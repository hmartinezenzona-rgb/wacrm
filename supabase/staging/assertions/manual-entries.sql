\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 228 (manual Calculator lines as ledger entries, so Finanzas counts them). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so nothing is
-- kept). Each passing case NOTICEs. Runs on staging (production after the owner's go-ahead). Builds its own data.
--
-- odd/tasks/manual-entries-in-finanzas.md (T1). The Calculator page parses the manual text on the client and sends the
-- parsed lines; crm_sincronizar_entradas_manuales replaces the current week's manual entries of the account with that set
-- (source 'manual', status completed, no operation). crm_cierre_financiero counts them next to the bot's entries and
-- marks them; the Calculator read (calculator_current_entries) keeps listing only the bot's entries; a weekly cut leaves
-- the closed week's manual entries in the ledger; only the sync RPC may change a manual row.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t228_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

-- a bot entry: completes a fresh operation of the account
CREATE FUNCTION pg_temp.t228_complete(p_acc uuid, p_conv uuid, p_agent uuid, p_amount numeric) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acc, p_conv, 'ready_to_transfer', 'remesa', 'GYD', p_amount, 'zelle') RETURNING id INTO v_op;
  PERFORM pg_temp.t228_claims(p_agent);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM pg_temp.t228_claims(NULL);
  RETURN v_op;
END $f$;

-- one parsed line as the client sends it
CREATE FUNCTION pg_temp.t228_line(p_pos int, p_date date, p_day text, p_cust text, p_service text, p_amount numeric, p_cur text,
                                  p_f numeric, p_i numeric, p_r numeric, p_raw text) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('position', p_pos, 'date', p_date, 'day_label', p_day, 'customer', p_cust, 'service', p_service,
                            'amount', p_amount, 'currency', p_cur, 'facturado_gyd', p_f, 'invertido_gyd', p_i, 'retorno_gyd', p_r,
                            'raw_line', p_raw);
$f$;

-- runs the sync as a user; returns 'ok' or the SQLSTATE
CREATE FUNCTION pg_temp.t228_sync(p_uid uuid, p_acc uuid, p_lines jsonb) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  PERFORM crm_sincronizar_entradas_manuales(p_acc, p_lines);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t228_claims(NULL);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.t228_cut(p_uid uuid, p_acc uuid, p_text text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  PERFORM crm_cerrar_semana_calculadora(p_acc, p_text, 'Semana', 0, 0, 0);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t228_claims(NULL);
  RETURN SQLSTATE;
END $f$;

-- the manual rows of an account as a comparable jsonb (ordered by position)
CREATE FUNCTION pg_temp.t228_rows(p_acc uuid) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.entry_date, e.line_position, e.id), '[]'::jsonb)
    FROM remittance_calculator_entries e WHERE e.account_id = p_acc AND e.source = 'manual';
$f$;

CREATE FUNCTION pg_temp.t228_close(p_uid uuid, p_from date, p_to date) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  v := crm_cierre_financiero(p_from, p_to);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN v;
END $f$;

