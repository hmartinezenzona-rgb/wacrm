\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- delivery-feed-evidence.sql — self-reverting assertion for
-- 108_delivery_evidence_before_status.sql
--
-- Proves that crm_entregar_operacion's delivery evidence (delivery_mode,
-- delivered_by) reaches the calculator ledger entry the completion trigger
-- feeds, for both the proof_sent and no_proof evidence modes.
--
-- Before 108, crm_entregar_operacion wrote the evidence columns onto
-- remittance_operations AFTER the `UPDATE deals SET stage_id = Entregada`
-- statement. That deals UPDATE is what fires the legacy status sync
-- (trg_sync_operacion_desde_deal, 041) which flips the operation to
-- status='completed', which in turn fires the calculator ledger feed
-- trigger (zzz_remittance_operations_calculator_feed, 104) inside the same
-- statement. calculator_feed_operation (104) copies delivery_mode and
-- delivered_by straight off the operation row at that instant — before the
-- evidence UPDATE has run — so the fed entry always carried NULL for both.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures (same
-- pipeline/stage ids as delivery.sql and feed-matrix.sql, via
-- ON CONFLICT DO NOTHING) so it can run alongside or independently of the
-- other assertion files.

SAVEPOINT delivery_feed_evidence;

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

  v_deal_proof_id    uuid; v_op_proof_id    uuid;  -- case 1: proof_sent, delivered by the agent
  v_deal_noproof_id  uuid; v_op_noproof_id  uuid;  -- case 2: no_proof, delivered by the owner

  v_result      jsonb;
  v_e           remittance_calculator_entries;
  v_fail_count  integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dfe-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'dfe-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'delivery feed evidence test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'dfe owner', 'dfe-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'dfe agent', 'dfe-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista, v_pipeline_id, 'Lista para transferir', 50) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_entregada, v_pipeline_id, 'Entregada', 60) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 90) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() / notify_deal_stage_change() (pre-existing
  -- triggers, unrelated to this fix) fire on every deals INSERT / stage
  -- UPDATE and need a non-null notify_url; point them at a loopback no-op.
  -- Our own transaction never commits, so pg_net's worker never actually
  -- dispatches these.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/delivery-feed-evidence-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'delivery-feed-evidence-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner_user, '15550000601', v_account_id, 'Cliente DFE') RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- Rates the ZELLE service formula needs (calculator_service_for_operation
  -- maps delivery_method 'zelle' -> service 'ZELLE').
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_buy_gyd', 250, 'usdt_sell_gyd', 265));
  PERFORM set_config('request.jwt.claims', '', true);

  -- deal 1: LISTA, value 26000 GYD -> its synced operation (041) starts
  -- ready_to_transfer with quoted_source_amount = 26000. Delivered with
  -- proof_sent by the agent.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'delivery feed evidence fixture 1', v_account_id, v_conv_id, v_contact_id, 26000, 'GYD')
  RETURNING id INTO v_deal_proof_id;
  SELECT id INTO v_op_proof_id FROM remittance_operations WHERE deal_id = v_deal_proof_id;
  IF v_op_proof_id IS NULL THEN
    RAISE EXCEPTION 'delivery-feed-evidence: fixture setup failed — no operation created for deal %', v_deal_proof_id;
  END IF;
  -- delivery_method feeds the ledger's service mapping (104); 041's sync
  -- trigger never sets it, so it is stamped directly.
  UPDATE remittance_operations SET delivery_method = 'zelle' WHERE id = v_op_proof_id;
  -- 102's readiness gate (crm_beneficiarios_completos) requires a complete
  -- vigente beneficiary before crm_entregar_operacion will deliver.
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_proof_id, 'zelle', 'Delivery Feed Evidence Beneficiary 1', 'dfe1-ok@example.invalid', 1, 1, 'vigente');

  -- deal 2: LISTA, value 26000 GYD. Delivered with no_proof by the owner.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'delivery feed evidence fixture 2', v_account_id, v_conv_id, v_contact_id, 26000, 'GYD')
  RETURNING id INTO v_deal_noproof_id;
  SELECT id INTO v_op_noproof_id FROM remittance_operations WHERE deal_id = v_deal_noproof_id;
  IF v_op_noproof_id IS NULL THEN
    RAISE EXCEPTION 'delivery-feed-evidence: fixture setup failed — no operation created for deal %', v_deal_noproof_id;
  END IF;
  UPDATE remittance_operations SET delivery_method = 'zelle' WHERE id = v_op_noproof_id;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_noproof_id, 'zelle', 'Delivery Feed Evidence Beneficiary 2', 'dfe2-ok@example.invalid', 1, 1, 'vigente');

  -- ---- case 1: proof_sent evidence reaches the fed ledger entry --------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_entregar_operacion(v_op_proof_id, jsonb_build_object('mode', 'proof_sent', 'wamid', 'wamid.DFE1', 'path', 'account/x/dfe1-prueba.png')) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  IF (v_result ->> 'new_status') IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery-feed-evidence: fixture setup failed — crm_entregar_operacion did not complete operation % (result %)', v_op_proof_id, v_result;
  END IF;

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_proof_id AND source = 'completed_operation';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery-feed-evidence: fixture setup failed — no ledger entry was fed for operation %', v_op_proof_id;
  END IF;

  IF v_e.delivery_mode IS DISTINCT FROM 'proof_sent' OR v_e.actor_user_id IS DISTINCT FROM v_agent_user THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected the fed ledger entry to carry delivery_mode=proof_sent and actor_user_id=% (the delivering agent); got delivery_mode=%, actor_user_id=%',
      v_agent_user, v_e.delivery_mode, v_e.actor_user_id;
  ELSE
    RAISE NOTICE 'PASS [case 1] the ledger entry fed by a proof_sent delivery carries the delivery evidence';
  END IF;

  -- ---- case 2: no_proof evidence reaches the fed ledger entry ----------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  SELECT crm_entregar_operacion(v_op_noproof_id, jsonb_build_object('mode', 'no_proof')) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  IF (v_result ->> 'new_status') IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery-feed-evidence: fixture setup failed — crm_entregar_operacion did not complete operation % (result %)', v_op_noproof_id, v_result;
  END IF;

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_noproof_id AND source = 'completed_operation';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery-feed-evidence: fixture setup failed — no ledger entry was fed for operation %', v_op_noproof_id;
  END IF;

  IF v_e.delivery_mode IS DISTINCT FROM 'no_proof' OR v_e.actor_user_id IS DISTINCT FROM v_owner_user THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected the fed ledger entry to carry delivery_mode=no_proof and actor_user_id=% (the delivering owner); got delivery_mode=%, actor_user_id=%',
      v_owner_user, v_e.delivery_mode, v_e.actor_user_id;
  ELSE
    RAISE NOTICE 'PASS [case 2] the ledger entry fed by a no_proof delivery carries the delivery evidence';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'delivery-feed-evidence: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'delivery-feed-evidence: ALL PASS (2 expectations)';
END $$;

ROLLBACK TO SAVEPOINT delivery_feed_evidence;
