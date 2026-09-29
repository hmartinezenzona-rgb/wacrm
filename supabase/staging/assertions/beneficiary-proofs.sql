-- beneficiary-proofs.sql — self-reverting assertion for
-- 143_beneficiary_delivery_proofs.sql
--
-- One delivery proof (image + caption) per beneficiary. A remesa with 2+
-- current beneficiaries delivered "with proof" completes only when every
-- current beneficiary has its proof. Single-beneficiary remesas and the
-- no_proof / skip_proof modes behave exactly as before.
--
-- BEFORE 143 (RED): crm_registrar_prueba_beneficiario does not exist, and a
-- 2-beneficiary remesa delivers with a single proof.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (psql -1). Never COMMIT. Never run against production.

SAVEPOINT beneficiary_proofs;

DO $$
DECLARE
  v_account_id      uuid;
  v_owner_user      uuid := gen_random_uuid();
  v_agent_user      uuid := gen_random_uuid();
  v_contact_id      uuid;
  v_conv_id         uuid;
  v_pipeline_id     CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_lista           CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada       CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
  v_por_verificar   CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_incidencia      CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_owner  uuid;
  v_dummy_hash      CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_agent_claims    text;

  v_deal            uuid;
  v_op_two          uuid;  -- 2 Zelle beneficiaries, proof_sent
  v_op_one          uuid;  -- 1 Zelle beneficiary, proof_sent, no proof rows
  v_op_skip         uuid;  -- 2 Zelle beneficiaries, no_proof
  v_b1 uuid; v_b2 uuid; v_b_other uuid; v_b_old uuid;

  v_result          jsonb;
  v_status          text;
  v_count           integer;
  v_raised          boolean;
  v_fail_count      integer := 0;
