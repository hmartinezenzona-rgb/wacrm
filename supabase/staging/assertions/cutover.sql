\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- cutover.sql — self-reverting assertion for
-- 114_cutover_retire_sync_pipeline.sql
--
-- Proves, against 114 applied on staging:
--   1. the dual-write into deals.stage_id no longer happens (n8n's
--      cerebro_cruzar_deposito updates remittance_operations.status but
--      leaves deals.stage_id untouched);
--   2. crm_entregar_operacion's delivery gate no longer requires the
--      linked deal to be in "Lista para transferir" — an operation whose
--      status is ready_to_transfer delivers even with its deal frozen at
--      an unrelated stage;
--   3. the Incidencia notification still fires, now from
--      remittance_operations.status = 'incident' instead of
--      deals.stage_id;
--   4. the repointed views (cerebro_historial_operaciones,
--      cerebro_volumen_diario) read remittance_operations as
--      authoritative. A third view, cerebro_conciliacion_operaciones, was
--      checked here until 164 dropped it by product decision; its check
--      is gone with it.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker psql against $CRM_STAGING_DATABASE_URL, wrapped in
-- BEGIN ... \i 114 ... \i this file ... ROLLBACK). Never COMMIT. Never
-- run against production. Builds its own account/users/pipeline/
-- fixtures, same posture as guard12-matrix.sql and rate-versions.sql.
--
-- RUN TWICE for the RED/GREEN discipline task 11.2 requires:
--   RED:   run against staging BEFORE 114 is applied — cases 1, 2, 3 and
--          4a must FAIL (the pre-114 bridge/gate is still live, and no
--          trigger on remittance_operations notifies on 'incident' yet —
--          090's Incidencia trigger only exists on deals.stage_id, and
--          this assertion deliberately writes remittance_operations
--          directly, so it does not go through it).
--   GREEN: run again AFTER 114 is applied for real — all cases PASS.

