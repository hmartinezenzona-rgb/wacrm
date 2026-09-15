-- pausa-humana-caduca.sql — self-reverting assertion for
-- 102_pausa_humana_caduca.sql
--
-- Proves cerebro_caducar_pausa_humana: the automatic pause that a human
-- panel send leaves on a conversation (ai_handoff_reason = 'agent_replied')
-- expires after N minutes without human activity (cerebro_config
-- 'pausa_humana_caduca_minutos', default 5), while manual pauses and the
-- bot's own handoffs never expire through this path.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT pausa_humana_caduca;

DO $$
DECLARE
  v_owner_user   uuid := gen_random_uuid();
  v_account_id   uuid;
  v_dummy_hash   CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_bot_profile  CONSTANT uuid := '377b0c8c-c025-46ff-8088-7a929080831e';

  v_conv_expired     uuid;
  v_conv_recent_msg  uuid;
  v_conv_recent_hand uuid;
  v_conv_manual      uuid;
  v_conv_bot_handoff uuid;
  v_conv_bot_msg     uuid;
  v_conv_assigned    uuid;
  v_conv_config      uuid;
  v_conv_other       uuid;

  v_released  uuid[];
  v_row       record;
  v_fail_count integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pausa-humana-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'pausa humana test account', v_owner_user)
  RETURNING id INTO v_account_id;

  -- The expiry reads cerebro_config; pin the default so a staging value
  -- cannot change the verdict. Case 7 overrides it later.
  INSERT INTO cerebro_config (clave, valor) VALUES ('pausa_humana_caduca_minutos', '5')
  ON CONFLICT (clave) DO UPDATE SET valor = excluded.valor;

  -- One contact + conversation per case (094: one conversation per contact).
  WITH c AS (
    INSERT INTO contacts (id, user_id, phone, account_id)
    SELECT gen_random_uuid(), v_owner_user, '1555000050' || g, v_account_id
      FROM generate_series(1, 9) g
    RETURNING id, phone
  ), v AS (
    INSERT INTO conversations (id, user_id, contact_id, account_id)
    SELECT gen_random_uuid(), v_owner_user, c.id, v_account_id FROM c
    RETURNING id, contact_id
  )
  SELECT
    max(v.id::text) FILTER (WHERE c.phone = '15550000501')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000502')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000503')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000504')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000505')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000506')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000507')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000508')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000509')::uuid
  INTO v_conv_expired, v_conv_recent_msg, v_conv_recent_hand, v_conv_manual,
       v_conv_bot_handoff, v_conv_bot_msg, v_conv_assigned, v_conv_config, v_conv_other
  FROM v JOIN c ON c.id = v.contact_id;

  -- 1 · agent_replied, last human message 6 min ago -> expires
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '6 minutes' WHERE id = v_conv_expired;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_conv_expired, 'agent', v_owner_user, 'text', 'Hola buenos dias', false, now() - interval '6 minutes');

  -- 2 · agent_replied 20 min ago, but a human wrote 2 min ago -> stays
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '20 minutes' WHERE id = v_conv_recent_msg;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_conv_recent_msg, 'agent', v_owner_user, 'text', 'Primer mensaje', false, now() - interval '20 minutes'),
         (v_conv_recent_msg, 'agent', v_owner_user, 'text', 'Sigo aqui', false, now() - interval '2 minutes');

  -- 3 · agent_replied 2 min ago with no newer message rows -> stays
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '2 minutes' WHERE id = v_conv_recent_hand;

  -- 4 · manual pause (no reason), 1 hour old -> never expires here
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = NULL, ai_handoff_at = NULL WHERE id = v_conv_manual;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_conv_manual, 'agent', v_owner_user, 'text', 'Pausado a mano', false, now() - interval '1 hour');

  -- 5 · bot handoff ('bucle', bot profile), 1 hour old -> never expires here
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'bucle', ai_handoff_at = now() - interval '1 hour', assigned_agent_id = v_bot_profile WHERE id = v_conv_bot_handoff;

  -- 6 · human 6 min ago, BOT message 1 min ago -> bot output is not human activity, expires
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '6 minutes' WHERE id = v_conv_bot_msg;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_conv_bot_msg, 'agent', v_owner_user, 'text', 'Humano', false, now() - interval '6 minutes'),
         (v_conv_bot_msg, 'agent', NULL, 'text', 'Bot', true, now() - interval '1 minute');

  -- 7 · agent_replied 6 min ago on a chat ASSIGNED to a person -> pause expires, assignment untouched
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '6 minutes', assigned_agent_id = v_owner_user WHERE id = v_conv_assigned;

  -- 8 · config raised to 30 min, human 10 min ago -> stays
  -- (evaluated after the default-5 cases, see below)
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '10 minutes' WHERE id = v_conv_config;

  -- 9 · expirable conversation that is NOT the argument -> untouched by another call
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '6 minutes' WHERE id = v_conv_other;

  -- ---- case 1 -----------------------------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_expired);
  SELECT ai_autoreply_disabled, ai_handoff_reason, ai_handoff_at, ai_resumed_at INTO v_row FROM conversations WHERE id = v_conv_expired;
  IF v_released IS DISTINCT FROM ARRAY[v_conv_expired]
     OR v_row.ai_autoreply_disabled OR v_row.ai_handoff_reason IS NOT NULL
     OR v_row.ai_handoff_at IS NOT NULL OR v_row.ai_resumed_at IS NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected release with reason/at cleared and ai_resumed_at set; got released=%, row=%', v_released, v_row;
  ELSE
    RAISE NOTICE 'PASS [case 1] an agent_replied pause with 6 min of human inactivity expires';
  END IF;

  -- ---- case 9 (checked right after case 1 released only its argument) ----
  SELECT ai_autoreply_disabled, ai_handoff_reason INTO v_row FROM conversations WHERE id = v_conv_other;
  IF NOT v_row.ai_autoreply_disabled OR v_row.ai_handoff_reason IS DISTINCT FROM 'agent_replied' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] another conversation was modified; got row=%', v_row;
  ELSE
    RAISE NOTICE 'PASS [case 9] only the conversation passed as argument is released';
  END IF;

  -- ---- cases 2-5: must stay paused -------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_recent_msg);
  IF v_released IS NOT NULL OR NOT (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_recent_msg) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a human message 2 min ago must keep the pause; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 2] a recent human message keeps the pause';
  END IF;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_recent_hand);
  IF v_released IS NOT NULL OR NOT (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_recent_hand) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a pause set 2 min ago must stay; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 3] a pause set 2 min ago stays';
  END IF;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_manual);
  IF v_released IS NOT NULL OR NOT (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_manual) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a manual pause must never expire here; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 4] a manual pause does not expire';
  END IF;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_bot_handoff);
  SELECT ai_autoreply_disabled, ai_handoff_reason, assigned_agent_id INTO v_row FROM conversations WHERE id = v_conv_bot_handoff;
  IF v_released IS NOT NULL OR NOT v_row.ai_autoreply_disabled
     OR v_row.ai_handoff_reason IS DISTINCT FROM 'bucle' OR v_row.assigned_agent_id IS DISTINCT FROM v_bot_profile THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a bot handoff must never expire here; released=%, row=%', v_released, v_row;
  ELSE
    RAISE NOTICE 'PASS [case 5] a bot handoff does not expire';
  END IF;

  -- ---- case 6 -----------------------------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_bot_msg);
  IF v_released IS DISTINCT FROM ARRAY[v_conv_bot_msg] OR (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_bot_msg) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] bot output must not count as human activity; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 6] a recent bot message does not keep the pause';
  END IF;

  -- ---- case 7 -----------------------------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_assigned);
  SELECT ai_autoreply_disabled, assigned_agent_id INTO v_row FROM conversations WHERE id = v_conv_assigned;
  IF v_released IS DISTINCT FROM ARRAY[v_conv_assigned] OR v_row.ai_autoreply_disabled
     OR v_row.assigned_agent_id IS DISTINCT FROM v_owner_user THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] pause must expire without touching the assignment; released=%, row=%', v_released, v_row;
  ELSE
    RAISE NOTICE 'PASS [case 7] the pause expires and the assignment is left to its own expiry';
  END IF;

  -- ---- case 8 -----------------------------------------------------------
  UPDATE cerebro_config SET valor = '30' WHERE clave = 'pausa_humana_caduca_minutos';
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_pausa_humana(v_conv_config);
  IF v_released IS NOT NULL OR NOT (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_config) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] with the window at 30 min a 10 min pause must stay; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 8] the window is read from cerebro_config';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'pausa-humana-caduca: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'pausa-humana-caduca: ALL PASS (9 expectations)';
END $$;

ROLLBACK TO SAVEPOINT pausa_humana_caduca;
