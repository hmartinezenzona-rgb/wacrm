\set ON_ERROR_STOP on
-- (2026-10-05) Fixture rebuilt: the operations come from cerebro_crear_operacion and the deal is linked to them (a deal no longer creates one since 161/172/183).
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- cash-delivery-activation.sql — self-reverting assertion for
-- 151_cash_delivery_activation.sql
--
-- Proves the two pieces that make B1.4 actually fire:
--   case 1 — a remesas deal whose notes say "ENTREGA EN USD: Efectivo"
--            (what marcar_destino_usd writes) ends with its operation's
--            delivery_method = 'efectivo_usd'.
--   case 2 — regression: "ENTREGA EN USD: Clasica" still maps to 'clasica'.
--   case 2b/2c — regression of the live last-mark-wins behavior, both ways.
--   case 3 — partial data (phone only) creates NO notification.
--   case 4 — the call that completes phone + address + ID photo creates
--            exactly one 'entrega_efectivo_lista' notification per
--            owner/admin of the account, and none for an agent.
--   case 5 — a later call on an already-complete recipient (a changed
--            address) creates NO second notification.
--   case 6 — the operation is never assigned or paused by any of this: the
--            bot keeps attending the chat (conversations.assigned_agent_id
--            and ai_autoreply_disabled untouched).
--
-- RED (against 042-150): case 1 fails (delivery_method stays NULL because
--   the parser only accepts Clasica|Tropical) and cases 3-5 fail (the
--   notification type is not allowed and nothing inserts it).
-- GREEN (after 151): all cases pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT cash_delivery_activation;