BEGIN
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bp-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bp-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'beneficiary proofs test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'bp owner', 'bp-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'bp agent', 'bp-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista, v_pipeline_id, 'Lista para transferir', 50) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_entregada, v_pipeline_id, 'Entregada', 60) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 90) ON CONFLICT (id) DO NOTHING;

  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/beneficiary-proofs-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'beneficiary-proofs-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner_user, '15550000701', v_account_id, 'Cliente BP') RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- Three LISTA deals -> three ready_to_transfer operations.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'bp two', v_account_id, v_conv_id, v_contact_id, 26000, 'GYD')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op_two FROM remittance_operations WHERE deal_id = v_deal;

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'bp one', v_account_id, v_conv_id, v_contact_id, 26000, 'GYD')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op_one FROM remittance_operations WHERE deal_id = v_deal;

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'bp skip', v_account_id, v_conv_id, v_contact_id, 26000, 'GYD')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op_skip FROM remittance_operations WHERE deal_id = v_deal;

  IF v_op_two IS NULL OR v_op_one IS NULL OR v_op_skip IS NULL THEN
    RAISE EXCEPTION 'beneficiary-proofs: fixture setup failed — an operation was not created';
  END IF;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_two, 'zelle', 'BP Uno', 'bp1@example.invalid', 1, 1, 'vigente') RETURNING id INTO v_b1;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_two, 'zelle', 'BP Dos', 'bp2@example.invalid', 2, 1, 'vigente') RETURNING id INTO v_b2;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status, replaced_at)
  VALUES (gen_random_uuid(), v_op_two, 'zelle', 'BP Viejo', 'bpold@example.invalid', 3, 0, 'reemplazado', now()) RETURNING id INTO v_b_old;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_one, 'zelle', 'BP Solo', 'bpsolo@example.invalid', 1, 1, 'vigente') RETURNING id INTO v_b_other;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (v_op_skip, 'zelle', 'BP Skip Uno', 'bps1@example.invalid', 1, 1, 'vigente'),
         (v_op_skip, 'zelle', 'BP Skip Dos', 'bps2@example.invalid', 2, 1, 'vigente');

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);

  -- ---- case 1: registering a proof does not deliver ----------------------
  v_result := crm_registrar_prueba_beneficiario(v_op_two, v_b1,
    jsonb_build_object('wamid', 'wamid.BP1', 'path', 'account/x/bp1.png', 'caption', 'Zelle a BP Uno'));
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_two;
  IF v_status IS DISTINCT FROM 'ready_to_transfer' OR (v_result ->> 'missing')::int IS DISTINCT FROM 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] recording one proof must not deliver and must report 1 missing; status % result %', v_status, v_result;
  ELSE
    RAISE NOTICE 'PASS [case 1] recording a beneficiary proof keeps the op ready_to_transfer and reports 1 missing';
  END IF;

  -- ---- case 2: a retry of the same proof is idempotent -------------------
  PERFORM crm_registrar_prueba_beneficiario(v_op_two, v_b1,
    jsonb_build_object('wamid', 'wamid.BP1', 'path', 'account/x/bp1.png', 'caption', 'Zelle a BP Uno'));
  SELECT count(*) INTO v_count FROM remittance_beneficiary_proofs WHERE beneficiary_id = v_b1;
  IF v_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a retried proof must not duplicate, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 2] a retried proof (same wamid) is stored once';
  END IF;

  -- ---- case 3: delivery with proof refused while a beneficiary lacks one --
  v_raised := false;
  BEGIN
    PERFORM crm_entregar_operacion(v_op_two, jsonb_build_object('mode', 'proof_sent', 'wamid', 'wamid.BP1', 'path', 'account/x/bp1.png'));
  EXCEPTION WHEN OTHERS THEN
    v_raised := true;
  END;
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_two;
  IF NOT v_raised OR v_status IS DISTINCT FROM 'ready_to_transfer' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a 2-beneficiary op with 1 proof must refuse delivery; raised % status %', v_raised, v_status;
  ELSE
    RAISE NOTICE 'PASS [case 3] a 2-beneficiary op with only 1 proof refuses delivery';
  END IF;

  -- ---- case 4: a beneficiary of another operation is refused -------------
  v_raised := false;
  BEGIN
    PERFORM crm_registrar_prueba_beneficiario(v_op_two, v_b_other, jsonb_build_object('wamid', 'wamid.BPX'));
  EXCEPTION WHEN OTHERS THEN
    v_raised := true;
  END;
  IF NOT v_raised THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a proof for another operation''s beneficiary must be refused';
  ELSE
    RAISE NOTICE 'PASS [case 4] a proof for another operation''s beneficiary is refused';
  END IF;

  -- ---- case 5: a replaced (non-current) beneficiary is refused ------------
  v_raised := false;
  BEGIN
    PERFORM crm_registrar_prueba_beneficiario(v_op_two, v_b_old, jsonb_build_object('wamid', 'wamid.BPOLD'));
  EXCEPTION WHEN OTHERS THEN
    v_raised := true;
  END;
  IF NOT v_raised THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a proof for a replaced beneficiary must be refused';
  ELSE
    RAISE NOTICE 'PASS [case 5] a proof for a replaced beneficiary is refused';
  END IF;

  -- ---- case 6: with every proof in, the delivery completes ---------------
  v_result := crm_registrar_prueba_beneficiario(v_op_two, v_b2,
    jsonb_build_object('wamid', 'wamid.BP2', 'path', 'account/x/bp2.png', 'caption', 'Zelle a BP Dos'));
  PERFORM crm_entregar_operacion(v_op_two, jsonb_build_object('mode', 'proof_sent', 'wamid', 'wamid.BP2', 'path', 'account/x/bp2.png'));
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_two;
  IF (v_result ->> 'missing')::int IS DISTINCT FROM 0 OR v_status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] with both proofs the op must deliver; missing % status %', v_result ->> 'missing', v_status;
  ELSE
    RAISE NOTICE 'PASS [case 6] with a proof per beneficiary the op delivers once';
  END IF;

  -- ---- case 7: single beneficiary delivers exactly as before ------------
  PERFORM crm_entregar_operacion(v_op_one, jsonb_build_object('mode', 'proof_sent', 'wamid', 'wamid.BPS', 'path', 'account/x/bps.png'));
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_one;
  IF v_status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] a 1-beneficiary op must deliver without proof rows, status %', v_status;
  ELSE
    RAISE NOTICE 'PASS [case 7] a 1-beneficiary op delivers as before, no proof rows needed';
  END IF;

  -- ---- case 8: no_proof mode needs no per-beneficiary proofs ------------
  PERFORM crm_entregar_operacion(v_op_skip, jsonb_build_object('mode', 'no_proof'));
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_skip;
  IF v_status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] no_proof on a 2-beneficiary op must deliver, status %', v_status;
  ELSE
    RAISE NOTICE 'PASS [case 8] no_proof delivers a 2-beneficiary op as before';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'beneficiary-proofs: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'beneficiary-proofs: ALL PASS (8 expectations)';
END $$;

ROLLBACK TO SAVEPOINT beneficiary_proofs;
