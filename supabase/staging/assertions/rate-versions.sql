-- rate-versions.sql — self-reverting assertion for
-- 103_calculator_rate_versions.sql
--
-- Proves calculator_rate_versions and crm_set_calculator_rates: admin+ only
-- (non-member, viewer and agent all refused), carry-forward of rates absent
-- from the payload, explicit-null clearing, input validation, the
-- optimistic-concurrency check on p_expected_version_id, append-only
-- enforcement (UPDATE and DELETE both rejected), the all-NULL guard, and
-- calculator_rates_vigentes always returning the newest version.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures (account +
-- owner/admin/agent/viewer personas + one outsider), so it can run
-- alongside or independently of the other assertion files.

-- SAVEPOINT and ROLLBACK TO SAVEPOINT are plain transaction-control
-- commands and cannot be issued from inside a PL/pgSQL DO block, so they
-- bracket it here instead.
SAVEPOINT rate_versions;

DO $$
DECLARE
  v_account_id     uuid;
  v_other_acct_id  uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_admin_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_outsider_user  uuid := gen_random_uuid();
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_v1             calculator_rate_versions;
  v_v2             calculator_rate_versions;
  v_v3             calculator_rate_versions;
  v_current        calculator_rate_versions;
  v_count          integer;
  v_set_by         uuid;

  v_fail_count     integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see corrections.sql's fixture comment for why.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rates-owner-'    || v_owner_user    || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rates-admin-'    || v_admin_user    || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rates-agent-'    || v_agent_user    || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rates-viewer-'   || v_viewer_user   || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_outsider_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rates-outsider-' || v_outsider_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'rate versions test account', v_owner_user)
  RETURNING id INTO v_account_id;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'rate versions other account', v_outsider_user)
  RETURNING id INTO v_other_acct_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user,    'rates owner',    'rates-owner-'    || v_owner_user    || '@test.invalid', v_account_id,    'owner'),
    (gen_random_uuid(), v_admin_user,    'rates admin',    'rates-admin-'    || v_admin_user    || '@test.invalid', v_account_id,    'admin'),
    (gen_random_uuid(), v_agent_user,    'rates agent',    'rates-agent-'    || v_agent_user    || '@test.invalid', v_account_id,    'agent'),
    (gen_random_uuid(), v_viewer_user,   'rates viewer',   'rates-viewer-'   || v_viewer_user   || '@test.invalid', v_account_id,    'viewer'),
    (gen_random_uuid(), v_outsider_user, 'rates outsider', 'rates-outsider-' || v_outsider_user || '@test.invalid', v_other_acct_id, 'owner');

  -- ---- case 1: no rates on file yet ------------------------------------
  v_current := calculator_rates_vigentes(v_account_id);
  IF v_current.id IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected no current rate version for a fresh account, got id=%', v_current.id;
  ELSE
    RAISE NOTICE 'PASS [case 1] a fresh account has no rates on file (no defaults seeded)';
  END IF;

  -- ---- case 2: admin sets all four rates -------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_v1 := crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 3.2, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 265, 'usdt_sell_cup', 410));
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_v1.cup_global_rate IS DISTINCT FROM 3.2 OR v_v1.usdt_buy_gyd IS DISTINCT FROM 250
     OR v_v1.usdt_sell_gyd IS DISTINCT FROM 265 OR v_v1.usdt_sell_cup IS DISTINCT FROM 410
     OR v_v1.set_by IS DISTINCT FROM v_admin_user OR v_v1.account_id IS DISTINCT FROM v_account_id
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected 3.2/250/265/410 set_by=%; got %/%/%/% set_by=%',
      v_admin_user, v_v1.cup_global_rate, v_v1.usdt_buy_gyd, v_v1.usdt_sell_gyd, v_v1.usdt_sell_cup, v_v1.set_by;
  ELSE
    RAISE NOTICE 'PASS [case 2] an admin appends a version with all four rates and their own set_by';
  END IF;

  -- ---- case 3: carry-forward of unspecified rates ----------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_v2 := crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 3.5));
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_v2.cup_global_rate IS DISTINCT FROM 3.5 OR v_v2.usdt_buy_gyd IS DISTINCT FROM 250
     OR v_v2.usdt_sell_gyd IS DISTINCT FROM 265 OR v_v2.usdt_sell_cup IS DISTINCT FROM 410
     OR v_v2.id = v_v1.id
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected a NEW version 3.5/250/265/410; got %/%/%/% (id same as v1: %)',
      v_v2.cup_global_rate, v_v2.usdt_buy_gyd, v_v2.usdt_sell_gyd, v_v2.usdt_sell_cup, (v_v2.id = v_v1.id);
  ELSE
    RAISE NOTICE 'PASS [case 3] rates absent from the payload carry forward into the new version';
  END IF;

  -- ---- case 4: the newest version is the current one -------------------
  v_current := calculator_rates_vigentes(v_account_id);
  IF v_current.id IS DISTINCT FROM v_v2.id THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected current = %, got %', v_v2.id, v_current.id;
  ELSE
    RAISE NOTICE 'PASS [case 4] calculator_rates_vigentes returns the newest version';
  END IF;

  -- ---- case 5: explicit null clears one rate ---------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_v3 := crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_cup', NULL));
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_v3.usdt_sell_cup IS NOT NULL OR v_v3.cup_global_rate IS DISTINCT FROM 3.5 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected usdt_sell_cup cleared and cup_global_rate kept at 3.5; got %/%',
      v_v3.usdt_sell_cup, v_v3.cup_global_rate;
  ELSE
    RAISE NOTICE 'PASS [case 5] an explicit JSON null clears a rate back to unknown';
  END IF;

  -- ---- case 6: the owner is admin+ -------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_cup', 415));
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'PASS [case 6] the account owner may set rates';

  -- ---- case 7: agent -> 42501 ------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 9));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected 42501 for an agent setting rates, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 7] an agent is rejected with 42501 (rates are admin+)';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8: viewer -> 42501 -----------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 9));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected 42501 for a viewer setting rates, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 8] a viewer is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 9: another account's owner -> 42501 ------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_outsider_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 9));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] expected 42501 for another account''s owner, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 9] an admin of a different account cannot set these rates';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 9] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 10: unknown key -> 22023 -----------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('tarifa', 3));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] expected 22023 for an unknown rate key, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 10] an unknown rate key is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 10] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 11: non-positive rate -> 22023 -----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 0));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 11] expected 22023 for a zero rate, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 11] a zero rate is rejected with 22023 (never priced at 0)';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 11] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 12: empty payload -> 22023 ---------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, '{}'::jsonb);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 12] expected 22023 for an empty payload, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 12] an empty payload is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 12] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 13: non-numeric value -> 22023 -----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 'tres'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 13] expected 22023 for a non-numeric rate, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 13] a non-numeric rate is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 13] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 14: stale expected version -> 40001 ------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
    -- v_v1 has long been superseded by v_v2/v_v3 and the case-6 write.
    PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 4), v_v1.id);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 14] expected 40001 for a stale expected version, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '40001' THEN
      RAISE NOTICE 'PASS [case 14] a stale p_expected_version_id is rejected with 40001';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 14] expected SQLSTATE 40001, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 15: correct expected version succeeds ----------------------
  v_current := calculator_rates_vigentes(v_account_id);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 4), v_current.id);
  PERFORM set_config('request.jwt.claims', '', true);

  v_current := calculator_rates_vigentes(v_account_id);
  IF v_current.cup_global_rate IS DISTINCT FROM 4 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 15] expected cup_global_rate 4 after a matching expected version, got %',
      v_current.cup_global_rate;
  ELSE
    RAISE NOTICE 'PASS [case 15] a matching p_expected_version_id is accepted';
  END IF;

  -- ---- case 16: UPDATE rejected (append-only) --------------------------
  BEGIN
    UPDATE calculator_rate_versions SET cup_global_rate = 99 WHERE id = v_v1.id;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 16] expected an append-only rejection on UPDATE, none raised';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 16] UPDATE on a rate version is rejected (history is immutable)';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 16] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 17: DELETE rejected (append-only) --------------------------
  BEGIN
    DELETE FROM calculator_rate_versions WHERE id = v_v1.id;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 17] expected an append-only rejection on DELETE, none raised';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 17] DELETE on a rate version is rejected';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 17] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 18: an all-NULL version is refused -------------------------
  BEGIN
    INSERT INTO calculator_rate_versions (account_id) VALUES (v_account_id);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 18] expected the not-empty CHECK to refuse an all-NULL version, none raised';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [case 18] an all-NULL version is refused by the not-empty CHECK';
  END;

  -- ---- case 19: every version is kept ----------------------------------
  SELECT count(*) INTO v_count FROM calculator_rate_versions WHERE account_id = v_account_id;
  IF v_count <> 5 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 19] expected 5 appended versions, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 19] all 5 appended versions are still on file';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'rate-versions: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'rate-versions: ALL PASS (19 expectations)';
END $$;

ROLLBACK TO SAVEPOINT rate_versions;
