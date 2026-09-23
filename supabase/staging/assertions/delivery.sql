-- delivery.sql — self-reverting assertion for 101_operation_delivery_rpc.sql
--
-- Proves crm_entregar_operacion: authorization (agent+), evidence
-- validation, the readiness guard (operation ready_to_transfer AND deal
-- in LISTA), reuse of the legacy stage-to-Entregada path (so 052's
-- auto-won flip and deals_stage_notify's client notification fire
-- exactly as they do for the old Kanban board), the evidence columns
-- being stamped on the operation, the human_delivery audit row, and that
-- a rejected call leaves no partial effect.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures
-- (pipeline/stages via ON CONFLICT DO NOTHING, same ids as
-- deposit-review.sql) so it can run alongside or independently of the
-- other assertion files.

SAVEPOINT delivery;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_nonmember_user uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista          CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada      CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_owner uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_deal_1_id  uuid; v_op_1_id  uuid;  -- proof_sent (case 1) then delivered-twice (case 5b)
  v_deal_2_id  uuid; v_op_2_id  uuid;  -- no_proof (case 2)
  v_deal_3_id  uuid; v_op_3_id  uuid;  -- skip_proof (case 3)
  v_deal_pv_id uuid; v_op_pv_id uuid;  -- still POR_VERIFICAR (case 5a)
  v_deal_val_id uuid; v_op_val_id uuid; -- LISTA, untouched (cases 4, 6, 7)

  v_result      jsonb;
  v_stage       uuid;
  v_op_status   text;
  v_op_status2  text;
  v_body_text   text;

  v_case_start  timestamptz;
  v_fail_count  integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see corrections.sql's fixture comment for why.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'delivery-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'delivery-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'delivery-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_nonmember_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'delivery-nonmember-' || v_nonmember_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'delivery test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'delivery owner', 'delivery-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'delivery agent', 'delivery-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'delivery viewer', 'delivery-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer');
  -- v_nonmember_user intentionally has no profile in this (or any) account.

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista, v_pipeline_id, 'Lista para transferir', 50) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_entregada, v_pipeline_id, 'Entregada', 60) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 90) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() / notify_deal_stage_change() (pre-existing
  -- triggers, unrelated to 101) fire on every deals INSERT / stage UPDATE
  -- and need a non-null notify_url; point them at a loopback no-op. Our
  -- own transaction never commits, so pg_net's worker never actually
  -- dispatches these.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/delivery-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'delivery-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000501', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- deal 1: LISTA -> its synced operation starts ready_to_transfer. Used
  -- for case 1 (agent delivers with proof_sent) and, once delivered, case
  -- 5b (delivering an already-completed operation again).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'delivery fixture 1', v_account_id, v_conv_id, v_contact_id, 25000, 'GYD')
  RETURNING id INTO v_deal_1_id;
  SELECT id INTO v_op_1_id FROM remittance_operations WHERE deal_id = v_deal_1_id;
  IF v_op_1_id IS NULL THEN
    RAISE EXCEPTION 'delivery: fixture setup failed — no operation created for deal %', v_deal_1_id;
  END IF;
  -- 102 requires complete beneficiary data before crm_entregar_operacion
  -- will deliver — a complete vigente zelle beneficiary satisfies it.
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_1_id, 'zelle', 'Delivery Fixture 1 Beneficiary', 'delivery1-ok@example.invalid', 1, 1, 'vigente');

  -- deal 2: LISTA — used for case 2 (owner delivers with no_proof).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'delivery fixture 2', v_account_id, v_conv_id, v_contact_id, 15000, 'GYD')
  RETURNING id INTO v_deal_2_id;
  SELECT id INTO v_op_2_id FROM remittance_operations WHERE deal_id = v_deal_2_id;
  IF v_op_2_id IS NULL THEN
    RAISE EXCEPTION 'delivery: fixture setup failed — no operation created for deal %', v_deal_2_id;
  END IF;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_2_id, 'zelle', 'Delivery Fixture 2 Beneficiary', 'delivery2-ok@example.invalid', 1, 1, 'vigente');

  -- deal 3: LISTA — used for case 3 (skip_proof).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'delivery fixture 3', v_account_id, v_conv_id, v_contact_id, 5000, 'GYD')
  RETURNING id INTO v_deal_3_id;
  SELECT id INTO v_op_3_id FROM remittance_operations WHERE deal_id = v_deal_3_id;
  IF v_op_3_id IS NULL THEN
    RAISE EXCEPTION 'delivery: fixture setup failed — no operation created for deal %', v_deal_3_id;
  END IF;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_3_id, 'zelle', 'Delivery Fixture 3 Beneficiary', 'delivery3-ok@example.invalid', 1, 1, 'vigente');

  -- deal pv: POR_VERIFICAR — its operation is deposit_verification, never
  -- ready_to_transfer. Used for case 5a.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'delivery fixture pv', v_account_id, v_conv_id, v_contact_id, 5000, 'GYD')
  RETURNING id INTO v_deal_pv_id;
  SELECT id INTO v_op_pv_id FROM remittance_operations WHERE deal_id = v_deal_pv_id;
  IF v_op_pv_id IS NULL THEN
    RAISE EXCEPTION 'delivery: fixture setup failed — no operation created for deal %', v_deal_pv_id;
  END IF;

  -- deal val: LISTA, left untouched throughout — used for the
  -- authorization negative cases (4), the evidence-validation negative
  -- cases (6), and the no-partial-effect check (7), so those checks
  -- always exercise the intended branch instead of tripping an earlier
  -- readiness guard, and so case 7 has a clean before/after to compare.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'delivery fixture val', v_account_id, v_conv_id, v_contact_id, 5000, 'GYD')
  RETURNING id INTO v_deal_val_id;
  SELECT id INTO v_op_val_id FROM remittance_operations WHERE deal_id = v_deal_val_id;
  IF v_op_val_id IS NULL THEN
    RAISE EXCEPTION 'delivery: fixture setup failed — no operation created for deal %', v_deal_val_id;
  END IF;

  -- ---- case 1: agent delivers with proof_sent --------------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_entregar_operacion(v_op_1_id, jsonb_build_object('mode', 'proof_sent', 'wamid', 'wamid.TEST', 'path', 'account/x/prueba-entrega.png')) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_1_id;

  SELECT convert_from(body, 'UTF8')::jsonb -> 'record' ->> 'stage_id' INTO v_body_text
    FROM net.http_request_queue
   WHERE convert_from(body, 'UTF8')::jsonb ->> 'table' = 'deals'
     AND convert_from(body, 'UTF8')::jsonb ->> 'type' = 'UPDATE'
     AND (convert_from(body, 'UTF8')::jsonb -> 'record' ->> 'id') = v_deal_1_id::text
   ORDER BY id DESC
   LIMIT 1;

  IF (v_result ->> 'new_status') IS DISTINCT FROM 'completed'
     OR (v_result ->> 'completed_at') IS NULL
     OR v_stage IS DISTINCT FROM v_entregada
     OR NOT EXISTS (
       SELECT 1 FROM remittance_operations
        WHERE id = v_op_1_id
          AND status = 'completed'
          AND completed_at IS NOT NULL
          AND delivery_mode = 'proof_sent'
          AND delivery_proof_wamid = 'wamid.TEST'
          AND delivery_proof_path = 'account/x/prueba-entrega.png'
          AND delivered_by = v_agent_user
     )
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_1_id AND action = 'human_delivery' AND created_at >= v_case_start
          AND (after -> 'evidence' ->> 'mode') = 'proof_sent'
     )
     OR v_body_text IS DISTINCT FROM v_entregada::text
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected new_status=completed, deal in ENTREGADA, evidence columns stored, audit row, and a notify payload record.stage_id=ENTREGADA; got result=%, stage=%, notify_stage=%', v_result, v_stage, v_body_text;
  ELSE
    RAISE NOTICE 'PASS [case 1] agent delivers with proof_sent, completes the operation via the legacy stage path, stores evidence, and audits it';
  END IF;

  -- ---- case 2: owner delivers with no_proof ------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  SELECT crm_entregar_operacion(v_op_2_id, jsonb_build_object('mode', 'no_proof')) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  IF (v_result ->> 'new_status') IS DISTINCT FROM 'completed'
     OR NOT EXISTS (
       SELECT 1 FROM remittance_operations
        WHERE id = v_op_2_id AND status = 'completed'
          AND delivery_mode = 'no_proof'
          AND delivery_proof_wamid IS NULL
          AND delivery_proof_path IS NULL
          AND delivered_by = v_owner_user
     )
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected new_status=completed with delivery_mode=no_proof and null wamid/path; got %', v_result;
  ELSE
    RAISE NOTICE 'PASS [case 2] owner delivers with no_proof, leaving wamid/path null';
  END IF;

  -- ---- case 3: skip_proof -------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_entregar_operacion(v_op_3_id, jsonb_build_object('mode', 'skip_proof')) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  IF (v_result ->> 'new_status') IS DISTINCT FROM 'completed'
     OR NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = v_op_3_id AND status = 'completed' AND delivery_mode = 'skip_proof')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected new_status=completed with delivery_mode=skip_proof; got %', v_result;
  ELSE
    RAISE NOTICE 'PASS [case 3] skip_proof completes the operation';
  END IF;

  -- ---- case 4a: viewer -> 42501 -------------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_val_id, jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4a] expected 42501 for a viewer, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 4a] a viewer is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4a] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 4b: non-member -> 42501 ---------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nonmember_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_val_id, jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4b] expected 42501 for a non-member, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 4b] a non-member is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4b] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 4c: unknown operation id -> P0002 -----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(gen_random_uuid(), jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4c] expected P0002 for an unknown operation id, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = 'P0002' THEN
      RAISE NOTICE 'PASS [case 4c] an unknown operation id is rejected with P0002';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4c] expected SQLSTATE P0002, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5a: operation still awaiting deposit verification -> 22023 ---
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_pv_id, jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5a] expected 22023 for an operation in deposit_verification, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 5a] an operation awaiting deposit verification is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5a] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5b: already-completed operation -> 22023 ----------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_1_id, jsonb_build_object('mode', 'no_proof'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5b] expected 22023 for an already-completed operation, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 5b] an already-completed operation is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5b] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 6a: invalid mode -> 22023 --------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_val_id, jsonb_build_object('mode', 'foo'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6a] expected 22023 for an invalid mode, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 6a] an invalid mode is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6a] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 6b: evidence not an object -> 22023 ----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_val_id, '"no_proof"'::jsonb);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6b] expected 22023 for evidence that is not a JSON object, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 6b] evidence that is not a JSON object is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6b] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 6c: empty wamid -> 22023 ---------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_entregar_operacion(v_op_val_id, jsonb_build_object('mode', 'proof_sent', 'wamid', ''));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6c] expected 22023 for an empty wamid, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 6c] an empty wamid is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6c] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7: a 22023 failure leaves no partial effect --------------------
  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_val_id;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_val_id;

  IF v_stage IS DISTINCT FROM v_lista
     OR v_op_status IS DISTINCT FROM 'ready_to_transfer'
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op_val_id AND action = 'human_delivery')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected deal_val still in LISTA, op_val still ready_to_transfer, and no human_delivery audit row after the 22023 attempts above; got stage=%, status=%', v_stage, v_op_status;
  ELSE
    RAISE NOTICE 'PASS [case 7] the rejected evidence attempts left the deal and operation completely untouched';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'delivery: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'delivery: ALL PASS (11 expectations)';
END $$;

ROLLBACK TO SAVEPOINT delivery;
