-- history-readiness.sql — self-reverting assertion for
-- 102_operations_history_and_delivery_readiness.sql
--
-- Proves:
--   1. crm_beneficiarios_completos: the completeness rule (zelle needs
--      name+zelle_account, everything else needs card_number+phone,
--      whitespace-only counts as empty, zero vigente beneficiaries is
--      never complete).
--   2. crm_operaciones_de_conversacion, as a viewer, surfaces a live
--      operation with operation_is_history=false and NULL delivery
--      columns, then — once delivered via crm_entregar_operacion — the
--      SAME operation with operation_is_history=true,
--      operation_delivery_mode='proof_sent', operation_delivered_at set,
--      and the resolver no longer counting it as live.
--   3. Of 11 completed remesa operations in one conversation, only the 10
--      most recently completed appear; a cancelled operation never does.
--   4. operation_beneficiaries_complete reflects the rule for open ops.
--   5. crm_entregar_operacion refuses a ready_to_transfer operation whose
--      beneficiary data is incomplete (or absent) with 22023 'beneficiary
--      data is incomplete', leaving the deal/operation/audit trail
--      untouched.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own
-- pipeline/stage/cerebro_config fixtures via ON CONFLICT DO NOTHING (same
-- ids as delivery.sql) so it can run alongside or independently of the
-- other assertion files.

SAVEPOINT history_readiness;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista          CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada      CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_owner uuid;

  v_fail_count     integer := 0;
  v_row_count      integer;
  v_distinct_ops   integer;
  v_bool           boolean;
  v_result         jsonb;
  v_stage          uuid;
  v_op_status      text;

  -- ---- case 1 fixtures ----
  v_c1_conv        uuid;
  v_c1_contact     uuid;
  v_op_zelle_ok       uuid;
  v_op_zelle_noacct   uuid;
  v_op_cuba_ok        uuid;
  v_op_cuba_nophone   uuid;
  v_op_none           uuid;
  v_op_mixed          uuid;
  v_op_whitespace     uuid;

  -- ---- case 2 fixtures ----
  v_c2_conv        uuid;
  v_c2_contact     uuid;
  v_deal_c2        uuid;
  v_op_c2          uuid;
  v_completed_at   timestamptz;

  -- ---- case 3 fixtures ----
  v_c3_conv        uuid;
  v_c3_contact     uuid;
  v_completed_ops  uuid[] := ARRAY[]::uuid[];
  v_cancelled_op   uuid;
  v_deal_i         uuid;
  v_op_i           uuid;
  i                integer;

  -- ---- case 4 fixtures ----
  v_c4_conv        uuid;
  v_c4_contact     uuid;
  v_op_c4_complete   uuid;
  v_op_c4_incomplete uuid;

  -- ---- case 5 fixtures ----
  v_c5_conv        uuid;
  v_c5_contact     uuid;
  v_deal_c5a       uuid; v_op_c5a uuid;  -- incomplete beneficiary
  v_deal_c5b       uuid; v_op_c5b uuid;  -- no beneficiaries
