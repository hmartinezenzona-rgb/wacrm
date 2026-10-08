\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 228 (manual operations as rows of the Calculator's one table, counted by Finanzas). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so nothing is
-- kept). Each passing case NOTICEs. Runs on staging (production after the owner's go-ahead). Builds its own data.
--
-- odd/tasks/manual-entries-in-finanzas.md (T2b, Design v2). crm_registrar_entradas_manuales ADDS manual operations (source
-- 'manual', status completed, no operation; all lines or none; an add, not a sync). They are listed by
-- calculator_current_entries next to the bot's; an admin corrects them (crm_corregir_entrada_calculadora) and deletes them
-- (crm_eliminar_entrada_calculadora, a durable void); the append-only guard lets a manual row change only through those two;
-- the weekly cut archives them with the bot's entries and they stay in the ledger; crm_cierre_financiero counts and marks them.
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
CREATE FUNCTION pg_temp.t228_line(p_date date, p_day text, p_cust text, p_service text, p_amount numeric, p_cur text,
                                  p_f numeric, p_i numeric, p_r numeric, p_raw text) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('date', p_date, 'day_label', p_day, 'customer', p_cust, 'service', p_service,
                            'amount', p_amount, 'currency', p_cur, 'facturado_gyd', p_f, 'invertido_gyd', p_i, 'retorno_gyd', p_r,
                            'raw_line', p_raw);
$f$;

-- runs the add as a user; returns 'ok' or the SQLSTATE
CREATE FUNCTION pg_temp.t228_add(p_uid uuid, p_acc uuid, p_lines jsonb) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  PERFORM crm_registrar_entradas_manuales(p_acc, p_lines);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t228_claims(NULL);
  RETURN SQLSTATE;
END $f$;

-- the add, returning what it returns
CREATE FUNCTION pg_temp.t228_addret(p_uid uuid, p_acc uuid, p_lines jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  v := crm_registrar_entradas_manuales(p_acc, p_lines);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.t228_correct(p_uid uuid, p_id uuid, p_f numeric, p_i numeric) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  PERFORM crm_corregir_entrada_calculadora(p_id, p_f, p_i);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t228_claims(NULL);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.t228_delete(p_uid uuid, p_id uuid) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  PERFORM crm_eliminar_entrada_calculadora(p_id);
  PERFORM pg_temp.t228_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t228_claims(NULL);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.t228_cut(p_uid uuid, p_acc uuid, p_text text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t228_claims(p_uid);
  PERFORM crm_cerrar_semana_calculadora(p_acc, p_text, 'Semana');
  PERFORM pg_temp.t228_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t228_claims(NULL);
  RETURN SQLSTATE;
END $f$;

-- the manual rows of an account as a comparable jsonb
CREATE FUNCTION pg_temp.t228_rows(p_acc uuid) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.created_at, e.id), '[]'::jsonb)
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
  v_d1 date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_d2 date := (now() AT TIME ZONE 'America/Guyana')::date - 1;
  v_lines jsonb; v_rows jsonb; v_ret jsonb; v_n int; v_res text; v_ids uuid[];
  v_c0 jsonb; v_c1 jsonb; v_c2 jsonb; v_x record; v_svc text; v_e uuid; v_week jsonb; v_week2 jsonb; v_aud jsonb;
  v_bot_f numeric; v_bot_i numeric; v_bot_r numeric; v_bot_n int; v_sql text;
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
  PERFORM pg_temp.t228_complete(v_acc, v_conv, v_agent, 26000);
  PERFORM pg_temp.t228_complete(v_acc, v_conv, v_agent, 13000);

  v_lines := jsonb_build_array(
    pg_temp.t228_line(v_d2, 'Martes 6', 'Pedro Perez', 'ZELLE', 100, 'USD', 15000, 12000, 3000, 'Pedro Perez 100 zelle (30%/120/150)'),
    pg_temp.t228_line(v_d1, 'Miércoles 7', 'Ana Gomez', 'CUP', 5000, 'CUP', 3333.5, 2800, 533.5, 'Ana Gomez 5000 cup'),
    pg_temp.t228_line(v_d1, 'Miércoles 7', 'Luis Diaz', 'DIRECTO', 20000, 'GYD', 20000, 0, 20000, 'Luis Diaz visa 20000'));

  -- ---- 1. the add: rows hold the lines, returned in order, audited; an add (twice = twice); bot entries untouched ----
  v_ret := pg_temp.t228_addret(v_agent, v_acc, v_lines);
  IF jsonb_typeof(v_ret) <> 'array' OR jsonb_array_length(v_ret) <> 3 THEN RAISE EXCEPTION 'case 1: the add must return the three created rows, got %', v_ret; END IF;
  IF v_ret -> 0 ->> 'customer_name' <> 'Pedro Perez' OR v_ret -> 1 ->> 'customer_name' <> 'Ana Gomez' OR v_ret -> 2 ->> 'customer_name' <> 'Luis Diaz' THEN
    RAISE EXCEPTION 'case 1: the returned rows must keep the order sent, got %', v_ret; END IF;
  v_rows := pg_temp.t228_rows(v_acc);
  IF jsonb_array_length(v_rows) <> 3 THEN RAISE EXCEPTION 'case 1: three manual rows expected, got %', v_rows; END IF;
  IF v_rows -> 0 ->> 'customer_name' <> 'Pedro Perez' OR v_rows -> 2 ->> 'customer_name' <> 'Luis Diaz' THEN
    RAISE EXCEPTION 'case 1: the rows must be stored in the order sent, got %', v_rows; END IF;
  SELECT * INTO v_x FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Pedro Perez';
  IF v_x.status <> 'completed' OR v_x.operation_id IS NOT NULL OR v_x.entry_date <> v_d2 OR v_x.service <> 'ZELLE' OR v_x.amount <> 100
     OR v_x.amount_currency <> 'USD' OR v_x.facturado_gyd <> 15000 OR v_x.invertido_gyd <> 12000 OR v_x.retorno_gyd <> 3000
     OR v_x.day_label <> 'Martes 6' OR v_x.raw_line <> 'Pedro Perez 100 zelle (30%/120/150)' OR v_x.source_event_id IS NOT NULL
     OR (v_x.completed_at AT TIME ZONE 'America/Guyana')::date <> v_d2 OR v_x.actor_user_id <> v_agent
     OR v_x.deleted_at IS NOT NULL OR v_x.voided_at IS NOT NULL THEN
    RAISE EXCEPTION 'case 1: the manual row does not hold the line: %', to_jsonb(v_x); END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE account_id = v_acc AND action = 'human_calculator_manual_added' AND actor = v_agent::text;
  IF v_n <> 3 THEN RAISE EXCEPTION 'case 1: each added row must be audited, got % audit rows', v_n; END IF;
  IF (SELECT count(*) FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'completed_operation') <> 2 THEN
    RAISE EXCEPTION 'case 1: the add touched the bot entries'; END IF;
  -- a bot completion after the manual rows exist leaves them as they were (the feed works by operation)
  PERFORM pg_temp.t228_complete(v_acc, v_conv, v_agent, 5000);
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 1: a bot completion changed manual rows'; END IF;
  SELECT count(*), sum(facturado_gyd), sum(invertido_gyd), sum(retorno_gyd) INTO v_bot_n, v_bot_f, v_bot_i, v_bot_r
    FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'completed_operation' AND status = 'completed';
  IF v_bot_n <> 3 THEN RAISE EXCEPTION 'fixture: expected three completed bot entries, got %', v_bot_n; END IF;
  -- the same lines again are added again: an add, not a sync (checked on the other account, to keep this one's baseline)
  IF pg_temp.t228_add(v_other, v_acc2, v_lines) <> 'ok' OR pg_temp.t228_add(v_other, v_acc2, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 1: the repeated add failed'; END IF;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc2 AND source = 'manual';
  IF v_n <> 6 THEN RAISE EXCEPTION 'case 1: adding the same lines twice must give six rows, got %', v_n; END IF;
  RAISE NOTICE 'PASS 1: the add stores the lines as manual completed rows (date, Guyana day, actor, raw line), returns them in order, audits each; twice = twice; bot entries untouched';

  -- ---- 2. validation: refused with nothing written (even after valid lines); roles; anon ----
  v_rows := pg_temp.t228_rows(v_acc);
  FOR v_x IN
    SELECT * FROM (VALUES
      ('negative amount', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', -5, 'USD', 1, 1, 0, 'x')),
      ('zero amount', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 0, 'USD', 1, 1, 0, 'x')),
      ('negative facturado', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', -1, 1, 0, 'x')),
      ('negative invertido', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, -1, 0, 'x')),
      ('NaN as text', jsonb_set(pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{facturado_gyd}', '"NaN"')),
      ('null figure', jsonb_set(pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{invertido_gyd}', 'null')),
      ('missing retorno', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'retorno_gyd'),
      ('huge figure', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1e15, 1, 0, 'x')),
      ('missing customer', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'customer'),
      ('blank customer', pg_temp.t228_line(v_d1, NULL, '   ', 'ZELLE', 5, 'USD', 1, 1, 0, 'x')),
      ('missing service', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'service'),
      ('unknown service', pg_temp.t228_line(v_d1, NULL, 'X', 'DESCONOCIDO', 5, 'USD', 1, 1, 0, 'x')),
      ('service with a space', pg_temp.t228_line(v_d1, NULL, 'X', 'SALDO MOVIL', 5, 'REC', 1, 1, 0, 'x')),
      ('bot-only service', pg_temp.t228_line(v_d1, NULL, 'X', 'EFECTIVO', 5, 'USD', 1, 1, 0, 'x')),
      ('missing currency', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'currency'),
      ('bad date', jsonb_set(pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{date}', '"nope"')),
      ('missing date', pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x') - 'date'),
      ('future date', pg_temp.t228_line(v_d1 + 5, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x')),
      ('too old a date', pg_temp.t228_line(v_d1 - 61, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x')),
      ('day label not text', jsonb_set(pg_temp.t228_line(v_d1, NULL, 'X', 'ZELLE', 5, 'USD', 1, 1, 0, 'x'), '{day_label}', '5')),
      ('not an object', '"text"'::jsonb)
    ) t(label, line)
  LOOP
    -- valid lines come first: the bad one must undo the whole batch
    v_res := pg_temp.t228_add(v_agent, v_acc, v_lines || jsonb_build_array(v_x.line));
    IF v_res <> '22023' THEN RAISE EXCEPTION 'case 2: % must be refused with 22023, got %', v_x.label, v_res; END IF;
    IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: % wrote something', v_x.label; END IF;
  END LOOP;
  IF pg_temp.t228_add(v_agent, v_acc, '[]'::jsonb) <> '22023' THEN RAISE EXCEPTION 'case 2: an empty list must be refused (22023)'; END IF;
  IF pg_temp.t228_add(v_agent, v_acc, '{"a":1}'::jsonb) <> '22023' OR pg_temp.t228_add(v_agent, v_acc, NULL) <> '22023' THEN
    RAISE EXCEPTION 'case 2: a payload that is not an array must be refused (22023)'; END IF;
  IF pg_temp.t228_add(v_agent, NULL, v_lines) <> '22023' THEN RAISE EXCEPTION 'case 2: a missing account must be refused (22023)'; END IF;
  IF pg_temp.t228_add(v_agent, v_acc, (SELECT jsonb_agg(pg_temp.t228_line(v_d1, NULL, 'Bulk ' || g, 'ZELLE', 5, 'USD', 1, 1, 0, 'x')) FROM generate_series(1, 501) g)) <> '22023' THEN
    RAISE EXCEPTION 'case 2: more than 500 lines must be refused (22023)'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: a refused payload wrote something'; END IF;
  IF pg_temp.t228_add(v_viewer, v_acc, v_lines) <> '42501' THEN RAISE EXCEPTION 'case 2: a viewer must be refused (42501)'; END IF;
  IF pg_temp.t228_add(v_other, v_acc, v_lines) <> '42501' THEN RAISE EXCEPTION 'case 2: another account''s owner must be refused (42501)'; END IF;
  IF pg_temp.t228_add(NULL, v_acc, v_lines) <> '42501' THEN RAISE EXCEPTION 'case 2: no session must be refused (42501)'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: refused callers wrote something'; END IF;
  IF has_function_privilege('anon', 'crm_registrar_entradas_manuales(uuid,jsonb)', 'execute') THEN RAISE EXCEPTION 'case 2: anon must not execute the add'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_registrar_entradas_manuales(uuid,jsonb)', 'execute') THEN RAISE EXCEPTION 'case 2: authenticated must execute the add'; END IF;
  IF to_regprocedure('crm_sincronizar_entradas_manuales(uuid,jsonb)') IS NOT NULL THEN RAISE EXCEPTION 'case 2: the sync RPC must be gone'; END IF;
  -- an account only adds to itself
  IF pg_temp.t228_add(v_other, v_acc2, jsonb_build_array(pg_temp.t228_line(v_d1, NULL, 'Otra', 'USDT', 10, 'USD', 2600, 2500, 100, 'otra 10 usdt'))) <> 'ok' THEN
    RAISE EXCEPTION 'case 2: the other account''s owner can add to its own account'; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 2: another account''s add changed this account'; END IF;
  IF (SELECT count(*) FROM remittance_calculator_entries WHERE account_id = v_acc2 AND source = 'manual') <> 7 THEN RAISE EXCEPTION 'case 2: the other account must hold exactly its own rows'; END IF;
  RAISE NOTICE 'PASS 2: every bad figure / customer / service / currency / date / shape refused (22023) with nothing written; empty and 501 lines refused; viewer, other account, no session refused (42501); anon cannot execute; the sync RPC is gone';

  -- ---- 3. the Calculator read lists the manual entries next to the bot's; Finanzas counts and marks them ----
  SELECT count(*) INTO v_n FROM calculator_current_entries WHERE account_id = v_acc;
  IF v_n <> 6 OR (SELECT count(*) FROM calculator_current_entries WHERE account_id = v_acc AND source = 'manual') <> 3
     OR (SELECT count(*) FROM calculator_current_entries WHERE account_id = v_acc AND source = 'completed_operation') <> 3 THEN
    RAISE EXCEPTION 'case 3: the Calculator read must list the three bot entries and the three manual ones, got % rows', v_n; END IF;
  v_c1 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF (v_c1 -> 'totales' ->> 'operaciones')::int <> v_bot_n + 3 THEN RAISE EXCEPTION 'case 3: operaciones must be bot + manual, got %', v_c1 -> 'totales'; END IF;
  IF (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric <> v_bot_f + 15000 + 3333.5 + 20000
     OR (v_c1 -> 'totales' ->> 'invertido_gyd')::numeric <> v_bot_i + 12000 + 2800 + 0
     OR (v_c1 -> 'totales' ->> 'retorno_gyd')::numeric <> v_bot_r + 3000 + 533.5 + 20000 THEN
    RAISE EXCEPTION 'case 3: the totals must add the manual entries to the bot''s, got %', v_c1 -> 'totales'; END IF;
  IF (SELECT coalesce(sum((s ->> 'facturado_gyd')::numeric), 0) FROM jsonb_array_elements(v_c1 -> 'por_servicio') s WHERE s ->> 'service' = 'DIRECTO') <> 20000
     OR (SELECT (s ->> 'operaciones')::int FROM jsonb_array_elements(v_c1 -> 'por_servicio') s WHERE s ->> 'service' = 'CUP') <> 1 THEN
    RAISE EXCEPTION 'case 3: the per-service breakdown must hold the manual services, got %', v_c1 -> 'por_servicio'; END IF;
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
  IF pg_temp.t228_close(v_viewer, v_d2, v_d1) IS DISTINCT FROM v_c1 THEN RAISE EXCEPTION 'case 3: a viewer must read the same close'; END IF;
  IF (pg_temp.t228_close(v_other, v_d2, v_d1) -> 'totales' ->> 'operaciones')::int <> 7 THEN RAISE EXCEPTION 'case 3: the other account must count only its own seven manual entries'; END IF;
  RAISE NOTICE 'PASS 3: calculator_current_entries lists bot + manual entries; Finanzas totals / per-service / per-day / detail count and mark the manual ones';
  SELECT array_agg(id ORDER BY created_at, id) INTO v_ids FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual';

  -- ---- 4. correct (admin): figures change, retorno = facturado - invertido, audited; roles; Finanzas follows ----
  v_e := v_ids[1];
  IF pg_temp.t228_correct(v_agent, v_e, 1, 1) <> '42501' THEN RAISE EXCEPTION 'case 4: an agent must not correct (42501)'; END IF;
  IF pg_temp.t228_correct(v_viewer, v_e, 1, 1) <> '42501' OR pg_temp.t228_correct(v_other, v_e, 1, 1) <> '42501' OR pg_temp.t228_correct(NULL, v_e, 1, 1) <> '42501' THEN
    RAISE EXCEPTION 'case 4: viewer / other account / no session must be refused (42501)'; END IF;
  IF pg_temp.t228_correct(v_admin, v_e, -1, 1) <> '22023' OR pg_temp.t228_correct(v_admin, v_e, 1, -1) <> '22023' OR pg_temp.t228_correct(v_admin, v_e, NULL, 1) <> '22023' THEN
    RAISE EXCEPTION 'case 4: negative or missing figures must be refused (22023)'; END IF;
  v_rows := pg_temp.t228_rows(v_acc);
  IF (SELECT facturado_gyd FROM remittance_calculator_entries WHERE id = v_e) <> 15000 THEN RAISE EXCEPTION 'case 4: refused corrections changed the row'; END IF;
  IF pg_temp.t228_correct(v_admin, v_e, 18000, 14400) <> 'ok' THEN RAISE EXCEPTION 'case 4: the admin correction failed'; END IF;
  SELECT * INTO v_x FROM remittance_calculator_entries WHERE id = v_e;
  IF v_x.facturado_gyd <> 18000 OR v_x.invertido_gyd <> 14400 OR v_x.retorno_gyd <> 3600 OR v_x.status <> 'completed' OR v_x.source <> 'manual'
     OR v_x.amount <> 100 OR v_x.service <> 'ZELLE' OR v_x.customer_name <> 'Pedro Perez' OR v_x.entry_date <> v_d2 OR v_x.raw_line <> 'Pedro Perez 100 zelle (30%/120/150)' THEN
    RAISE EXCEPTION 'case 4: the correction must change only the three figures: %', to_jsonb(v_x); END IF;
  SELECT jsonb_build_object('before', before, 'after', after) INTO v_aud FROM remittance_admin_audit
   WHERE row_id = v_e AND action = 'human_calculator_correction' AND actor = v_admin::text;
  IF v_aud IS NULL OR (v_aud -> 'before' ->> 'facturado_gyd')::numeric <> 15000 OR (v_aud -> 'after' ->> 'facturado_gyd')::numeric <> 18000 THEN
    RAISE EXCEPTION 'case 4: the correction must be audited with before and after, got %', v_aud; END IF;
  v_c2 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF (v_c2 -> 'totales' ->> 'facturado_gyd')::numeric <> (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric + 3000
     OR (v_c2 -> 'totales' ->> 'retorno_gyd')::numeric <> (v_c1 -> 'totales' ->> 'retorno_gyd')::numeric + 600
     OR (v_c2 -> 'totales' ->> 'operaciones')::int <> (v_c1 -> 'totales' ->> 'operaciones')::int THEN
    RAISE EXCEPTION 'case 4: Finanzas must follow the corrected figures, got %', v_c2 -> 'totales'; END IF;
  RAISE NOTICE 'PASS 4: an admin corrects a manual entry (three figures only, audited); agent / viewer / other account / no session refused; Finanzas follows';

  -- ---- 5. delete (admin): a durable void that stops counting everywhere ----
  v_c1 := v_c2;
  v_e := v_ids[3];
  IF pg_temp.t228_delete(v_agent, v_e) <> '42501' OR pg_temp.t228_delete(v_viewer, v_e) <> '42501' OR pg_temp.t228_delete(v_other, v_e) <> '42501' OR pg_temp.t228_delete(NULL, v_e) <> '42501' THEN
    RAISE EXCEPTION 'case 5: only an admin may delete (42501)'; END IF;
  IF pg_temp.t228_delete(v_admin, gen_random_uuid()) <> 'P0002' THEN RAISE EXCEPTION 'case 5: an unknown id must give P0002'; END IF;
  IF pg_temp.t228_delete(v_admin, v_e) <> 'ok' THEN RAISE EXCEPTION 'case 5: the admin delete failed'; END IF;
  SELECT * INTO v_x FROM remittance_calculator_entries WHERE id = v_e;
  IF v_x.status <> 'void' OR v_x.deleted_at IS NULL OR v_x.deleted_by <> v_admin OR v_x.voided_at IS NULL OR v_x.void_reason NOT LIKE 'deleted by %'
     OR v_x.facturado_gyd <> 20000 OR v_x.amount <> 20000 THEN
    RAISE EXCEPTION 'case 5: the delete must be a durable void that keeps the figures: %', to_jsonb(v_x); END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_e AND action = 'human_calculator_entry_deleted' AND actor = v_admin::text) THEN
    RAISE EXCEPTION 'case 5: the delete must be audited'; END IF;
  IF pg_temp.t228_delete(v_admin, v_e) <> '22023' OR pg_temp.t228_correct(v_admin, v_e, 1, 1) <> '22023' THEN
    RAISE EXCEPTION 'case 5: a void entry can be neither deleted nor corrected (22023)'; END IF;
  IF EXISTS (SELECT 1 FROM calculator_current_entries WHERE id = v_e) OR (SELECT count(*) FROM calculator_current_entries WHERE account_id = v_acc AND source = 'manual') <> 2 THEN
    RAISE EXCEPTION 'case 5: the Calculator read must drop the deleted entry'; END IF;
  v_c2 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF (v_c2 -> 'totales' ->> 'operaciones')::int <> (v_c1 -> 'totales' ->> 'operaciones')::int - 1
     OR (v_c2 -> 'totales' ->> 'facturado_gyd')::numeric <> (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric - 20000
     OR (v_c2 -> 'totales' ->> 'retorno_gyd')::numeric <> (v_c1 -> 'totales' ->> 'retorno_gyd')::numeric - 20000
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_c2 -> 'detalle') d WHERE (d ->> 'id')::uuid = v_e)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_c2 -> 'excluidas') d WHERE (d ->> 'id')::uuid = v_e AND d ->> 'status' = 'void' AND d ->> 'source' = 'manual') THEN
    RAISE EXCEPTION 'case 5: a deleted entry must stop counting in Finanzas and stay visible as excluded, got %', v_c2 -> 'totales'; END IF;
  RAISE NOTICE 'PASS 5: an admin deletes a manual entry (durable void, audited); it stops counting in the Calculator read and in Finanzas; agent / viewer / other account / no session refused';

  -- ---- 6. guard: a manual row changes only through the correction and the deletion ----
  v_e := v_ids[2];
  v_rows := pg_temp.t228_rows(v_acc);
  FOREACH v_sql IN ARRAY ARRAY[
    format('UPDATE remittance_calculator_entries SET facturado_gyd = 1 WHERE id = %L', v_e),
    format('UPDATE remittance_calculator_entries SET amount = 1 WHERE id = %L', v_e),
    format('UPDATE remittance_calculator_entries SET status = ''void'', voided_at = now() WHERE id = %L', v_e),
    format('DELETE FROM remittance_calculator_entries WHERE id = %L', v_e),
    format('UPDATE remittance_calculator_entries SET customer_name = ''Otro'' WHERE id = %L', v_e),
    format('UPDATE remittance_calculator_entries SET source = ''completed_operation'' WHERE id = %L', v_e),
    -- the switches alone do not open anything else than what their own RPC changes
    format('SELECT set_config(''wacrm.calculator_correction'', ''true'', true); UPDATE remittance_calculator_entries SET customer_name = ''Otro'' WHERE id = %L', v_e),
    format('SELECT set_config(''wacrm.calculator_correction'', ''true'', true); UPDATE remittance_calculator_entries SET status = ''void'', voided_at = now() WHERE id = %L', v_e),
    format('SELECT set_config(''wacrm.calculator_manual_delete'', ''true'', true); UPDATE remittance_calculator_entries SET facturado_gyd = 1 WHERE id = %L', v_e),
    format('SELECT set_config(''wacrm.calculator_manual_delete'', ''true'', true); DELETE FROM remittance_calculator_entries WHERE id = %L', v_e),
    -- a void manual row never changes again, switches or not
    format('SELECT set_config(''wacrm.calculator_manual_delete'', ''true'', true); UPDATE remittance_calculator_entries SET status = ''completed'', voided_at = NULL WHERE id = %L', v_ids[3]),
    format('SELECT set_config(''wacrm.calculator_correction'', ''true'', true); UPDATE remittance_calculator_entries SET facturado_gyd = 1 WHERE id = %L', v_ids[3]),
    format('DELETE FROM remittance_calculator_entries WHERE id = %L', v_ids[3])
  ] LOOP
    v_res := pg_temp.t228_raw(v_sql);
    IF v_res NOT IN ('42501') THEN RAISE EXCEPTION 'case 6: must be refused with 42501 (got %): %', v_res, v_sql; END IF;
  END LOOP;
  IF (SELECT facturado_gyd FROM remittance_calculator_entries WHERE id = v_e) <> 3333.5 OR (SELECT status FROM remittance_calculator_entries WHERE id = v_ids[3]) <> 'void' THEN
    RAISE EXCEPTION 'case 6: a refused raw statement changed a row'; END IF;
  -- a client has no write on the table
  IF has_table_privilege('authenticated', 'remittance_calculator_entries', 'INSERT') OR has_table_privilege('authenticated', 'remittance_calculator_entries', 'UPDATE')
     OR has_table_privilege('authenticated', 'remittance_calculator_entries', 'DELETE') THEN
    RAISE EXCEPTION 'case 6: clients must have no write grant on the ledger'; END IF;
  -- the bot's rows keep their guard: a completed bot row still cannot be deleted raw
  IF pg_temp.t228_raw(format('DELETE FROM remittance_calculator_entries WHERE account_id = %L AND source = ''completed_operation''', v_acc)) <> '42501' THEN
    RAISE EXCEPTION 'case 6: a raw delete of a completed bot row must stay refused'; END IF;
  RAISE NOTICE 'PASS 6: raw UPDATE / DELETE / void of a manual row and any change of a void manual row are refused (42501), switches included; the bot rows keep their guard';

  -- ---- 7. the weekly cut archives manual + bot entries; Finanzas is identical before and after; the next week is new ----
  v_c1 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  v_rows := pg_temp.t228_rows(v_acc);
  IF to_regprocedure('crm_cerrar_semana_calculadora(uuid,text,text,numeric,numeric,numeric)') IS NOT NULL THEN RAISE EXCEPTION 'case 7: the six-argument cut must be gone'; END IF;
  IF has_function_privilege('anon', 'crm_cerrar_semana_calculadora(uuid,text,text)', 'execute') THEN RAISE EXCEPTION 'case 7: anon must not execute the cut'; END IF;
  IF pg_temp.t228_cut(v_viewer, v_acc, 'x') <> '42501' OR pg_temp.t228_cut(v_other, v_acc, 'x') <> '42501' OR pg_temp.t228_cut(NULL, v_acc, 'x') <> '42501' THEN
    RAISE EXCEPTION 'case 7: viewer / other account / no session must be refused (42501)'; END IF;
  IF pg_temp.t228_cut(v_agent, v_acc, 'Pedro Perez 100 zelle') <> 'ok' THEN RAISE EXCEPTION 'case 7: the cut failed'; END IF;
  SELECT jsonb_build_object('entries', entries, 'chat', chat_totals, 'manual', manual_totals, 'text', raw_text) INTO v_week
    FROM remittance_calculator_weeks WHERE account_id = v_acc;
  IF jsonb_array_length(v_week -> 'entries') <> 5
     OR (SELECT count(*) FROM jsonb_array_elements(v_week -> 'entries') e WHERE e ->> 'source' = 'manual' AND e ->> 'operation_id' IS NULL) <> 2
     OR (SELECT count(*) FROM jsonb_array_elements(v_week -> 'entries') e WHERE e ->> 'source' = 'completed_operation' AND e ->> 'operation_id' IS NOT NULL) <> 3
     OR (v_week -> 'chat' ->> 'count')::int <> 3 OR (v_week -> 'chat' ->> 'facturado_gyd')::numeric <> v_bot_f
     OR (v_week -> 'manual' ->> 'count')::int <> 2 OR (v_week -> 'manual' ->> 'facturado_gyd')::numeric <> 18000 + 3333.5
     OR (v_week -> 'manual' ->> 'invertido_gyd')::numeric <> 14400 + 2800 OR (v_week -> 'manual' ->> 'retorno_gyd')::numeric <> 3600 + 533.5
     OR v_week ->> 'text' <> 'Pedro Perez 100 zelle' THEN
    RAISE EXCEPTION 'case 7: the week must archive the three bot and the two live manual entries, chat totals = bot, manual totals = manual, got %', v_week; END IF;
  IF pg_temp.t228_rows(v_acc) IS DISTINCT FROM v_rows THEN RAISE EXCEPTION 'case 7: the cut changed the manual rows'; END IF;
  IF pg_temp.t228_close(v_admin, v_d2, v_d1) IS DISTINCT FROM v_c1 THEN RAISE EXCEPTION 'case 7: Finanzas changed after the cut'; END IF;
  IF (SELECT count(*) FROM calculator_current_entries WHERE account_id = v_acc) <> 0 THEN RAISE EXCEPTION 'case 7: the new week must start with no entries'; END IF;
  IF (SELECT count(*) FROM remittance_calculator_week_entries WHERE account_id = v_acc) <> 5 THEN RAISE EXCEPTION 'case 7: five entries must be archived'; END IF;
  -- entries added after the cut belong to the new week, even when dated before the cut
  IF pg_temp.t228_add(v_agent, v_acc, jsonb_build_array(
       pg_temp.t228_line(v_d2, 'Martes 6', 'Nueva', 'USDT', 10, 'USD', 2600, 2500, 100, 'Nueva 10 usdt'),
       pg_temp.t228_line(v_d1, 'Miércoles 7', 'Nueva Dos', 'ZELLE', 20, 'USD', 5000, 4000, 1000, 'Nueva Dos 20 zelle'))) <> 'ok' THEN
    RAISE EXCEPTION 'case 7: the add of the new week failed'; END IF;
  IF (SELECT count(*) FROM calculator_current_entries WHERE account_id = v_acc AND source = 'manual') <> 2
     OR EXISTS (SELECT 1 FROM calculator_current_entries c JOIN remittance_calculator_week_entries w ON w.entry_id = c.id) THEN
    RAISE EXCEPTION 'case 7: the new week must list the two new entries only'; END IF;
  v_c2 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  IF (v_c2 -> 'totales' ->> 'operaciones')::int <> (v_c1 -> 'totales' ->> 'operaciones')::int + 2
     OR (v_c2 -> 'totales' ->> 'facturado_gyd')::numeric <> (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric + 7600 THEN
    RAISE EXCEPTION 'case 7: Finanzas must count the archived and the new manual entries, got %', v_c2 -> 'totales'; END IF;
  -- the archived week reads the same; a second cut archives only what came after
  SELECT jsonb_build_object('entries', entries, 'chat', chat_totals, 'manual', manual_totals, 'text', raw_text) INTO v_week2
    FROM remittance_calculator_weeks WHERE account_id = v_acc AND raw_text = 'Pedro Perez 100 zelle';
  IF v_week2 IS DISTINCT FROM v_week THEN RAISE EXCEPTION 'case 7: the archived week shows something else now'; END IF;
  IF pg_temp.t228_cut(v_agent, v_acc, '') <> 'ok' THEN RAISE EXCEPTION 'case 7: the second cut failed'; END IF;
  SELECT jsonb_build_object('entries', entries, 'manual', manual_totals, 'chat', chat_totals) INTO v_week2
    FROM remittance_calculator_weeks WHERE account_id = v_acc AND raw_text = '';
  IF jsonb_array_length(v_week2 -> 'entries') <> 2 OR (v_week2 -> 'manual' ->> 'count')::int <> 2 OR (v_week2 -> 'chat' ->> 'count')::int <> 0 THEN
    RAISE EXCEPTION 'case 7: the second cut must archive only the two new manual entries, got %', v_week2; END IF;
  IF pg_temp.t228_close(v_admin, v_d2, v_d1) IS DISTINCT FROM v_c2 THEN RAISE EXCEPTION 'case 7: Finanzas changed after the second cut'; END IF;
  RAISE NOTICE 'PASS 7: the cut archives bot + manual entries (chat totals = bot, manual totals = manual), they stay in the ledger, Finanzas is identical before and after, entries added after the cut open the new week';

  -- ---- 8. Finanzas is exactly the ledger: the close equals an independent sum of the completed rows, bot and manual ----
  v_c1 := pg_temp.t228_close(v_admin, v_d2, v_d1);
  SELECT count(*), coalesce(sum(facturado_gyd), 0), coalesce(sum(invertido_gyd), 0), coalesce(sum(retorno_gyd), 0) INTO v_n, v_bot_f, v_bot_i, v_bot_r
    FROM remittance_calculator_entries
   WHERE account_id = v_acc AND status = 'completed' AND source IN ('completed_operation', 'manual')
     AND (coalesce(completed_at AT TIME ZONE 'America/Guyana', entry_date::timestamp))::date BETWEEN v_d2 AND v_d1;
  IF (v_c1 -> 'totales' ->> 'operaciones')::int <> v_n OR (v_c1 -> 'totales' ->> 'facturado_gyd')::numeric <> v_bot_f
     OR (v_c1 -> 'totales' ->> 'invertido_gyd')::numeric <> v_bot_i OR (v_c1 -> 'totales' ->> 'retorno_gyd')::numeric <> v_bot_r THEN
    RAISE EXCEPTION 'case 8: the close must equal the sum of the completed ledger rows, got % vs % / % / % / %', v_c1 -> 'totales', v_n, v_bot_f, v_bot_i, v_bot_r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_c1 -> 'detalle') d WHERE d ->> 'source' IS NULL)
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_c1 -> 'excluidas') d WHERE d ->> 'source' IS NULL) THEN
    RAISE EXCEPTION 'case 8: every detail and excluded row carries its source'; END IF;
  RAISE NOTICE 'PASS 8: the Finanzas close equals the sum of the completed ledger rows (bot and manual) and every row carries its source';

  -- ---- 9. every service the manual calculator can produce is accepted ----
  -- the parser (src/lib/calculator/web-calculator.ts) emits CUP, ZELLE, MLC, TROPICAL, CLASICA, USDT, SALDO MOVIL (ledger SALDO_MOVIL),
  -- RECARGA and, for the direct lines (visa, ext, trabajo, estudiante, trad, combo, pasaje), the group TRAMITES / COMBOS / SERVICIOS (ledger DIRECTO).
  v_lines := '[]'::jsonb; v_n := 0;
  FOREACH v_svc IN ARRAY ARRAY['CUP', 'ZELLE', 'MLC', 'TROPICAL', 'CLASICA', 'USDT', 'SALDO_MOVIL', 'RECARGA', 'DIRECTO'] LOOP
    v_n := v_n + 1;
    v_lines := v_lines || jsonb_build_array(pg_temp.t228_line(v_d1, NULL, 'Cliente ' || v_svc, v_svc, 10, CASE v_svc WHEN 'CUP' THEN 'CUP' WHEN 'DIRECTO' THEN 'GYD' WHEN 'RECARGA' THEN 'REC' WHEN 'SALDO_MOVIL' THEN 'REC' ELSE 'USD' END, 100, 60, 40, 'line ' || v_svc));
  END LOOP;
  IF pg_temp.t228_add(v_agent, v_acc, v_lines) <> 'ok' THEN RAISE EXCEPTION 'case 9: a service the manual calculator produces was refused'; END IF;
  SELECT count(DISTINCT service) INTO v_n FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND entry_date = v_d1 AND customer_name LIKE 'Cliente %';
  IF v_n <> 9 THEN RAISE EXCEPTION 'case 9: nine services expected, got %', v_n; END IF;
  RAISE NOTICE 'PASS 9: every service the manual calculator can produce is accepted';

  RAISE NOTICE 'manual-entries: ALL PASS';
END $$;

ROLLBACK;
