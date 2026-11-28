-- =====================================================================
-- Assertion for migration 229 (Finanzas history names the service; the board keeps awaiting_deposit / deposit_received).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Fixtures build their own account, user, contact and
-- operations. Run it as: BEGIN; \i history-service-and-board-statuses.sql; ROLLBACK;
--
-- The history reads every account (the view has no account filter), so each check looks only at this fixture's operations
-- (by operation id) and compares totals against the same RPC called without a filter. The helper lives in pg_temp.
-- =====================================================================
CREATE FUNCTION pg_temp.mk_op(p_acc uuid, p_conv uuid, p_ct uuid, p_status text, p_service text, p_dm text, p_types text[])
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid; v_i int;
BEGIN
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (p_acc, p_conv, p_ct, p_status, p_service, 'GYD', 10000, p_dm) RETURNING id INTO v_op;
  FOR v_i IN 1 .. coalesce(array_length(p_types, 1), 0) LOOP
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, position, block_index, source, status)
    VALUES (v_op, p_types[v_i], 'History Recipient ' || v_i, v_i, v_i, 'manual', 'vigente');
  END LOOP;
  RETURN v_op;
END $f$;

-- servicio the history reports for one operation (every row of an operation must agree)
CREATE FUNCTION pg_temp.servicio_of(p_op uuid) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_vals text[];
BEGIN
  EXECUTE 'SELECT array_agg(DISTINCT t.servicio) FROM cerebro_dashboard_historial(NULL, NULL, NULL, 1000, 0) t WHERE t.operation_id = $1'
    INTO v_vals USING p_op;
  IF v_vals IS NULL THEN RETURN '<no row>'; END IF;
  IF array_length(v_vals, 1) > 1 THEN RETURN '<disagree: ' || array_to_string(v_vals, ',') || '>'; END IF;
  RETURN v_vals[1];
END $f$;

