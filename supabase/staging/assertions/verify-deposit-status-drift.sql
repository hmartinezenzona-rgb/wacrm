-- verify-deposit-status-drift.sql — self-reverting assertion for
-- 144_verify_deposit_status_drift.sql
--
-- Proves the B3.3 root cause and its fix: an operation whose deal
-- existed BEFORE its deposit arrived (cerebro_registrar_deposito's
-- "movido" branch — the same ~13% class migration 125 measured) reaches
-- remittance_operations.status = 'deposit_verification' WITHOUT
-- deals.stage_id ever moving off its birth stage ("Solicitada"). The
-- panel's own crm_verificar_deposito then derives its expected stage
-- from the CURRENT status, not from deals.stage_id — so, before 144,
-- cerebro_cruzar_deposito's deals.stage_id-based staleness check
-- ("v_aplica") is permanently false for this operation, and a
-- genuinely-matching deposit is reported as 'no_aplica' ("The operation
-- is not awaiting verification") instead of 'verificado'.
--
-- RED (against 114-143): case 1 FAILS — resultado is 'no_aplica' and the
--   operation's status never leaves 'deposit_verification'.
-- GREEN (after 144 is applied): case 1 PASSES — resultado is
--   'verificado', the deposit is consumed, and status advances to
--   'ready_to_transfer'.
--
-- Case 2 is a control: a deal that was born ALREADY at "Por verificar"
-- (the common, single-shot case — deposit arrives at first contact) was
-- never affected by this bug either way, and must keep working
-- identically before and after 144.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker psql against $CRM_STAGING_DATABASE_URL, wrapped in
-- BEGIN ... \i 144 ... \i this file ... ROLLBACK). Never COMMIT. Never
-- run against production. Builds its own account/users/pipeline/
-- fixtures, same posture as cutover.sql and deposit-review.sql.