-- a raw statement as the trigger sees it: returns the SQLSTATE or 'ok'
CREATE FUNCTION pg_temp.t228_raw(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END $f$;

DO $$
DECLARE
  v_dummy constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_viewer uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_acc uuid; v_acc2 uuid; v_ct uuid; v_conv uuid;
  v_op1 uuid; v_op2 uuid;
  v_d1 date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_d2 date := (now() AT TIME ZONE 'America/Guyana')::date - 1;
  v_lines jsonb; v_rows jsonb; v_rows2 jsonb; v_n int; v_res text; v_ids uuid[]; v_ids2 uuid[];
  v_c0 jsonb; v_c1 jsonb; v_c2 jsonb; v_x record; v_svc text; v_e uuid; v_week jsonb; v_week2 jsonb; v_arch jsonb;
  v_bot_f numeric; v_bot_i numeric; v_bot_r numeric; v_bot_n int;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'man-' || u || '@test.invalid', v_dummy, now(), now(), now(), '{}', '{}', false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_viewer, v_other]) u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'man test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'man other account', v_other) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'man owner', 'man-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'man admin', 'man-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'man agent', 'man-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_viewer, 'man viewer', 'man-' || v_viewer || '@test.invalid', v_acc, 'viewer'),
    (gen_random_uuid(), v_other, 'man other', 'man-' || v_other || '@test.invalid', v_acc2, 'owner');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '59902280001', v_acc, 'Cliente MAN') RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct, v_acc) RETURNING id INTO v_conv;
  PERFORM pg_temp.t228_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 400));
  PERFORM pg_temp.t228_claims(NULL);

  -- two bot entries today (the close already counts them)
  v_op1 := pg_temp.t228_complete(v_acc, v_conv, v_agent, 26000);
  v_op2 := pg_temp.t228_complete(v_acc, v_conv, v_agent, 13000);
  SELECT count(*), sum(facturado_gyd), sum(invertido_gyd), sum(retorno_gyd) INTO v_bot_n, v_bot_f, v_bot_i, v_bot_r
    FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'completed_operation' AND status = 'completed';
  IF v_bot_n <> 2 THEN RAISE EXCEPTION 'fixture: expected two completed bot entries, got %', v_bot_n; END IF;
  v_c0 := pg_temp.t228_close(v_admin, v_d2, v_d1);

  v_lines := jsonb_build_array(
    pg_temp.t228_line(1, v_d2, 'Martes 6', 'Pedro Perez', 'ZELLE', 100, 'USD', 15000, 12000, 3000, 'Pedro Perez 100 zelle (30%/120/150)'),
    pg_temp.t228_line(2, v_d1, 'Miércoles 7', 'Ana Gomez', 'CUP', 5000, 'CUP', 3333.5, 2800, 533.5, 'Ana Gomez 5000 cup'),
    pg_temp.t228_line(4, v_d1, 'Miércoles 7', 'Luis Diaz', 'DIRECTO', 20000, 'GYD', 20000, 0, 20000, 'Luis Diaz visa 20000'));

  -- ---- 1. the sync replaces the current week's manual entries; idempotent; remove / change / empty ----
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 1: the agent sync failed'; END IF;
  v_rows := pg_temp.t228_rows(v_acc);
  IF jsonb_array_length(v_rows) <> 3 THEN RAISE EXCEPTION 'case 1: three manual rows expected, got %', v_rows; END IF;
  SELECT * INTO v_x FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Pedro Perez';
  IF v_x.status <> 'completed' OR v_x.operation_id IS NOT NULL OR v_x.entry_date <> v_d2 OR v_x.service <> 'ZELLE' OR v_x.amount <> 100
     OR v_x.amount_currency <> 'USD' OR v_x.facturado_gyd <> 15000 OR v_x.invertido_gyd <> 12000 OR v_x.retorno_gyd <> 3000
     OR v_x.day_label <> 'Martes 6' OR v_x.line_position <> 1 OR v_x.raw_line <> 'Pedro Perez 100 zelle (30%/120/150)'
     OR (v_x.completed_at AT TIME ZONE 'America/Guyana')::date <> v_d2 OR v_x.actor_user_id <> v_agent THEN
    RAISE EXCEPTION 'case 1: the manual row does not hold the line: %', to_jsonb(v_x); END IF;
  SELECT array_agg(id ORDER BY line_position) INTO v_ids FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual';
  -- same set again: the same rows, untouched
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 1: the repeated sync failed'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 1: a repeated sync must leave the very same rows'; END IF;
  -- one line removed: that row disappears, the others stay
  IF pg_temp.t228_sync(v_admin, v_acc, v_lines - 2) <> 'ok' THEN RAISE EXCEPTION 'case 1: the sync without line 4 failed'; END IF;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual';
  IF v_n <> 2 OR EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE id = v_ids[3]) OR NOT EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE id = v_ids[1])
     OR NOT EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE id = v_ids[2]) THEN
    RAISE EXCEPTION 'case 1: removing a line must delete exactly that row'; END IF;
  -- one line changed: updated in place
  v_lines := jsonb_set(v_lines, '{0}', pg_temp.t228_line(1, v_d2, 'Martes 6', 'Pedro Perez', 'ZELLE', 120, 'USD', 18000, 14400, 3600, 'Pedro Perez 120 zelle'));
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 1: the sync with a changed line failed'; END IF;
  SELECT * INTO v_x FROM remittance_calculator_entries WHERE id = v_ids[1];
  IF v_x.amount <> 120 OR v_x.facturado_gyd <> 18000 OR v_x.retorno_gyd <> 3600 OR v_x.raw_line <> 'Pedro Perez 120 zelle' THEN
    RAISE EXCEPTION 'case 1: a changed line must update its row: %', to_jsonb(v_x); END IF;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual';
  IF v_n <> 3 THEN RAISE EXCEPTION 'case 1: the line 4 came back with the full set, three rows expected, got %', v_n; END IF;
  -- an empty set removes them all, and not the bot's entries
  IF pg_temp.t228_sync(v_agent, v_acc, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 1: the empty sync failed'; END IF;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: an empty set must remove every manual row, % left', v_n; END IF;
  IF (SELECT count(*) FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'completed_operation') <> 2 THEN
    RAISE EXCEPTION 'case 1: the sync touched the bot entries'; END IF;
  RAISE NOTICE 'PASS 1: the sync replaces the current week''s manual entries; repeated sync leaves the same rows; remove / change / empty work';

  -- ---- 2. validation: refused, nothing written; roles; anon ----
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 2: setup sync failed'; END IF;
  v_rows := pg_temp.t228_rows(v_acc);
  FOR v_x IN
    SELECT * FROM (VALUES
      ('negative amount', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', -5, 'USD', 1, 1, 0, 'x')),
      ('zero amount', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 0, 'USD', 1, 1, 0, 'x')),
      ('negative facturado', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', -1, 1, 0, 'x')),
      ('negative invertido', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, -1, 0, 'x')),
      ('NaN as text', jsonb_set(pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{facturado_gyd}', '"NaN"')),
      ('null figure', jsonb_set(pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{invertido_gyd}', 'null')),
      ('huge figure', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1e15, 1, 0, 'x')),
      ('missing customer', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'customer'),
      ('blank customer', pg_temp.t228_line(9, v_d1, NULL, '   ', 'ZELLE', 5, 'USD', 1, 1, 0, 'x')),
      ('missing service', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'service'),
      ('unknown service', pg_temp.t228_line(9, v_d1, NULL, 'X', 'DESCONOCIDO', 5, 'USD', 1, 1, 0, 'x')),
      ('service with a space', pg_temp.t228_line(9, v_d1, NULL, 'X', 'SALDO MOVIL', 5, 'REC', 1, 1, 0, 'x')),
      ('bot-only service', pg_temp.t228_line(9, v_d1, NULL, 'X', 'EFECTIVO', 5, 'USD', 1, 1, 0, 'x')),
      ('bad date', jsonb_set(pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{date}', '"nope"')),
      ('future date', pg_temp.t228_line(9, v_d1 + 5, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x')),
      ('missing position', pg_temp.t228_line(9, v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'position'),
      ('not an object', '"text"'::jsonb)
    ) t(label, line)
  LOOP
    v_res := pg_temp.t228_sync(v_agent, v_acc, v_lines || jsonb_build_array(v_x.line));
    IF v_res <> '22023' THEN RAISE EXCEPTION 'case 2: % must be refused with 22023, got %', v_x.label, v_res; END IF;
    IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: % wrote something', v_x.label; END IF;
  END LOOP;
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines || jsonb_build_array(v_lines -> 0)) <> '22023' THEN RAISE EXCEPTION 'case 2: a repeated position must be refused'; END IF;
  IF pg_temp.t228_sync(v_agent, v_acc, '{"a":1}'::jsonb) <> '22023' OR pg_temp.t228_sync(v_agent, v_acc, NULL) <> '22023' THEN
    RAISE EXCEPTION 'case 2: a payload that is not an array must be refused (22023)'; END IF;
  IF pg_temp.t228_sync(v_agent, NULL, v_lines) <> '22023' THEN RAISE EXCEPTION 'case 2: a missing account must be refused (22023)'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: a refused payload wrote something'; END IF;
  IF pg_temp.t228_sync(v_viewer, v_acc, v_lines) <> '42501' THEN RAISE EXCEPTION 'case 2: a viewer must be refused (42501)'; END IF;
  IF pg_temp.t228_sync(v_other, v_acc, v_lines) <> '42501' THEN RAISE EXCEPTION 'case 2: another account''s owner must be refused (42501)'; END IF;
  IF pg_temp.t228_sync(NULL, v_acc, v_lines) <> '42501' THEN RAISE EXCEPTION 'case 2: no session must be refused (42501)'; END IF;
  IF pg_temp.t228_sync(v_other, v_acc2, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 2: the other account''s owner can sync its own account'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: refused callers wrote something'; END IF;
  IF has_function_privilege('anon', 'crm_sincronizar_entradas_manuales(uuid,jsonb)', 'execute') THEN RAISE EXCEPTION 'case 2: anon must not execute the sync'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_sincronizar_entradas_manuales(uuid,jsonb)', 'execute') THEN RAISE EXCEPTION 'case 2: authenticated must execute the sync'; END IF;
  -- a sync of one account never touches another account's manual rows
  IF pg_temp.t228_sync(v_other, v_acc2, jsonb_build_array(pg_temp.t228_line(1, v_d1, NULL, 'Otra', 'USDT', 10, 'USD', 2600, 2500, 100, 'otra 10 usdt'))) <> 'ok' THEN
    RAISE EXCEPTION 'case 2: the other account sync failed'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: another account''s sync changed this account'; END IF;
  IF pg_temp.t228_sync(v_other, v_acc2, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 2: cleanup of the other account failed'; END IF;
  RAISE NOTICE 'PASS 2: bad figures / customer / service / date / shape refused (22023) with nothing written; viewer, other account, no session refused (42501); anon cannot execute';

  -- ---- 3. Finanzas counts the manual entries next to the bot's and marks them; bot-only is unchanged ----
  v_c1 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF (v_c1 -> 'totales' ->> 'operaciones')::int <> v_bot_n + 3 THEN RAISE EXCEPTION 'case 3: operaciones must be bot + manual, got %', v_c1 -> 'totales'; END IF;
  IF (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric <> v_bot_f + 18000 + 3333.5 + 20000
     OR (v_c1 -> 'totales' ->> 'invertido_gyd')::numeric <> v_bot_i + 14400 + 2800 + 0
     OR (v_c1 -> 'totales' ->> 'retorno_gyd')::numeric <> v_bot_r + 3600 + 533.5 + 20000 THEN
    RAISE EXCEPTION 'case 3: the totals must add the manual entries to the bot''s, got %', v_c1 -> 'totales'; END IF;
  IF (SELECT coalesce(sum((s ->> 'facturado_gyd')::numeric), 0) FROM jsonb_array_elements(v_c1 -> 'por_servicio') s WHERE s ->> 'service' = 'DIRECTO') <> 20000
     OR (SELECT (s ->> 'operaciones')::int FROM jsonb_array_elements(v_c1 -> 'por_servicio') s WHERE s ->> 'service' = 'CUP') <> 1 THEN
    RAISE EXCEPTION 'case 3: the per-service breakdown must hold the manual services, got %', v_c1 -> 'por_servicio'; END IF;
  IF (SELECT (s ->> 'facturado_gyd')::numeric FROM jsonb_array_elements(v_c1 -> 'por_servicio') s WHERE s ->> 'service' = 'ZELLE')
     <> (SELECT sum(facturado_gyd) FROM remittance_calculator_entries WHERE account_id = v_acc AND service = 'ZELLE' AND status = 'completed') THEN
    RAISE EXCEPTION 'case 3: a manual ZELLE must add to the bot''s ZELLE row, got %', v_c1 -> 'por_servicio'; END IF;
  IF (SELECT sum((d ->> 'operaciones')::int) FROM jsonb_array_elements(v_c1 -> 'por_dia') d) <> v_bot_n + 3
     OR (SELECT (d ->> 'operaciones')::int FROM jsonb_array_elements(v_c1 -> 'por_dia') d WHERE (d ->> 'dia')::date = v_d2) <> 1 THEN
    RAISE EXCEPTION 'case 3: the per-day breakdown must count the manual entries on their day, got %', v_c1 -> 'por_dia'; END IF;
  IF jsonb_array_length(v_c1 -> 'detalle') <> v_bot_n + 3
     OR (SELECT count(*) FROM jsonb_array_elements(v_c1 -> 'detalle') d WHERE d ->> 'source' = 'manual') <> 3
     OR (SELECT count(*) FROM jsonb_array_elements(v_c1 -> 'detalle') d WHERE d ->> 'source' = 'completed_operation' AND d ->> 'operation_id' IS NOT NULL) <> v_bot_n
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_c1 -> 'detalle') d WHERE d ->> 'source' = 'manual' AND (d ->> 'operation_id') IS NOT NULL) THEN
    RAISE EXCEPTION 'case 3: the detail must list manual rows marked as manual next to the bot rows, got %', v_c1 -> 'detalle'; END IF;
  IF (SELECT d ->> 'customer_name' FROM jsonb_array_elements(v_c1 -> 'detalle') d WHERE d ->> 'source' = 'manual' AND (d ->> 'dia')::date = v_d2) <> 'Pedro Perez' THEN
    RAISE EXCEPTION 'case 3: a manual row must be listed on its own day'; END IF;
  -- a viewer of the account reads the same numbers (any member); another account sees none of it
  IF pg_temp.t228_close(v_viewer, v_d2, v_d1) IS DISTINCT FROM v_c1 THEN RAISE EXCEPTION 'case 3: a viewer must read the same close'; END IF;
  IF (pg_temp.t228_close(v_other, v_d2, v_d1) -> 'totales' ->> 'operaciones')::int <> 0 THEN RAISE EXCEPTION 'case 3: another account counted these entries'; END IF;
  -- bot-only: with no manual entries the close is EXACTLY what it was
  IF pg_temp.t228_sync(v_agent, v_acc, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 3: cleanup failed'; END IF;
  v_c2 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF jsonb_set(v_c2, '{detalle}', (SELECT coalesce(jsonb_agg(d - 'source'), '[]') FROM jsonb_array_elements(v_c2 -> 'detalle') d))
     IS DISTINCT FROM jsonb_set(v_c0, '{detalle}', (SELECT coalesce(jsonb_agg(d - 'source'), '[]') FROM jsonb_array_elements(v_c0 -> 'detalle') d)) THEN
    RAISE EXCEPTION 'case 3: with no manual entries the close must equal the bot-only close: % vs %', v_c2, v_c0; END IF;
  IF v_c2 -> 'totales' IS DISTINCT FROM v_c0 -> 'totales' OR v_c2 -> 'por_servicio' IS DISTINCT FROM v_c0 -> 'por_servicio'
     OR v_c2 -> 'por_dia' IS DISTINCT FROM v_c0 -> 'por_dia' THEN
    RAISE EXCEPTION 'case 3: bot-only numbers changed'; END IF;
  RAISE NOTICE 'PASS 3: Finanzas totals / per-service / per-day / detail count the manual entries, mark them, and are unchanged without them';

  -- ---- 4. the Calculator read lists ONLY the bot's entries ----
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 4: setup sync failed'; END IF;
  SELECT count(*) INTO v_n FROM calculator_current_entries WHERE account_id = v_acc;
  IF v_n <> 2 OR EXISTS (SELECT 1 FROM calculator_current_entries WHERE account_id = v_acc AND source = 'manual') THEN
    RAISE EXCEPTION 'case 4: the Calculator read must list the two bot entries only, got % rows', v_n; END IF;
  RAISE NOTICE 'PASS 4: calculator_current_entries lists only the bot''s entries';

  -- ---- 5. the weekly cut keeps the closed week's manual entries; the next sync does not touch them ----
  v_c1 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  v_rows := pg_temp.t228_rows(v_acc);
  IF pg_temp.t228_cut(v_agent, v_acc, 'Pedro Perez 120 zelle') <> 'ok' THEN RAISE EXCEPTION 'case 5: the cut failed'; END IF;
  SELECT jsonb_build_object('entries', entries, 'chat', chat_totals, 'manual', manual_totals, 'text', raw_text) INTO v_week
    FROM remittance_calculator_weeks WHERE account_id = v_acc;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 5: the cut changed the manual rows'; END IF;
  IF pg_temp.t228_close(v_admin, v_d2, v_d1) IS DISTINCT FROM v_c1 THEN RAISE EXCEPTION 'case 5: the close changed after the cut'; END IF;
  -- the new week starts with no manual entries: the client syncs an empty set, which must not delete the archived rows
  IF pg_temp.t228_sync(v_agent, v_acc, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 5: the empty sync of the new week failed'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 5: an empty sync after the cut deleted the archived week''s manual rows'; END IF;
  -- the new week reuses the same positions: new rows, the archived ones stay
  IF pg_temp.t228_sync(v_agent, v_acc, jsonb_build_array(
       pg_temp.t228_line(1, v_d1, 'Miércoles 7', 'Nueva', 'USDT', 10, 'USD', 2600, 2500, 100, 'Nueva 10 usdt'),
       pg_temp.t228_line(2, v_d1, 'Miércoles 7', 'Nueva Dos', 'ZELLE', 20, 'USD', 5000, 4000, 1000, 'Nueva Dos 20 zelle'))) <> 'ok' THEN
    RAISE EXCEPTION 'case 5: the sync of the new week failed'; END IF;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual';
  IF v_n <> 5 THEN RAISE EXCEPTION 'case 5: three archived + two new manual rows expected, got %', v_n; END IF;
  IF NOT (pg_temp.t228_rows(v_acc) @> (SELECT jsonb_agg(r) FROM jsonb_array_elements(v_rows) r)) THEN RAISE EXCEPTION 'case 5: the archived rows changed'; END IF;
  v_c2 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF (v_c2 -> 'totales' ->> 'operaciones')::int <> v_bot_n + 5 OR (v_c2 -> 'totales' ->> 'facturado_gyd')::numeric <> (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric + 7600 THEN
    RAISE EXCEPTION 'case 5: the close must count the archived and the new manual entries, got %', v_c2 -> 'totales'; END IF;
  -- changing / emptying the new week never touches the archived one
  IF pg_temp.t228_sync(v_agent, v_acc, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 5: emptying the new week failed'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 5: emptying the new week touched the archived rows'; END IF;
  SELECT jsonb_build_object('entries', entries, 'chat', chat_totals, 'manual', manual_totals, 'text', raw_text) INTO v_week2
    FROM remittance_calculator_weeks WHERE account_id = v_acc;
  IF v_week2 IS DISTINCT FROM v_week THEN RAISE EXCEPTION 'case 5: the archived week shows something else now'; END IF;
  -- a second cut: the new (empty) week archives nothing manual and still leaves the older rows
  IF pg_temp.t228_cut(v_agent, v_acc, '') <> 'ok' THEN RAISE EXCEPTION 'case 5: the second cut failed'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 5: the second cut changed the manual rows'; END IF;
  RAISE NOTICE 'PASS 5: after a weekly cut the closed week''s manual entries stay in the ledger and in Finanzas; the next sync does not touch them; the archived week reads the same';

  -- ---- 6. guard: a manual row changes only through the sync ----
  SELECT id INTO v_e FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' ORDER BY line_position LIMIT 1;
  IF pg_temp.t228_raw(format('UPDATE remittance_calculator_entries SET facturado_gyd = 1 WHERE id = %L', v_e)) <> '42501' THEN RAISE EXCEPTION 'case 6: a raw UPDATE of a manual row must be refused'; END IF;
  IF pg_temp.t228_raw(format('UPDATE remittance_calculator_entries SET amount = 1 WHERE id = %L', v_e)) <> '42501' THEN RAISE EXCEPTION 'case 6: a raw UPDATE of the amount must be refused'; END IF;
  IF pg_temp.t228_raw(format('UPDATE remittance_calculator_entries SET status = ''void'', voided_at = now() WHERE id = %L', v_e)) NOT IN ('42501', '23514') THEN
    RAISE EXCEPTION 'case 6: a raw void of a manual row must be refused'; END IF;
  IF pg_temp.t228_raw(format('DELETE FROM remittance_calculator_entries WHERE id = %L', v_e)) <> '42501' THEN RAISE EXCEPTION 'case 6: a raw DELETE of a manual row must be refused'; END IF;
  IF pg_temp.t228_raw(format('SELECT set_config(''wacrm.calculator_correction'', ''true'', true); UPDATE remittance_calculator_entries SET facturado_gyd = 1 WHERE id = %L', v_e)) = 'ok' THEN
    RAISE EXCEPTION 'case 6: the correction switch must not open a manual row'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 6: the manual rows changed'; END IF;
  -- delete (226) and correct (149) keep refusing manual rows
  PERFORM pg_temp.t228_claims(v_admin);
  BEGIN
    PERFORM crm_eliminar_entrada_calculadora(v_e);
    RAISE EXCEPTION 'case 6: deleting a manual entry through the chat delete must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM crm_corregir_entrada_calculadora(v_e, 1, 1);
    RAISE EXCEPTION 'case 6: correcting a manual entry must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  PERFORM pg_temp.t228_claims(NULL);
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 6: delete / correct changed a manual row'; END IF;
  -- a client has no write on the table
  IF has_table_privilege('authenticated', 'remittance_calculator_entries', 'INSERT') OR has_table_privilege('authenticated', 'remittance_calculator_entries', 'UPDATE')
     OR has_table_privilege('authenticated', 'remittance_calculator_entries', 'DELETE') THEN
    RAISE EXCEPTION 'case 6: clients must have no write grant on the ledger'; END IF;
  RAISE NOTICE 'PASS 6: raw UPDATE / DELETE of a manual row refused; the chat delete and correct keep refusing manual rows (22023)';

  -- ---- 7. every service the manual calculator can produce is accepted ----
  -- the parser (src/lib/calculator/web-calculator.ts) emits CUP, ZELLE, MLC, TROPICAL, CLASICA, USDT, SALDO MOVIL (ledger SALDO_MOVIL),
  -- RECARGA and, for the direct lines (visa, ext, trabajo, estudiante, trad, combo, pasaje), the group TRAMITES / COMBOS / SERVICIOS (ledger DIRECTO).
  v_lines := '[]'::jsonb; v_n := 0;
  FOREACH v_svc IN ARRAY ARRAY['CUP', 'ZELLE', 'MLC', 'TROPICAL', 'CLASICA', 'USDT', 'SALDO_MOVIL', 'RECARGA', 'DIRECTO'] LOOP
    v_n := v_n + 1;
    v_lines := v_lines || jsonb_build_array(pg_temp.t228_line(v_n, v_d1, NULL, 'Cliente ' || v_svc, v_svc, 10, CASE v_svc WHEN 'CUP' THEN 'CUP' WHEN 'DIRECTO' THEN 'GYD' WHEN 'RECARGA' THEN 'REC' WHEN 'SALDO_MOVIL' THEN 'REC' ELSE 'USD' END, 100, 60, 40, 'line ' || v_svc));
  END LOOP;
  IF pg_temp.t228_sync(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 7: a service the manual calculator produces was refused'; END IF;
  SELECT count(DISTINCT service) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND entry_date = v_d1 AND customer_name LIKE 'Cliente %';
  IF v_n <> 9 THEN RAISE EXCEPTION 'case 7: nine services expected, got %', v_n; END IF;
  IF pg_temp.t228_sync(v_agent, v_acc, '[]'::jsonb) <> 'ok' THEN RAISE EXCEPTION 'case 7: cleanup failed'; END IF;
  RAISE NOTICE 'PASS 7: every service the manual calculator can produce is accepted';

  RAISE NOTICE 'manual-entries: ALL PASS';
END $$;

ROLLBACK;