DO $$
DECLARE
  v_owner_user  uuid := gen_random_uuid();
  v_admin_user  uuid := gen_random_uuid();
  v_agent_user  uuid := gen_random_uuid();
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_pipeline    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_solicitada  CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_acc         uuid;
  v_ct          uuid;
  v_conv        uuid;
  v_ct2         uuid;
  v_conv2       uuid;
  v_deal        uuid;
  v_deal2       uuid;
  v_op          uuid;
  v_op2         uuid;
  v_method      text;
  v_count       integer;
  v_agent_n     integer;
  v_assigned    uuid;
  v_paused      boolean;
  v_fail_count  integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cda-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cda-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cda-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cash delivery activation test account', v_owner_user)
  RETURNING id INTO v_acc;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'cda owner', 'cda-owner-' || v_owner_user || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin_user, 'cda admin', 'cda-admin-' || v_admin_user || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent_user, 'cda agent', 'cda-agent-' || v_agent_user || '@test.invalid', v_acc, 'agent');

  INSERT INTO pipelines (id, user_id, name, account_id)
  VALUES (v_pipeline, v_owner_user, 'Remesas', v_acc) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position")
  VALUES (v_solicitada, v_pipeline, 'Solicitada', 10) ON CONFLICT (id) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner_user, '59900151001', 'Cliente CDA Efectivo', v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_ct, v_acc) RETURNING id INTO v_conv;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner_user, '59900151002', 'Cliente CDA Clasica', v_acc) RETURNING id INTO v_ct2;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_ct2, v_acc) RETURNING id INTO v_conv2;

  -- Exactly the INSERT marcar_destino_usd does when there is no open deal.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_owner_user, v_acc, v_ct, v_conv, v_pipeline, v_solicitada, 'Remesa +59900151001', 0, 'GYD', 'ENTREGA EN USD: Efectivo', 'open')
  RETURNING id INTO v_deal;
  -- (2026-10-05) A deal no longer creates the operation: create it deal-free, link the deal, and re-fire the notes sync (the live
  -- trg_sync_z_benef_desde_deal, left on purpose by 172) now that the operation exists.
  v_op := cerebro_crear_operacion(v_conv, 0, 'GYD', v_solicitada);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;

  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_owner_user, v_acc, v_ct2, v_conv2, v_pipeline, v_solicitada, 'Remesa +59900151002', 0, 'GYD', 'ENTREGA EN USD: Clasica', 'open')
  RETURNING id INTO v_deal2;
  v_op2 := cerebro_crear_operacion(v_conv2, 0, 'GYD', v_solicitada);
  UPDATE remittance_operations SET deal_id = v_deal2 WHERE id = v_op2;
  UPDATE deals SET notes = notes WHERE id = v_deal2;

  -- ===========================================================================
  -- CASE 1 — "Efectivo" marks the operation efectivo_usd.
  -- ===========================================================================
  SELECT delivery_method INTO v_method FROM remittance_operations WHERE deal_id = v_deal;
  IF v_method IS DISTINCT FROM 'efectivo_usd' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected delivery_method efectivo_usd, got %', v_method;
  ELSE
    RAISE NOTICE 'PASS [case 1] ENTREGA EN USD: Efectivo -> delivery_method efectivo_usd';
  END IF;

  -- ===========================================================================
  -- CASE 2 — regression: Clasica still maps to clasica.
  -- ===========================================================================
  SELECT delivery_method INTO v_method FROM remittance_operations WHERE deal_id = v_deal2;
  IF v_method IS DISTINCT FROM 'clasica' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected delivery_method clasica, got %', v_method;
  ELSE
    RAISE NOTICE 'PASS [case 2] ENTREGA EN USD: Clasica still -> clasica';
  END IF;

  -- ===========================================================================
  -- CASE 2b — regression of the LIVE last-mark-wins behavior: a customer who
  -- changes their mind. Clasica then Efectivo -> efectivo_usd; and back,
  -- Efectivo then Clasica -> clasica (Clasica sorts BEFORE Efectivo, so the
  -- alphabetical ORDER BY 1 DESC fallback would pick Efectivo: this only
  -- passes if the LAST mark wins).
  -- ===========================================================================
  UPDATE deals SET notes = notes || E'\n---\nENTREGA EN USD: Efectivo' WHERE id = v_deal2;
  SELECT delivery_method INTO v_method FROM remittance_operations WHERE deal_id = v_deal2;
  IF v_method IS DISTINCT FROM 'efectivo_usd' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2b] Clasica then Efectivo: expected efectivo_usd, got %', v_method;
  ELSE
    RAISE NOTICE 'PASS [case 2b] Clasica then Efectivo -> efectivo_usd (last mark wins)';
  END IF;

  UPDATE deals SET notes = notes || E'\n---\nENTREGA EN USD: Clasica' WHERE id = v_deal2;
  SELECT delivery_method INTO v_method FROM remittance_operations WHERE deal_id = v_deal2;
  IF v_method IS DISTINCT FROM 'clasica' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2c] Efectivo then Clasica: expected clasica, got %', v_method;
  ELSE
    RAISE NOTICE 'PASS [case 2c] Efectivo then Clasica -> clasica (last mark wins)';
  END IF;

  -- Cases 3-6 need the efectivo operation from case 1. If case 1 failed
  -- the RPC has nothing to record against; report and stop here.
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'cash-delivery-activation: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  -- ===========================================================================
  -- CASE 3 — partial data creates no notification.
  -- ===========================================================================
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, '53999001', NULL, NULL);
  SELECT count(*) INTO v_count FROM notifications
   WHERE account_id = v_acc AND type = 'entrega_efectivo_lista';
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected 0 notifications after partial data, got %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 3] partial data -> no notification';
  END IF;

  -- ===========================================================================
  -- CASE 4 — completing the data notifies owner + admin once, not the agent.
  -- ===========================================================================
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, NULL, 'Calle 23 #456, Vedado', NULL);
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, NULL, NULL, 'wamid.test151.carnet');
  SELECT count(*) INTO v_count FROM notifications
   WHERE account_id = v_acc AND type = 'entrega_efectivo_lista';
  SELECT count(*) INTO v_agent_n FROM notifications
   WHERE account_id = v_acc AND type = 'entrega_efectivo_lista' AND user_id = v_agent_user;
  IF v_count <> 2 OR v_agent_n <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected 2 notifications (owner+admin) and 0 for the agent, got % and %', v_count, v_agent_n;
  ELSE
    RAISE NOTICE 'PASS [case 4] completing the data notifies owner and admin once each';
  END IF;

  -- ===========================================================================
  -- CASE 5 — a later change on a complete recipient does not notify again.
  -- ===========================================================================
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, NULL, 'Calle 25 #100, Vedado', NULL);
  SELECT count(*) INTO v_count FROM notifications
   WHERE account_id = v_acc AND type = 'entrega_efectivo_lista';
  IF v_count <> 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected still 2 notifications, got %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 5] a change after completion does not notify again';
  END IF;

  -- ===========================================================================
  -- CASE 6 — the bot keeps attending: nothing assigns or pauses the chat.
  -- ===========================================================================
  SELECT assigned_agent_id, coalesce(ai_autoreply_disabled, false)
    INTO v_assigned, v_paused
    FROM conversations WHERE id = v_conv;
  IF v_assigned IS NOT NULL OR v_paused THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected the chat unassigned and unpaused, got assigned=% paused=%', v_assigned, v_paused;
  ELSE
    RAISE NOTICE 'PASS [case 6] the chat stays with the bot (not assigned, not paused)';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'cash-delivery-activation: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'cash-delivery-activation: ALL PASS (8 expectations)';
END $$;

ROLLBACK TO SAVEPOINT cash_delivery_activation;