SAVEPOINT verify_deposit_status_drift;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_contact_a      uuid;
  v_conv_a         uuid;
  v_contact_b      uuid;
  v_conv_b         uuid;

  v_solicitada     CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista          CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;

  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_fail_count     integer := 0;

  v_deal_a         uuid;
  v_op_a           uuid;
  v_deal_b         uuid;
  v_op_b           uuid;

  v_ref_a          text;
  v_ref_b          text;

  v_result         jsonb;
  v_status_after   text;
  v_stage_after    uuid;
  v_dep_deal       uuid;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'verify-drift-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'verify-drift-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'verify drift test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'verify drift owner', 'verify-drift-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'verify drift agent', 'verify-drift-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_solicitada,    v_pipeline_id, 'Solicitada',            10) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar',         20) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista,         v_pipeline_id, 'Lista para transferir', 30) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia,    v_pipeline_id, 'Incidencia',            91) ON CONFLICT (id) DO NOTHING;

  -- Loopback no-op notify config — same posture as cutover.sql/
  -- deposit-review.sql: pg_net queues the POST inside this transaction,
  -- which never dispatches once this script rolls back.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/verify-drift-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'verify-drift-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000701', 'Verify Drift Cliente A', v_account_id) RETURNING id INTO v_contact_a;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_a, v_account_id) RETURNING id INTO v_conv_a;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000702', 'Verify Drift Cliente B', v_account_id) RETURNING id INTO v_contact_b;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_b, v_account_id) RETURNING id INTO v_conv_b;

  -- A TransID above every one received, so cerebro_transid_plausible
  -- accepts both (same technique as deal-insert-creates-operation.sql).
  SELECT (coalesce(max(trans_id::numeric), 20000000000000) + 7)::text INTO v_ref_a
    FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$';
  v_ref_b := (v_ref_a::numeric + 1)::text;

  -- =========================================================================
  -- CASE 1 — deal born BEFORE its deposit ("movido" branch): the drift
  -- =========================================================================
  -- Deal A is born at "Solicitada", value 0, no notes — exactly what
  -- trg_sync_operacion_al_crear_deal (125) creates for a beneficiary-first
  -- (or bare) contact before any money is mentioned.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id,
                     title, value, currency, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, v_pipeline_id, v_solicitada,
         'Remesa +verifydrift-a', 0, 'GYD', 'open'
    FROM conversations v WHERE v.id = v_conv_a
  RETURNING id INTO v_deal_a;

  SELECT id INTO v_op_a FROM remittance_operations WHERE deal_id = v_deal_a;
  IF v_op_a IS NULL THEN
    RAISE EXCEPTION 'verify-deposit-status-drift: fixture setup failed — no operation created for deal %', v_deal_a;
  END IF;

  -- The deposit arrives later: cerebro_registrar_deposito matches deal A
  -- (open, in Solicitada, no DEPOSITO note yet) via its "movido" branch —
  -- remittance_operations.status advances directly; deals.stage_id does
  -- NOT (114 stopped writing it from this branch).
  PERFORM * FROM cerebro_registrar_deposito(v_conv_a, 7000, 'GYD', v_por_verificar,
            'DEPOSITO: 7,000 GYD - EXITOSA' || E'\nRef: ' || v_ref_a, 'COMP-verifydrift-a');

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = v_op_a;
  SELECT stage_id INTO v_stage_after FROM deals WHERE id = v_deal_a;
  IF v_status_after IS DISTINCT FROM 'deposit_verification' OR v_stage_after IS DISTINCT FROM v_solicitada THEN
    RAISE EXCEPTION 'verify-deposit-status-drift: fixture invariant broken — expected status=deposit_verification (got %) and deal stage frozen at Solicitada (got %)',
      v_status_after, v_stage_after;
  END IF;

  -- The MMG deposit-notification email arrives, unconsumed, matching
  -- exactly what was just registered.
  INSERT INTO depositos_mmg (trans_id, monto, moneda, recibido_en, titular, asunto)
  VALUES (v_ref_a, 7000, 'GYD', now(), 'Verify Drift Titular A', 'verify-drift');

  -- The operator opens the panel and clicks "Verify".
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_verificar_deposito(v_op_a, jsonb_build_array(jsonb_build_object('ref', v_ref_a, 'amount', 7000))) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = v_op_a;
  SELECT deal_id INTO v_dep_deal FROM depositos_mmg WHERE trans_id = v_ref_a;

  IF (v_result ->> 'resultado') IS DISTINCT FROM 'verificado'
     OR v_status_after IS DISTINCT FROM 'ready_to_transfer'
     OR v_dep_deal IS DISTINCT FROM v_deal_a
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] a deal born before its deposit (movido branch) could not be verified from the panel: expected resultado=verificado and status=ready_to_transfer, got resultado=%, status=%, deposit consumed by deal=% (expected %)',
      v_result ->> 'resultado', v_status_after, v_dep_deal, v_deal_a;
  ELSE
    RAISE NOTICE 'PASS [case 1] crm_verificar_deposito verifies a deal whose deals.stage_id never caught up with its operation''s status';
  END IF;

  -- =========================================================================
  -- CASE 2 — control: deal born ALREADY at "Por verificar" (unaffected
  -- either way — deposit arrived at first contact, the common case).
  -- =========================================================================
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id,
                     title, value, currency, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, v_pipeline_id, v_por_verificar,
         'Remesa +verifydrift-b', 9000, 'GYD', 'open'
    FROM conversations v WHERE v.id = v_conv_b
  RETURNING id INTO v_deal_b;

  SELECT id INTO v_op_b FROM remittance_operations WHERE deal_id = v_deal_b;
  IF v_op_b IS NULL THEN
    RAISE EXCEPTION 'verify-deposit-status-drift: fixture setup failed — no operation created for deal %', v_deal_b;
  END IF;
  SELECT status INTO v_status_after FROM remittance_operations WHERE id = v_op_b;
  IF v_status_after IS DISTINCT FROM 'deposit_verification' THEN
    RAISE EXCEPTION 'verify-deposit-status-drift: control fixture invariant broken — expected status=deposit_verification, got %', v_status_after;
  END IF;

  INSERT INTO depositos_mmg (trans_id, monto, moneda, recibido_en, titular, asunto)
  VALUES (v_ref_b, 9000, 'GYD', now(), 'Verify Drift Titular B', 'verify-drift');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_verificar_deposito(v_op_b, jsonb_build_array(jsonb_build_object('ref', v_ref_b, 'amount', 9000))) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = v_op_b;

  IF (v_result ->> 'resultado') IS DISTINCT FROM 'verificado' OR v_status_after IS DISTINCT FROM 'ready_to_transfer' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] control deal (born already at Por verificar) regressed: expected resultado=verificado and status=ready_to_transfer, got resultado=%, status=%',
      v_result ->> 'resultado', v_status_after;
  ELSE
    RAISE NOTICE 'PASS [case 2] a deal born already at Por verificar keeps verifying normally (control, unaffected by the drift either way)';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'verify-deposit-status-drift: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'verify-deposit-status-drift: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT verify_deposit_status_drift;
