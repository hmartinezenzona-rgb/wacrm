-- =====================================================================
-- Assertion for migration 351 (history search, status groups and counts: crm_historial_operaciones / crm_historial_estados).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Fixtures build their own
-- account, user, two contacts and five operations (one per status); every check isolates them with a unique search token.
-- Cases: 1 grants (anon cannot execute), 2 old function untouched, 3 shape + operation time + conversation id,
-- 4 search by name / phone digits / operation id prefix / trim / case / no match, 5 status groups, 6 counts, 7 limit cap,
-- 8 service filter still works, 9 date range.
-- =====================================================================
CREATE FUNCTION pg_temp.mk_op(p_acc uuid, p_conv uuid, p_ct uuid, p_status text, p_service text, p_dm text, p_types text[])
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid; v_i int;
BEGIN
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, completed_at)
  VALUES (p_acc, p_conv, p_ct, p_status, p_service, 'GYD', 10000, p_dm, CASE WHEN p_status = 'completed' THEN now() END) RETURNING id INTO v_op;
  FOR v_i IN 1 .. coalesce(array_length(p_types, 1), 0) LOOP
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, position, block_index, source, status)
    VALUES (v_op, p_types[v_i], 'Search Recipient ' || v_i, v_i, v_i, 'manual', 'vigente');
  END LOOP;
  RETURN v_op;
END $f$;

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc uuid; v_ct uuid; v_ct2 uuid; v_conv uuid; v_conv2 uuid;
  v_hash text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_comp uuid; v_prog uuid; v_prog2 uuid; v_inc uuid; v_can uuid; v_other uuid;
  v_n int; v_c bigint; v_got text; v_day date;
