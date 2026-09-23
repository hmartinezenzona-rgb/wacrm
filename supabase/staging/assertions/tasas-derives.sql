-- tasas-derives.sql — self-reverting assertion for
-- 113_tasas_derives_from_the_calculator.sql
--
-- Proves the legacy `tasas` reads now derive from the calculator:
--   - the ACTUAL reader queries (crm_tasa_vigente, the consultar_tasas
--     DISTINCT ON shape, the calcular_usd_desde_gyd shape) still work,
--     unchanged, against the view;
--   - the two sources can no longer disagree: appending a new calculator
--     rate version is immediately visible to every reader, with no
--     separate write/sync step;
--   - a rate can no longer be set anywhere but the calculator — writing
--     to `tasas` directly now fails;
--   - a currency with no rate on the latest version produces no row for
--     that currency (never a `tasa_cup = NULL` row), and readers
--     correctly fall back to the last version that actually set one.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures
-- (account + admin persona), so it can run alongside or independently of
-- the other assertion files. Does not touch or depend on any pre-existing
-- account's real calculator rates.

SAVEPOINT tasas_derives;

DO $$
DECLARE
  v_account_id  uuid;
  v_admin_user  uuid := gen_random_uuid();
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_v1          calculator_rate_versions;
  v_v2          calculator_rate_versions;
  v_v3          calculator_rate_versions;

  v_usd         numeric;
  v_gyd         numeric;
  v_distinct_n  integer;
  v_distinct_usd numeric;
  v_distinct_gyd numeric;
  v_calc_usd    numeric;
  v_row_count   integer;

  v_fail_count  integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tasas-derives-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'tasas derives test account', v_admin_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_admin_user, 'tasas derives admin', 'tasas-derives-admin-' || v_admin_user || '@test.invalid', v_account_id, 'owner');

  -- ---- v1: set all four calculator rates -------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_v1 := crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 3.10, 'usdt_buy_gyd', 245, 'usdt_sell_gyd', 258, 'usdt_sell_cup', 405));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- case 1: crm_tasa_vigente reflects v1 ----------------------------
  v_usd := crm_tasa_vigente('usd');
  v_gyd := crm_tasa_vigente('gyd');

  IF v_usd IS DISTINCT FROM 258 OR v_gyd IS DISTINCT FROM 3.10 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected crm_tasa_vigente(usd)=258 and crm_tasa_vigente(gyd)=3.10 after v1; got %/%', v_usd, v_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 1] crm_tasa_vigente(usd)/crm_tasa_vigente(gyd) read the calculator''s rates through the tasas view';
  END IF;

  -- ---- case 2: the consultar_tasas DISTINCT ON shape --------------------
  SELECT count(*) INTO v_distinct_n
    FROM (SELECT DISTINCT ON (moneda) moneda, tasa_cup
            FROM tasas
           ORDER BY moneda, fecha DESC, actualizada_at DESC) d;

  SELECT tasa_cup INTO v_distinct_usd
    FROM (SELECT DISTINCT ON (moneda) moneda, tasa_cup
            FROM tasas
           ORDER BY moneda, fecha DESC, actualizada_at DESC) d
   WHERE moneda = 'usd';

  SELECT tasa_cup INTO v_distinct_gyd
    FROM (SELECT DISTINCT ON (moneda) moneda, tasa_cup
            FROM tasas
           ORDER BY moneda, fecha DESC, actualizada_at DESC) d
   WHERE moneda = 'gyd';

  IF v_distinct_n <> 2 OR v_distinct_usd IS DISTINCT FROM 258 OR v_distinct_gyd IS DISTINCT FROM 3.10 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected the DISTINCT ON (moneda) shape to return exactly 2 rows (usd=258, gyd=3.10); got n=%, usd=%, gyd=%', v_distinct_n, v_distinct_usd, v_distinct_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 2] the consultar_tasas SELECT DISTINCT ON (moneda) shape returns one row per currency with the calculator''s rates';
  END IF;

  -- ---- case 3: the calcular_usd_desde_gyd shape --------------------------
  -- Same query n8n's node runs, verbatim shape, only the deposit amount
  -- ($1 there) inlined as a literal here.
  SELECT floor(50000 / tasa_cup) INTO v_calc_usd
    FROM tasas WHERE moneda = 'usd' ORDER BY fecha DESC, actualizada_at DESC LIMIT 1;

  IF v_calc_usd IS DISTINCT FROM floor(50000::numeric / 258) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected calcular_usd_desde_gyd(50000) = floor(50000/258) = %; got %', floor(50000::numeric / 258), v_calc_usd;
  ELSE
    RAISE NOTICE 'PASS [case 3] the calcular_usd_desde_gyd shape computes against the calculator''s rate';
  END IF;

  -- ---- v2: append a NEW calculator rate version --------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_v2 := crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 3.35, 'usdt_sell_gyd', 262));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- case 4: the two sources can no longer disagree --------------------
  -- THE ENTIRE POINT of 113: before it, setting a calculator rate left
  -- the bot quoting the old `tasas` number. Now the SAME transaction that
  -- appended v2 must see it immediately through the legacy read path,
  -- with no separate write/sync step at all.
  v_usd := crm_tasa_vigente('usd');
  v_gyd := crm_tasa_vigente('gyd');

  IF v_usd IS DISTINCT FROM 262 OR v_gyd IS DISTINCT FROM 3.35 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected crm_tasa_vigente to immediately reflect the new calculator rates (usd=262, gyd=3.35) with NO separate sync step; got %/%', v_usd, v_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 4] crm_set_calculator_rates immediately changes what every tasas reader sees — the two sources cannot disagree any more';
  END IF;

  -- ---- case 5: a rate can no longer be set anywhere else -----------------
  BEGIN
    INSERT INTO tasas (tasa_cup, moneda) VALUES (999, 'usd');
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected INSERT INTO tasas to fail (a view with no INSERT rule/trigger), it succeeded instead';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'PASS [case 5] INSERT INTO tasas is rejected (% — %): a rate can only be set through crm_set_calculator_rates', SQLSTATE, SQLERRM;
  END;

  -- ---- v3: clear usdt_sell_gyd only (explicit JSON null) ------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_v3 := crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', NULL));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- case 6: a NULL underlying rate produces no row, and the reader
  --              correctly falls back to the last version that had one --
  SELECT count(*) INTO v_row_count
    FROM tasas WHERE moneda = 'usd' AND actualizada_at = v_v3.effective_at;

  IF v_row_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6a] expected NO usd row for the version whose usdt_sell_gyd is NULL, found %', v_row_count;
  ELSE
    RAISE NOTICE 'PASS [case 6a] a NULL usdt_sell_gyd produces no usd row for that version (never surfaces as tasa_cup = NULL)';
  END IF;

  SELECT count(*) INTO v_row_count
    FROM tasas WHERE moneda = 'gyd' AND actualizada_at = v_v3.effective_at;

  IF v_row_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6b] expected exactly one gyd row for v3 (cup_global_rate carried forward, still non-NULL), found %', v_row_count;
  ELSE
    RAISE NOTICE 'PASS [case 6b] the same version still produces a gyd row, since cup_global_rate carried forward non-NULL';
  END IF;

  v_usd := crm_tasa_vigente('usd');
  v_gyd := crm_tasa_vigente('gyd');

  IF v_usd IS DISTINCT FROM 262 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6c] expected crm_tasa_vigente(usd) to fall back to the last version that set it (262), got %', v_usd;
  ELSIF v_gyd IS DISTINCT FROM 3.35 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6c] expected crm_tasa_vigente(gyd) to stay at the newest version''s carried-forward rate (3.35), got %', v_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 6c] crm_tasa_vigente(usd) falls back past the NULL version to the last real usd rate, while crm_tasa_vigente(gyd) stays current';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'tasas-derives: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'tasas-derives: ALL PASS (8 expectations)';
END $$;

ROLLBACK TO SAVEPOINT tasas_derives;