SAVEPOINT cutover;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_op_id          uuid;
  v_op_id2         uuid;
  v_op_id3         uuid;
  v_deal_id        uuid;
  v_deal_id2       uuid;

  v_solicitada     CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista          CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_entregada      CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;

  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_fail_count     integer := 0;

  v_stage_after    uuid;
  v_status_after   text;
  v_result         record;
  v_case_start     timestamptz;
  v_notif_count    integer;
  v_monto          numeric;
  v_divergent      integer;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cutover-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cutover-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cutover test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'cutover owner', 'cutover-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'cutover agent', 'cutover-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_solicitada,    v_pipeline_id, 'Solicitada',          10) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar',       20) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista,         v_pipeline_id, 'Lista para transferir', 30) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_entregada,     v_pipeline_id, 'Entregada',           90) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia,    v_pipeline_id, 'Incidencia',          91) ON CONFLICT (id) DO NOTHING;

  -- Loopback no-op notify config, same posture as guard12-matrix.sql —
  -- pg_net queues the POST inside this transaction; it never actually
  -- dispatches once this script rolls back.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/cutover-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'cutover-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000201', 'Cutover Cliente', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;


  -- =========================================================================
  -- CASE 1 — the dual-write into deals.stage_id no longer happens
  -- =========================================================================
  -- Fixture: a deal in "Por verificar" with a matching remittance
  -- operation, and a depositos_mmg row that will cross-reference clean.

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, value, currency, account_id, conversation_id, contact_id, status)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'cutover fixture 1', 5000, 'GYD', v_account_id, v_conv_id, v_contact_id, 'open')
  RETURNING id INTO v_deal_id;

  -- Pre-114, the still-live bridge trigger auto-creates the operation row
  -- on the deals INSERT above; post-114 it does not. ON CONFLICT makes
  -- this fixture correct in both states.
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, quoted_source_amount, source_currency)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, v_deal_id, 'deposit_verification', 5000, 'GYD')
  ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL
    DO UPDATE SET status = 'deposit_verification', quoted_source_amount = 5000, source_currency = 'GYD'
  RETURNING id INTO v_op_id;

  INSERT INTO depositos_mmg (trans_id, monto, moneda, recibido_en, titular, asunto)
  VALUES ('10378400000001', 5000, 'GYD', now(), 'Cutover Titular', 'cutover');

  SELECT * INTO v_result FROM cerebro_cruzar_deposito(v_deal_id, '10378400000001', 5000, v_lista, v_incidencia, v_por_verificar, false);

  SELECT stage_id INTO v_stage_after FROM deals WHERE id = v_deal_id;
  SELECT status INTO v_status_after FROM remittance_operations WHERE id = v_op_id;

  IF v_result.resultado IS DISTINCT FROM 'verificado' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected the cross-reference itself to succeed (resultado=verificado), got %', v_result.resultado;
  ELSIF v_stage_after IS DISTINCT FROM v_por_verificar THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected deals.stage_id to stay at Por verificar (no dual-write), got %', v_stage_after;
  ELSIF v_status_after IS DISTINCT FROM 'ready_to_transfer' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected remittance_operations.status = ready_to_transfer, got %', v_status_after;
  ELSE
    RAISE NOTICE 'PASS [case 1] cerebro_cruzar_deposito moved remittance_operations.status to ready_to_transfer WITHOUT touching deals.stage_id (stayed at Por verificar)';
  END IF;


  -- =========================================================================
  -- CASE 2 — crm_entregar_operacion no longer gates on the deal's stage
  -- =========================================================================
  -- Fixture: a SECOND deal, deliberately left at Por verificar (never
  -- moved to Lista para transferir), whose operation's OWN status is
  -- ready_to_transfer. Pre-114 this combination is impossible to reach
  -- through the RPC's old gate; post-114 it is exactly the case the panel
  -- can now hit (deals.stage_id frozen, remittance_operations authoritative).

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, value, currency, account_id, conversation_id, contact_id, status)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'cutover fixture 2', 5000, 'GYD', v_account_id, v_conv_id, v_contact_id, 'open')
  RETURNING id INTO v_deal_id2;

  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, quoted_source_amount, source_currency)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, v_deal_id2, 'ready_to_transfer', 5000, 'GYD')
  ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL
    DO UPDATE SET status = 'ready_to_transfer', quoted_source_amount = 5000, source_currency = 'GYD'
  RETURNING id INTO v_op_id2;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status)
  VALUES (v_op_id2, 'cuban_card', '9216123412341234', '53512345678', 'vigente');

  -- (329) Delivery now requires verified funding.
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32930000000001', 5000, 'GYD', 'PRUEBA CUTOVER', now(), now(), v_op_id2);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  BEGIN
    SELECT crm_entregar_operacion(v_op_id2, jsonb_build_object('mode', 'no_proof')) INTO v_result;
    PERFORM set_config('request.jwt.claims', '', true);

    SELECT status INTO v_status_after FROM remittance_operations WHERE id = v_op_id2;
    SELECT stage_id INTO v_stage_after FROM deals WHERE id = v_deal_id2;

    IF v_status_after IS DISTINCT FROM 'completed' THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2] expected delivery to succeed with status=completed despite the deal never reaching Lista para transferir, got %', v_status_after;
    ELSIF v_stage_after IS DISTINCT FROM v_por_verificar THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2] expected deals.stage_id to stay untouched at Por verificar, got %', v_stage_after;
    ELSE
      RAISE NOTICE 'PASS [case 2] crm_entregar_operacion delivered an operation whose deal was frozen at Por verificar (never Lista para transferir) — the deal-stage gate is gone, and deals.stage_id was not written';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] crm_entregar_operacion raised unexpectedly: % (%)', SQLERRM, SQLSTATE;
  END;


  -- =========================================================================
  -- CASE 3 — the Incidencia notification still fires, now from
  -- remittance_operations.status = 'incident'
  -- =========================================================================

  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, quoted_source_amount, source_currency, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, 'deposit_verification', 5000, 'GYD', 'remesa')
  RETURNING id INTO v_op_id3;

  -- notifications.created_at defaults to now(), which is frozen at
  -- transaction start (not clock_timestamp()) — a "created_at >= X"
  -- check captured mid-transaction would always be false. Count
  -- before/after instead, same technique as the re-entry guard below.
  SELECT count(*) INTO v_notif_count FROM notifications WHERE type = 'deal_incidencia' AND contact_id = v_contact_id;

  UPDATE remittance_operations SET status = 'incident' WHERE id = v_op_id3;

  IF (SELECT count(*) FROM notifications WHERE type = 'deal_incidencia' AND contact_id = v_contact_id) > v_notif_count THEN
    RAISE NOTICE 'PASS [case 3] moving remittance_operations.status to incident inserted a deal_incidencia notification (ported off deals.stage_id)';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected a new deal_incidencia notification after remittance_operations.status -> incident, found none';
  END IF;

  -- Re-entry guard: editing an already-incident operation must NOT
  -- duplicate the alert (same rule as 090's deals-side trigger).
  SELECT count(*) INTO v_notif_count FROM notifications WHERE type = 'deal_incidencia' AND contact_id = v_contact_id;
  UPDATE remittance_operations SET quoted_source_amount = 5001 WHERE id = v_op_id3;
  UPDATE remittance_operations SET status = 'incident' WHERE id = v_op_id3;
  IF (SELECT count(*) FROM notifications WHERE type = 'deal_incidencia' AND contact_id = v_contact_id) <> v_notif_count THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3b] re-asserting status=incident on an already-incident operation duplicated the alert';
  ELSE
    RAISE NOTICE 'PASS [case 3b] re-entry into incident does not duplicate the alert';
  END IF;


  -- =========================================================================
  -- CASE 4 — repointed views read remittance_operations as authoritative
  -- =========================================================================
  -- Self-contained fixture (a THIRD deal/operation pair, not reused from
  -- case 2): the deal's `value` deliberately diverges from the
  -- operation's quoted_source_amount, set once at creation and never
  -- touched again — a later UPDATE of deals.stage_id/value/contact_id/
  -- currency would re-arm the pre-114 bridge trigger (still live during
  -- the RED run) and clobber this fixture the same way it does in case 1;
  -- case 4 is about the VIEWS, not the write path, so it avoids that
  -- interaction entirely. The operation is completed directly (case 2
  -- already proves the delivery RPC itself).

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, value, currency, account_id, conversation_id, contact_id, status)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'cutover fixture 4', 1, 'GYD', v_account_id, v_conv_id, v_contact_id, 'open')
  RETURNING id INTO v_deal_id2;

  -- wacrm.origin=admin: this fixture asserts status=completed directly
  -- (not through crm_entregar_operacion), which would otherwise be
  -- suppressed by guard 12a (096) as an automation-origin completion.
  PERFORM set_config('wacrm.origin', 'admin', true);
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, quoted_source_amount, source_currency, completed_at)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, v_deal_id2, 'completed', 5000, 'GYD', now())
  ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL
    DO UPDATE SET status = 'completed', quoted_source_amount = 5000, source_currency = 'GYD', completed_at = now()
  RETURNING id INTO v_op_id2;
  PERFORM set_config('wacrm.origin', '', true);

  SELECT monto_gyd INTO v_monto FROM cerebro_historial_operaciones WHERE operation_id = v_op_id2;
  IF v_monto IS DISTINCT FROM 5000 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4a] cerebro_historial_operaciones.monto_gyd expected 5000 (from remittance_operations), got %', v_monto;
  ELSE
    RAISE NOTICE 'PASS [case 4a] cerebro_historial_operaciones prefers remittance_operations.quoted_source_amount over the stale deals.value';
  END IF;

  -- (case 4b was removed: it queried cerebro_conciliacion_operaciones,
  --  which 164 dropped by product decision. The check could never pass
  --  again, so it is gone rather than left failing.)

  -- Volume view: same coalesce-order flip, checked via the daily rollup.
  IF NOT EXISTS (
    SELECT 1 FROM cerebro_volumen_diario
     WHERE service_type = (SELECT service_type FROM remittance_operations WHERE id = v_op_id2)
       AND volumen_gyd >= 5000
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4c] cerebro_volumen_diario does not reflect remittance_operations.quoted_source_amount for the completed fixture operation';
  ELSE
    RAISE NOTICE 'PASS [case 4c] cerebro_volumen_diario reflects remittance_operations.quoted_source_amount';
  END IF;


  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'cutover: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'cutover: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT cutover;