BEGIN
  -- 1. Grants: the three new functions follow the old one (authenticated + service_role, never anon).
  IF has_function_privilege('anon', 'public.crm_historial_operaciones(date,date,text,text,text,integer,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crm_historial_estados(date,date,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crm_historial_estado_grupo(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 1: anon must not execute the new history functions'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.crm_historial_operaciones(date,date,text,text,text,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.crm_historial_operaciones(date,date,text,text,text,integer,integer)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.crm_historial_estados(date,date,text,text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.crm_historial_estados(date,date,text,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 1: authenticated and service_role must execute the new history functions'; END IF;

  -- 2. The old function keeps its shape.
  SELECT pg_get_function_result('public.cerebro_dashboard_historial(date,date,text,integer,integer)'::regprocedure) INTO v_got;
  IF v_got <> 'TABLE(dia date, service_type text, status text, cliente text, telefono text, monto_gyd numeric, beneficiario text, tarjeta text, operation_id uuid, total bigint, servicio text)' THEN
    RAISE EXCEPTION 'case 2: the old history changed: %', v_got; END IF;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hs-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'history search account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'history search agent', 'hs-' || v_user || '@test.invalid', v_acc, 'agent');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '+592 600-3510', 'Zq351 Cliente') RETURNING id INTO v_ct;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5921239999', 'Mm351 Otro') RETURNING id INTO v_ct2;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct2) RETURNING id INTO v_conv2;

  -- 096's completion guard coerces an automation insert of 'completed' to 'incident'; a human actor passes.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_comp  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'completed', 'remesa', 'cuban_card', ARRAY['cuban_card']);
  v_prog  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'zelle', ARRAY['zelle']);
  v_prog2 := pg_temp.mk_op(v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'zelle', ARRAY['zelle', 'zelle']);
  v_inc   := pg_temp.mk_op(v_acc, v_conv, v_ct, 'incident', 'remesa', 'cuban_card', ARRAY['cuban_card']);
  v_can   := pg_temp.mk_op(v_acc, v_conv, v_ct, 'cancelled', 'remesa', 'cuban_card', ARRAY['cuban_card']);
  v_other := pg_temp.mk_op(v_acc, v_conv2, v_ct2, 'completed', 'remesa', 'cuban_card', ARRAY['cuban_card']);

  PERFORM set_config('request.jwt.claims', '', true);

  -- 3. Shape, conversation id and operation time.
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, NULL, 200, 0) t
   WHERE t.operation_id = v_comp AND t.conversation_id = v_conv AND t.operacion_at IS NOT NULL AND t.total >= 6;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 3: expected the completed fixture once with conversation_id and operacion_at, got %', v_n; END IF;
  SELECT t.dia INTO v_day FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351', 200, 0) t WHERE t.operation_id = v_comp;
  IF v_day IS DISTINCT FROM (SELECT (operacion_at AT TIME ZONE 'America/Guyana')::date FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351', 200, 0) WHERE operation_id = v_comp) THEN
    RAISE EXCEPTION 'case 3: dia must be the Guyana day of operacion_at'; END IF;

  -- 4. Search.
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351', 200, 0) t;
  IF v_n <> 5 THEN RAISE EXCEPTION 'case 4: name search (lowercase) expected 5 operations, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, '   ZQ351 cli  ', 200, 0) t;
  IF v_n <> 5 THEN RAISE EXCEPTION 'case 4: trimmed, upper-case name search expected 5 operations, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, '600-3510', 200, 0) t;
  IF v_n <> 5 THEN RAISE EXCEPTION 'case 4: phone search by digits expected 5 operations, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, '6003510', 200, 0) t;
  IF v_n <> 5 THEN RAISE EXCEPTION 'case 4: phone search without separators expected 5 operations, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, upper(left(v_inc::text, 8)), 200, 0) t;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 4: operation id prefix expected exactly the incident fixture, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, left(v_inc::text, 8), 200, 0) t WHERE t.operation_id = v_inc;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 4: operation id prefix did not return the incident fixture'; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351%', 200, 0) t;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: LIKE wildcards must not be interpreted, got % rows', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'no-such-client-351', 200, 0) t;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: no match expected, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, '   ', 200, 0) t WHERE t.operation_id = v_other;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 4: blank search must not filter'; END IF;

  -- 5. Status groups.
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, 'completed', 'zq351', 200, 0) t;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: completed expected 1, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, 'in_progress', 'zq351', 200, 0) t
   WHERE t.operation_id IN (v_prog, v_prog2);
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 5: in_progress expected the two in-flight fixtures, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, 'incident', 'zq351', 200, 0) t WHERE t.operation_id = v_inc;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: incident expected the incident fixture, got %', v_n; END IF;
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, 'cancelled', 'zq351', 200, 0) t WHERE t.operation_id = v_can;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: cancelled expected the cancelled fixture, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, 'all', 'zq351', 200, 0) t;
  IF v_n <> 6 THEN RAISE EXCEPTION 'case 5: all expected 6 rows (the two-recipient operation shows twice), got %', v_n; END IF;
  IF EXISTS (SELECT 1 FROM crm_historial_operaciones(NULL, NULL, NULL, 'completed', 'zq351', 200, 0) t WHERE t.estado_grupo <> 'completed') THEN
    RAISE EXCEPTION 'case 5: estado_grupo mismatch'; END IF;
  IF crm_historial_estado_grupo('transferring') <> 'in_progress' OR crm_historial_estado_grupo('awaiting_deposit') <> 'in_progress'
     OR crm_historial_estado_grupo('deposit_received') <> 'in_progress' OR crm_historial_estado_grupo('deposit_verification') <> 'in_progress' THEN
    RAISE EXCEPTION 'case 5: in-flight statuses must map to in_progress'; END IF;

  -- 6. Counts under the same filters except status (rows, like total).
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq351') WHERE grupo = 'completed';
  IF v_c IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'case 6: completed count expected 1, got %', v_c; END IF;
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq351') WHERE grupo = 'in_progress';
  IF v_c IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'case 6: in_progress count expected 3 rows, got %', v_c; END IF;
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq351') WHERE grupo = 'incident';
  IF v_c IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'case 6: incident count expected 1, got %', v_c; END IF;
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq351') WHERE grupo = 'cancelled';
  IF v_c IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'case 6: cancelled count expected 1, got %', v_c; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_estados(NULL, NULL, NULL, 'no-such-client-351');
  IF v_n <> 4 THEN RAISE EXCEPTION 'case 6: the four groups must always be returned, got % rows', v_n; END IF;
  SELECT sum(cantidad) INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'no-such-client-351');
  IF v_c <> 0 THEN RAISE EXCEPTION 'case 6: no match must count 0, got %', v_c; END IF;

  -- 7. The limit is capped at 200 and total counts the whole filtered set.
  SELECT count(*), max(t.total) INTO v_n, v_c FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351', 2, 0) t;
  IF v_n <> 2 OR v_c <> 6 THEN RAISE EXCEPTION 'case 7: limit 2 expected 2 rows of total 6, got % of %', v_n, v_c; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351', 100000, 0) t;
  IF v_n > 200 THEN RAISE EXCEPTION 'case 7: limit cap broken, got % rows', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq351', 200, 5) t;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 7: offset 5 of 6 expected 1 row, got %', v_n; END IF;

  -- 8. The service filter still works next to the search.
  SELECT count(DISTINCT t.operation_id) INTO v_n FROM crm_historial_operaciones(NULL, NULL, 'ZELLE', NULL, 'zq351', 200, 0) t;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 8: ZELLE + search expected 2 operations, got %', v_n; END IF;
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, 'ZELLE', 'zq351') WHERE grupo = 'in_progress';
  IF v_c IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'case 8: ZELLE in_progress count expected 3, got %', v_c; END IF;

  -- 9. Date range: tomorrow onwards finds none of the fixtures, today finds them.
  SELECT count(*) INTO v_n FROM crm_historial_operaciones((now() AT TIME ZONE 'America/Guyana')::date + 2, NULL, NULL, NULL, 'zq351', 200, 0) t;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 9: future range expected 0, got %', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones((now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 1, NULL, NULL, 'zq351', 200, 0) t;
  IF v_n <> 6 THEN RAISE EXCEPTION 'case 9: current range expected 6 rows, got %', v_n; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