DO $$
DECLARE
  v_user  uuid := gen_random_uuid();
  v_acc   uuid;
  v_ct    uuid;
  v_conv  uuid;
  v_hash  text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_cup uuid; v_zel uuid; v_cla uuid; v_tro uuid; v_efe uuid; v_rec uuid; v_sal uuid; v_com uuid; v_vis uuid;
  v_mix uuid; v_tra uuid; v_mex uuid; v_bare uuid; v_two uuid;
  v_rem   uuid[];
  v_n     int;
  v_total bigint;
  v_all   bigint;
  v_b1 uuid; v_b2 uuid; v_b3 uuid; v_b4 uuid;
  v_order uuid[];
  v_got   text;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hist-a-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'history service account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'history service agent', 'hist-a-' || v_user || '@test.invalid', v_acc, 'agent');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900229', 'History Service Customer') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- Permissions stay exactly as 088/088b left them.
  IF NOT has_function_privilege('authenticated', 'public.cerebro_dashboard_historial(date,date,text,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_dashboard_historial(date,date,text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'grants: authenticated and service_role must execute the history'; END IF;
  IF has_function_privilege('anon', 'public.cerebro_dashboard_historial(date,date,text,integer,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'grants: anon must not execute the history'; END IF;

  -- Shape: the old columns keep their order and types, servicio is appended last.
  SELECT pg_get_function_result('public.cerebro_dashboard_historial(date,date,text,integer,integer)'::regprocedure) INTO v_got;
  IF v_got <> 'TABLE(dia date, service_type text, status text, cliente text, telefono text, monto_gyd numeric, beneficiario text, tarjeta text, operation_id uuid, total bigint, servicio text)' THEN
    RAISE EXCEPTION 'shape: unexpected result columns: %', v_got; END IF;

  -- Fixture: one operation per service, all ready_to_transfer.
  v_cup  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'cuban_card', ARRAY['cuban_card']);
  v_zel  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'zelle',      ARRAY['zelle']);
  v_cla  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'clasica',    ARRAY['clasica']);
  v_tro  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'tropical',   ARRAY['tropical']);
  v_efe  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'efectivo_usd', ARRAY['efectivo_usd']);
  v_rec  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'recarga', NULL,         ARRAY['recarga']);
  v_sal  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'saldo',   NULL,         ARRAY['recarga']);
  v_com  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'combo',   NULL,         ARRAY['combo']);
  v_vis  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'visa',    NULL,         NULL);
  v_mix  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'multiple_distribution', ARRAY['cuban_card', 'zelle']);
  v_tra  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'traduccion', NULL,      NULL);
  v_mex  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'mexico',  NULL,         NULL);
  v_bare := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  NULL,         NULL);
  -- Two recipients of the SAME kind: still one kind (ZELLE), and two rows (the grain stays one row per recipient).
  v_two  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa',  'zelle',      ARRAY['zelle', 'zelle']);

  -- 1. The ledger-style service of each operation.
  FOR v_got IN SELECT unnest(ARRAY[
      'cup:'    || v_cup, 'zelle:' || v_zel, 'clasica:' || v_cla, 'tropical:' || v_tro, 'efectivo:' || v_efe,
      'recarga:' || v_rec, 'saldo:' || v_sal, 'combo:' || v_com, 'visa:' || v_vis, 'mixta:' || v_mix,
      'traduccion:' || v_tra, 'mexico:' || v_mex, 'bare:' || v_bare, 'two:' || v_two]) LOOP
    DECLARE
      v_key text := split_part(v_got, ':', 1);
      v_op  uuid := split_part(v_got, ':', 2)::uuid;
      v_exp text := CASE v_key
        WHEN 'cup' THEN 'CUP' WHEN 'zelle' THEN 'ZELLE' WHEN 'clasica' THEN 'CLASICA' WHEN 'tropical' THEN 'TROPICAL'
        WHEN 'efectivo' THEN 'EFECTIVO' WHEN 'recarga' THEN 'RECARGA' WHEN 'saldo' THEN 'SALDO_MOVIL' WHEN 'combo' THEN 'COMBO'
        WHEN 'visa' THEN 'VISA' WHEN 'mixta' THEN 'MIXTA' WHEN 'traduccion' THEN 'TRADUCCION' WHEN 'mexico' THEN 'MEXICO'
        WHEN 'bare' THEN 'REMESA' WHEN 'two' THEN 'ZELLE' END;
      v_act text := pg_temp.servicio_of(v_op);
    BEGIN
      IF v_act IS DISTINCT FROM v_exp THEN
        RAISE EXCEPTION 'case 1 (%): expected servicio %, got %', v_key, v_exp, v_act; END IF;
    END;
  END LOOP;

  -- 2. The row grain is unchanged: the operation with two recipients still shows twice, the one without recipients once.
  SELECT count(*) INTO v_n FROM cerebro_dashboard_historial(NULL, NULL, NULL, 1000, 0) t WHERE t.operation_id = v_two;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 2: two recipients should be two rows, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM cerebro_dashboard_historial(NULL, NULL, NULL, 1000, 0) t WHERE t.operation_id = v_vis;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 2: a visa has one row, got %', v_n; END IF;

  -- 3. Filter by a ledger-style value: only CUP rows, and total counts the whole filtered set.
  SELECT count(*), max(t.total) INTO v_n, v_total FROM cerebro_dashboard_historial(NULL, NULL, 'CUP', 1000, 0) t;
  IF v_n = 0 OR v_total IS DISTINCT FROM v_n THEN
    RAISE EXCEPTION 'case 3: CUP rows % vs total % (expected equal, page is not truncated here)', v_n, v_total; END IF;
  IF EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'CUP', 1000, 0) t WHERE t.servicio <> 'CUP') THEN
    RAISE EXCEPTION 'case 3: a non-CUP row came back for the CUP filter'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'CUP', 1000, 0) t WHERE t.operation_id = v_cup) THEN
    RAISE EXCEPTION 'case 3: the CUP fixture is missing from the CUP filter'; END IF;
  IF EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'CUP', 1000, 0) t WHERE t.operation_id IN (v_zel, v_mix, v_rec, v_vis)) THEN
    RAISE EXCEPTION 'case 3: a non-CUP fixture came back for the CUP filter'; END IF;
  -- total stays the filtered count when the page is smaller than the set (limit 1 offset 0 and a later offset)
  SELECT max(t.total) INTO v_all FROM cerebro_dashboard_historial(NULL, NULL, 'CUP', 1, 0) t;
  IF v_all IS DISTINCT FROM v_total THEN RAISE EXCEPTION 'case 3: total % on a 1-row page, expected %', v_all, v_total; END IF;
  -- lowercase ledger value works too
  SELECT count(*) INTO v_n FROM cerebro_dashboard_historial(NULL, NULL, 'zelle', 1000, 0) t WHERE t.operation_id = v_zel;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 3: lowercase zelle filter, got % rows of the fixture', v_n; END IF;
  -- the mixed and the new-vocabulary values
  IF NOT EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'MIXTA', 1000, 0) t WHERE t.operation_id = v_mix) THEN
    RAISE EXCEPTION 'case 3: MIXTA filter misses the mixed operation'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'SALDO_MOVIL', 1000, 0) t WHERE t.operation_id = v_sal) THEN
    RAISE EXCEPTION 'case 3: SALDO_MOVIL filter misses the saldo'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'TRADUCCION', 1000, 0) t WHERE t.operation_id = v_tra) THEN
    RAISE EXCEPTION 'case 3: TRADUCCION filter misses the translation'; END IF;

  -- 4. The old service_type values keep working: 'remesa' returns every remittance (whatever its rail), no other service.
  SELECT array_agg(DISTINCT t.operation_id) INTO v_rem
    FROM cerebro_dashboard_historial(NULL, NULL, 'remesa', 1000, 0) t
   WHERE t.operation_id IN (v_cup, v_zel, v_cla, v_tro, v_efe, v_mix, v_bare, v_two, v_rec, v_sal, v_com, v_vis, v_tra, v_mex);
  IF v_rem IS NULL OR array_length(v_rem, 1) <> 8 OR NOT (v_rem @> ARRAY[v_cup, v_zel, v_cla, v_tro, v_efe, v_mix, v_bare, v_two]) THEN
    RAISE EXCEPTION 'case 4: the remesa filter should return the 8 remittance fixtures, got %', v_rem; END IF;
  IF EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'remesa', 1000, 0) t WHERE t.service_type <> 'remesa') THEN
    RAISE EXCEPTION 'case 4: a non-remittance row came back for the remesa filter'; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'recarga', 1000, 0) t WHERE t.operation_id = v_rec)
     OR EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'recarga', 1000, 0) t WHERE t.operation_id = v_sal) THEN
    RAISE EXCEPTION 'case 4: the recarga filter should match the recarga and not the saldo'; END IF;
  -- no filter: every fixture is there; an unknown value returns nothing
  IF (SELECT count(DISTINCT t.operation_id) FROM cerebro_dashboard_historial(NULL, NULL, NULL, 1000, 0) t
       WHERE t.operation_id IN (v_cup, v_zel, v_cla, v_tro, v_efe, v_rec, v_sal, v_com, v_vis, v_mix, v_tra, v_mex, v_bare, v_two)) <> 14 THEN
    RAISE EXCEPTION 'case 4: the unfiltered history misses fixtures'; END IF;
  IF EXISTS (SELECT 1 FROM cerebro_dashboard_historial(NULL, NULL, 'NOPE', 1000, 0)) THEN
    RAISE EXCEPTION 'case 4: an unknown filter value returned rows'; END IF;

  -- 5. The old four-argument call of the deployed app still resolves and answers.
  SELECT count(*) INTO v_n FROM cerebro_dashboard_historial(p_desde := NULL, p_hasta := NULL, p_servicio := 'remesa', p_limite := 200);
  IF v_n = 0 THEN RAISE EXCEPTION 'case 5: the four-argument call returned nothing'; END IF;

  -- 6. The board keeps awaiting_deposit and deposit_received, ranked with their neighbours.
  --    since order is collecting < verification < awaiting < received, so the rank decides the order:
  --    rank 1 (collecting, awaiting) then rank 2 (verification, received).
  v_b1 := pg_temp.mk_op(v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'zelle', NULL);
  PERFORM pg_sleep(0.05);
  v_b2 := pg_temp.mk_op(v_acc, v_conv, v_ct, 'deposit_verification', 'remesa', 'zelle', NULL);
  PERFORM pg_sleep(0.05);
  v_b3 := pg_temp.mk_op(v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'zelle', NULL);
  PERFORM pg_sleep(0.05);
  v_b4 := pg_temp.mk_op(v_acc, v_conv, v_ct, 'deposit_received', 'remesa', 'zelle', NULL);
  -- the history fixtures are on this account's board too; keep only the four board fixtures
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT array_agg(t.operation_id ORDER BY t.rn) INTO v_order
    FROM (SELECT b.operation_id, row_number() OVER () AS rn FROM crm_tablero_operaciones() b) t
   WHERE t.operation_id IN (v_b1, v_b2, v_b3, v_b4);
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_order IS NULL OR array_length(v_order, 1) <> 4 THEN
    RAISE EXCEPTION 'case 6: awaiting_deposit / deposit_received are missing from the board: %', v_order; END IF;
  IF v_order <> ARRAY[v_b1, v_b3, v_b2, v_b4] THEN
    RAISE EXCEPTION 'case 6: wrong board order, expected [collecting, awaiting, verification, received], got %', v_order; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