BEGIN
  -- ---- shared fixtures --------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see corrections.sql's fixture comment for why.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hist-owner-'  || v_owner_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hist-agent-'  || v_agent_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'hist-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'history-readiness test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user,  'hist owner',  'hist-owner-'  || v_owner_user  || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user,  'hist agent',  'hist-agent-'  || v_agent_user  || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'hist viewer', 'hist-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista, v_pipeline_id, 'Lista para transferir', 50) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_entregada, v_pipeline_id, 'Entregada', 60) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 90) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() / notify_deal_stage_change() need a non-null
  -- notify_url; point them at a loopback no-op (our transaction never
  -- commits, so pg_net's worker never actually dispatches these).
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/history-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'history-noop') ON CONFLICT (clave) DO NOTHING;

  RAISE NOTICE 'history-readiness: fixtures ready (account=%)', v_account_id;

  -- =======================================================================
  -- Case 1: crm_beneficiarios_completos
  -- =======================================================================
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000601', v_account_id) RETURNING id INTO v_c1_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_c1_contact, v_account_id) RETURNING id INTO v_c1_conv;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_zelle_ok;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_zelle_ok, 'zelle', 'Zelle Complete', 'zelle-ok@example.invalid', 1, 1, 'vigente');

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_zelle_noacct;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_zelle_noacct, 'zelle', 'Zelle No Account', NULL, 1, 1, 'vigente');

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_cuba_ok;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, card_number, phone, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_cuba_ok, 'cuban_card', 'Cuba Complete', '1111222233334444', '15551234567', 1, 1, 'vigente');

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_cuba_nophone;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, card_number, phone, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_cuba_nophone, 'cuban_card', 'Cuba No Phone', '1111222233334444', NULL, 1, 1, 'vigente');

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_none;
  -- v_op_none deliberately has zero beneficiaries.

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_mixed;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_mixed, 'zelle', 'Mixed Complete', 'mixed-ok@example.invalid', 1, 1, 'vigente');
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, card_number, phone, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_mixed, 'cuban_card', 'Mixed Incomplete', '1111222233334444', NULL, 1, 2, 'vigente');

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c1_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_whitespace;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_whitespace, 'zelle', '   ', 'whitespace-ok@example.invalid', 1, 1, 'vigente');

  IF crm_beneficiarios_completos(v_op_zelle_ok) IS NOT TRUE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 zelle complete] expected true';
  ELSE
    RAISE NOTICE 'PASS [c1 zelle complete] true';
  END IF;

  IF crm_beneficiarios_completos(v_op_zelle_noacct) IS NOT FALSE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 zelle missing account] expected false';
  ELSE
    RAISE NOTICE 'PASS [c1 zelle missing account] false';
  END IF;

  IF crm_beneficiarios_completos(v_op_cuba_ok) IS NOT TRUE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 cuba complete] expected true';
  ELSE
    RAISE NOTICE 'PASS [c1 cuba complete] true';
  END IF;

  IF crm_beneficiarios_completos(v_op_cuba_nophone) IS NOT FALSE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 cuba missing phone] expected false';
  ELSE
    RAISE NOTICE 'PASS [c1 cuba missing phone] false';
  END IF;

  IF crm_beneficiarios_completos(v_op_none) IS NOT FALSE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 no beneficiaries] expected false';
  ELSE
    RAISE NOTICE 'PASS [c1 no beneficiaries] false';
  END IF;

  IF crm_beneficiarios_completos(v_op_mixed) IS NOT FALSE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 mixed, one incomplete] expected false';
  ELSE
    RAISE NOTICE 'PASS [c1 mixed, one incomplete] false';
  END IF;

  IF crm_beneficiarios_completos(v_op_whitespace) IS NOT FALSE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c1 whitespace-only name] expected false';
  ELSE
    RAISE NOTICE 'PASS [c1 whitespace-only name] false';
  END IF;

  -- =======================================================================
  -- Case 2: read RPC before/after delivering a complete operation
  -- =======================================================================
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000602', v_account_id) RETURNING id INTO v_c2_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_c2_contact, v_account_id) RETURNING id INTO v_c2_conv;

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'history fixture c2', v_account_id, v_c2_conv, v_c2_contact, 5000, 'GYD')
  RETURNING id INTO v_deal_c2;
  SELECT id INTO v_op_c2 FROM remittance_operations WHERE deal_id = v_deal_c2;
  IF v_op_c2 IS NULL THEN
    RAISE EXCEPTION 'history-readiness: fixture setup failed — no operation created for deal %', v_deal_c2;
  END IF;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_c2, 'zelle', 'Case2 Beneficiary', 'case2-ok@example.invalid', 1, 1, 'vigente');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  IF NOT EXISTS (
    SELECT 1 FROM crm_operaciones_de_conversacion(v_c2_conv)
     WHERE operation_id = v_op_c2
       AND operation_is_history = false
       AND operation_delivery_mode IS NULL
       AND operation_delivered_at IS NULL
       AND operation_beneficiaries_complete = true
       AND resolver_resultado = 'unica'
       AND resolver_operation_id = v_op_c2
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c2 before delivery] expected op_c2 as live, non-history, no delivery info, complete beneficiaries, resolver=unica';
  ELSE
    RAISE NOTICE 'PASS [c2 before delivery] op_c2 surfaces as live with resolver=unica';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_entregar_operacion(v_op_c2, jsonb_build_object('mode', 'proof_sent', 'wamid', 'wamid.HIST', 'path', 'account/x/hist-proof.png')) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  v_completed_at := (v_result ->> 'completed_at')::timestamptz;
  IF v_completed_at IS NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c2 delivery] crm_entregar_operacion did not return a completed_at for a complete-beneficiary operation, result=%', v_result;
  ELSE
    RAISE NOTICE 'PASS [c2 delivery] complete-beneficiary operation delivered successfully';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  IF NOT EXISTS (
    SELECT 1 FROM crm_operaciones_de_conversacion(v_c2_conv)
     WHERE operation_id = v_op_c2
       AND operation_is_history = true
       AND operation_delivery_mode = 'proof_sent'
       AND operation_delivered_at = v_completed_at
       AND resolver_resultado = 'ninguna'
       AND resolver_operation_id IS NULL
       AND resolver_candidatas = 0
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c2 after delivery] expected op_c2 as history with delivery_mode=proof_sent, delivered_at=%, and resolver=ninguna (no longer live)', v_completed_at;
  ELSE
    RAISE NOTICE 'PASS [c2 after delivery] op_c2 surfaces as history with delivery facts, resolver no longer counts it';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- =======================================================================
  -- Case 3: 11 completed operations -> only the 10 most recent surface;
  -- a cancelled operation never does.
  -- =======================================================================
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000603', v_account_id) RETURNING id INTO v_c3_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_c3_contact, v_account_id) RETURNING id INTO v_c3_conv;

  -- A raw UPDATE of deals.stage_id into Entregada with no human actor
  -- context (no request.jwt.claims / auth.uid()) is suppressed by 096's
  -- automation guard as an unattended automation write — exactly what
  -- crm_entregar_operacion's header calls "doing the stage UPDATE under a
  -- human actor context (so the 096 automation guards get out of the
  -- way)". So this fixture wraps the same Lista -> Entregada transition
  -- crm_entregar_operacion and the old Kanban board perform with an
  -- authenticated agent session, letting trg_sync_operacion_desde_deal —
  -- not a raw table write — complete the operation.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);

  FOR i IN 1..11 LOOP
    INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
    VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'history fixture c3 #' || i, v_account_id, v_c3_conv, v_c3_contact, 1000, 'GYD')
    RETURNING id INTO v_deal_i;
    SELECT id INTO v_op_i FROM remittance_operations WHERE deal_id = v_deal_i;
    IF v_op_i IS NULL THEN
      RAISE EXCEPTION 'history-readiness: fixture setup failed — no operation created for deal %', v_deal_i;
    END IF;

    UPDATE deals SET stage_id = v_entregada, updated_at = now() WHERE id = v_deal_i;

    SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_i;
    IF v_op_status IS DISTINCT FROM 'completed' THEN
      RAISE EXCEPTION 'history-readiness: fixture setup failed — operation % did not complete via the deal-stage sync (status=%)', v_op_i, v_op_status;
    END IF;

    -- completed_at is then staggered explicitly (a plain column update,
    -- untouched by 096's lock guard and by guard 12a, which only guard
    -- specific operation columns and status transitions) so ordering is
    -- deterministic instead of depending on real-time gaps between loop
    -- iterations.
    UPDATE remittance_operations SET completed_at = now() - (i || ' minutes')::interval WHERE id = v_op_i;

    v_completed_ops := array_append(v_completed_ops, v_op_i);
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);

  -- Terminal, excluded fixture: a cancelled remesa, inserted directly
  -- (guard 12a only guards transitions into/out of 'completed', never
  -- 'cancelled' — see read-rpc.sql's fixture comment for why this is safe).
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c3_conv, 'cancelled', 'remesa') RETURNING id INTO v_cancelled_op;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  SELECT count(*) INTO v_row_count FROM crm_operaciones_de_conversacion(v_c3_conv);
  IF v_row_count IS DISTINCT FROM 10 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c3 row count] expected exactly 10 rows (10 most recent completed ops, no beneficiaries each), got %', v_row_count;
  ELSE
    RAISE NOTICE 'PASS [c3 row count] exactly 10 rows';
  END IF;

  SELECT count(DISTINCT operation_id) INTO v_distinct_ops
    FROM crm_operaciones_de_conversacion(v_c3_conv)
   WHERE operation_id = ANY(v_completed_ops);
  IF v_distinct_ops IS DISTINCT FROM 10 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c3 distinct history ops] expected 10 of the 11 completed ops, got %', v_distinct_ops;
  ELSIF EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_c3_conv) WHERE operation_id = v_completed_ops[11]) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c3 oldest excluded] the 11th (oldest) completed operation leaked into the result';
  ELSE
    RAISE NOTICE 'PASS [c3 oldest excluded] only the 10 most recently completed operations surface';
  END IF;

  IF EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_c3_conv) WHERE operation_id = v_cancelled_op) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c3 cancelled excluded] a cancelled operation leaked into the result';
  ELSE
    RAISE NOTICE 'PASS [c3 cancelled excluded] the cancelled operation never surfaces';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- =======================================================================
  -- Case 4: operation_beneficiaries_complete reflects the rule for open ops
  -- =======================================================================
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000604', v_account_id) RETURNING id INTO v_c4_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_c4_contact, v_account_id) RETURNING id INTO v_c4_conv;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c4_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_c4_complete;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_c4_complete, 'zelle', 'C4 Complete', 'c4-ok@example.invalid', 1, 1, 'vigente');

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_c4_conv, 'collecting_information', 'remesa') RETURNING id INTO v_op_c4_incomplete;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_c4_incomplete, 'zelle', 'C4 Incomplete', NULL, 1, 1, 'vigente');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  SELECT bool_and(operation_beneficiaries_complete) INTO v_bool
    FROM crm_operaciones_de_conversacion(v_c4_conv) WHERE operation_id = v_op_c4_complete;
  IF v_bool IS NOT TRUE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c4 complete open op] expected operation_beneficiaries_complete=true';
  ELSE
    RAISE NOTICE 'PASS [c4 complete open op] operation_beneficiaries_complete=true';
  END IF;

  SELECT bool_and(operation_beneficiaries_complete) INTO v_bool
    FROM crm_operaciones_de_conversacion(v_c4_conv) WHERE operation_id = v_op_c4_incomplete;
  IF v_bool IS NOT FALSE THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c4 incomplete open op] expected operation_beneficiaries_complete=false';
  ELSE
    RAISE NOTICE 'PASS [c4 incomplete open op] operation_beneficiaries_complete=false';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- =======================================================================
  -- Case 5: crm_entregar_operacion refuses incomplete/absent beneficiary data
  -- =======================================================================
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000605', v_account_id) RETURNING id INTO v_c5_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_c5_contact, v_account_id) RETURNING id INTO v_c5_conv;

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'history fixture c5a', v_account_id, v_c5_conv, v_c5_contact, 5000, 'GYD')
  RETURNING id INTO v_deal_c5a;
  SELECT id INTO v_op_c5a FROM remittance_operations WHERE deal_id = v_deal_c5a;
  IF v_op_c5a IS NULL THEN
    RAISE EXCEPTION 'history-readiness: fixture setup failed — no operation created for deal %', v_deal_c5a;
  END IF;
  -- zelle beneficiary without a zelle_account -> incomplete.
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_c5a, 'zelle', 'C5a Incomplete', NULL, 1, 1, 'vigente');

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'history fixture c5b', v_account_id, v_c5_conv, v_c5_contact, 5000, 'GYD')
  RETURNING id INTO v_deal_c5b;
  SELECT id INTO v_op_c5b FROM remittance_operations WHERE deal_id = v_deal_c5b;
  IF v_op_c5b IS NULL THEN
    RAISE EXCEPTION 'history-readiness: fixture setup failed — no operation created for deal %', v_deal_c5b;
  END IF;
  -- v_op_c5b deliberately has zero beneficiaries.

  -- ---- case 5a: incomplete beneficiary -> 22023 --------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_c5a, jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c5a incomplete beneficiary] expected 22023, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' AND SQLERRM = 'beneficiary data is incomplete' THEN
      RAISE NOTICE 'PASS [c5a incomplete beneficiary] rejected with 22023 ''beneficiary data is incomplete''';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [c5a incomplete beneficiary] expected 22023 ''beneficiary data is incomplete'', got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5b: no beneficiaries -> 22023 ---------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_c5b, jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c5b no beneficiaries] expected 22023, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' AND SQLERRM = 'beneficiary data is incomplete' THEN
      RAISE NOTICE 'PASS [c5b no beneficiaries] rejected with 22023 ''beneficiary data is incomplete''';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [c5b no beneficiaries] expected 22023 ''beneficiary data is incomplete'', got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5c: both rejections left no partial effect --------------------
  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_c5a;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_c5a;
  IF v_stage IS DISTINCT FROM v_lista
     OR v_op_status IS DISTINCT FROM 'ready_to_transfer'
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op_c5a AND action = 'human_delivery')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c5c no partial effect, c5a] expected deal_c5a still LISTA, op_c5a still ready_to_transfer, no human_delivery audit; got stage=%, status=%', v_stage, v_op_status;
  ELSE
    RAISE NOTICE 'PASS [c5c no partial effect, c5a] the rejected delivery left deal/operation/audit untouched';
  END IF;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_c5b;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_c5b;
  IF v_stage IS DISTINCT FROM v_lista
     OR v_op_status IS DISTINCT FROM 'ready_to_transfer'
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op_c5b AND action = 'human_delivery')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [c5c no partial effect, c5b] expected deal_c5b still LISTA, op_c5b still ready_to_transfer, no human_delivery audit; got stage=%, status=%', v_stage, v_op_status;
  ELSE
    RAISE NOTICE 'PASS [c5c no partial effect, c5b] the rejected delivery left deal/operation/audit untouched';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'history-readiness: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'history-readiness: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT history_readiness;
