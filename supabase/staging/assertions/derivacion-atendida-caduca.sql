-- derivacion-atendida-caduca.sql — self-reverting assertion for
-- 104_derivacion_atendida_caduca.sql
--
-- Proves cerebro_caducar_derivacion_atendida(id) and the sweep
-- cerebro_caducar_derivaciones_atendidas(): a bot handoff (chat assigned to
-- the handoff profile 377b0c8c) is released once a person has written after
-- the handoff and N minutes pass without human activity (cerebro_config
-- 'derivacion_atendida_caduca_minutos', default 5). A handoff nobody has
-- attended yet stays, a manual pause stays, and chats assigned to a real
-- teammate are not touched. Also proves the pg_cron job and the ACL.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT derivacion_atendida_caduca;

DO $$
DECLARE
  v_owner_user   uuid := gen_random_uuid();
  v_account_id   uuid;
  v_dummy_hash   CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_bot_profile  CONSTANT uuid := '377b0c8c-c025-46ff-8088-7a929080831e';

  v_attended      uuid;  -- 1
  v_recent_human  uuid;  -- 2
  v_unattended    uuid;  -- 3
  v_half_state    uuid;  -- 4
  v_manual_pause  uuid;  -- 5
  v_teammate      uuid;  -- 6
  v_bot_after     uuid;  -- 7
  v_config        uuid;  -- 8

  v_released  uuid[];
  v_count     integer;
  v_row       record;
  v_job       record;
  v_fail_count integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'derivacion-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'derivacion atendida test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO cerebro_config (clave, valor) VALUES ('derivacion_atendida_caduca_minutos', '5')
  ON CONFLICT (clave) DO UPDATE SET valor = excluded.valor;

  WITH c AS (
    INSERT INTO contacts (id, user_id, phone, account_id)
    SELECT gen_random_uuid(), v_owner_user, '1555000070' || g, v_account_id
      FROM generate_series(1, 8) g
    RETURNING id, phone
  ), v AS (
    INSERT INTO conversations (id, user_id, contact_id, account_id)
    SELECT gen_random_uuid(), v_owner_user, c.id, v_account_id FROM c
    RETURNING id, contact_id
  )
  SELECT
    max(v.id::text) FILTER (WHERE c.phone = '15550000701')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000702')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000703')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000704')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000705')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000706')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000707')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000708')::uuid
  INTO v_attended, v_recent_human, v_unattended, v_half_state, v_manual_pause, v_teammate, v_bot_after, v_config
  FROM v JOIN c ON c.id = v.contact_id;

  -- 1 · handoff 1 h ago, a person replied 6 min ago -> released completely
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_summary = 'El caso requiere atención de un operador.', ai_handoff_at = now() - interval '1 hour', ai_reply_count = 7 WHERE id = v_attended;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_attended, 'agent', v_owner_user, 'text', 'Ya le atiendo', false, now() - interval '6 minutes');

  -- 2 · handoff 1 h ago, a person replied 2 min ago -> stays
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '1 hour' WHERE id = v_recent_human;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_recent_human, 'agent', v_owner_user, 'text', 'Primero', false, now() - interval '30 minutes'),
         (v_recent_human, 'agent', v_owner_user, 'text', 'Sigo aqui', false, now() - interval '2 minutes');

  -- 3 · handoff 30 min ago, the only human message is from BEFORE the handoff -> stays (nobody attended it)
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = true, ai_handoff_reason = 'bucle', ai_handoff_at = now() - interval '30 minutes' WHERE id = v_unattended;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_unattended, 'agent', v_owner_user, 'text', 'Mensaje viejo', false, now() - interval '2 hours');

  -- 4 · half state: bot active, no reason, still assigned to the handoff profile; person wrote after the assignment -> assignment removed
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = false, ai_handoff_reason = NULL, ai_handoff_at = NULL WHERE id = v_half_state;
  UPDATE conversations SET assigned_at = now() - interval '3 days' WHERE id = v_half_state;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_half_state, 'agent', v_owner_user, 'text', 'Atendido', false, now() - interval '2 days');

  -- 5 · manual pause (no reason) on a chat assigned to the handoff profile -> stays paused and assigned
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = true, ai_handoff_reason = NULL, ai_handoff_at = NULL WHERE id = v_manual_pause;
  UPDATE conversations SET assigned_at = now() - interval '3 days' WHERE id = v_manual_pause;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_manual_pause, 'agent', v_owner_user, 'text', 'Pausado a mano', false, now() - interval '2 days');

  -- 6 · assigned to a real teammate, paused by a handoff reason, old -> not this function's business
  UPDATE conversations SET assigned_agent_id = v_owner_user, ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '1 hour' WHERE id = v_teammate;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_teammate, 'agent', v_owner_user, 'text', 'Lo llevo yo', false, now() - interval '40 minutes');

  -- 7 · person replied 6 min ago, bot message 1 min ago -> bot output is not human activity, released
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = true, ai_handoff_reason = 'operacion_ambigua', ai_handoff_at = now() - interval '1 hour' WHERE id = v_bot_after;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_bot_after, 'agent', v_owner_user, 'text', 'Humano', false, now() - interval '6 minutes'),
         (v_bot_after, 'agent', NULL, 'text', 'Bot', true, now() - interval '1 minute');

  -- 8 · person replied 10 min ago, window raised to 30 min -> stays (evaluated last)
  UPDATE conversations SET assigned_agent_id = v_bot_profile, ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '1 hour' WHERE id = v_config;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_config, 'agent', v_owner_user, 'text', 'Atendido hace 10', false, now() - interval '10 minutes');

  -- ---- case 1 -----------------------------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_attended);
  SELECT assigned_agent_id, ai_autoreply_disabled, ai_handoff_reason, ai_handoff_summary, ai_handoff_at, ai_reply_count, ai_resumed_at INTO v_row FROM conversations WHERE id = v_attended;
  IF v_released IS DISTINCT FROM ARRAY[v_attended]
     OR v_row.assigned_agent_id IS NOT NULL OR v_row.ai_autoreply_disabled
     OR v_row.ai_handoff_reason IS NOT NULL OR v_row.ai_handoff_summary IS NOT NULL
     OR v_row.ai_handoff_at IS NOT NULL OR v_row.ai_reply_count <> 0 OR v_row.ai_resumed_at IS NULL
     OR NOT EXISTS (SELECT 1 FROM cerebro_memoria WHERE session_id = v_attended::text AND message->>'content' LIKE '%ATENCION HUMANA YA TERMINADA%') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected a full release with the human-attention-closed memory mark; released=%, row=%', v_released, v_row;
  ELSE
    RAISE NOTICE 'PASS [case 1] an attended handoff with 6 min of human inactivity is released completely';
  END IF;

  -- ---- cases 2, 3, 5, 6: must stay ---------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_recent_human);
  IF v_released IS NOT NULL OR (SELECT assigned_agent_id IS DISTINCT FROM v_bot_profile OR NOT ai_autoreply_disabled FROM conversations WHERE id = v_recent_human) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a person active 2 min ago must keep the handoff; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 2] recent human activity keeps the handoff';
  END IF;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_unattended);
  IF v_released IS NOT NULL OR (SELECT assigned_agent_id IS DISTINCT FROM v_bot_profile OR NOT ai_autoreply_disabled FROM conversations WHERE id = v_unattended) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a handoff nobody attended must stay; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 3] an unattended handoff stays';
  END IF;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_manual_pause);
  IF v_released IS NOT NULL OR (SELECT assigned_agent_id IS DISTINCT FROM v_bot_profile OR NOT ai_autoreply_disabled FROM conversations WHERE id = v_manual_pause) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a manual pause must never be released here; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 5] a manual pause stays paused';
  END IF;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_teammate);
  IF v_released IS NOT NULL OR (SELECT assigned_agent_id IS DISTINCT FROM v_owner_user OR NOT ai_autoreply_disabled FROM conversations WHERE id = v_teammate) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] a chat assigned to a real teammate must not be touched; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 6] a chat assigned to a real teammate is not touched';
  END IF;

  -- ---- case 4 -----------------------------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_half_state);
  SELECT assigned_agent_id, ai_autoreply_disabled INTO v_row FROM conversations WHERE id = v_half_state;
  IF v_released IS DISTINCT FROM ARRAY[v_half_state] OR v_row.assigned_agent_id IS NOT NULL OR v_row.ai_autoreply_disabled THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a half-state handoff must lose the assignment; released=%, row=%', v_released, v_row;
  ELSE
    RAISE NOTICE 'PASS [case 4] a half-state handoff loses the assignment';
  END IF;

  -- ---- case 7 -----------------------------------------------------------
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_bot_after);
  IF v_released IS DISTINCT FROM ARRAY[v_bot_after] OR (SELECT assigned_agent_id IS NOT NULL OR ai_autoreply_disabled FROM conversations WHERE id = v_bot_after) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] bot output must not count as human activity; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 7] a recent bot message does not keep the handoff';
  END IF;

  -- ---- case 8 -----------------------------------------------------------
  UPDATE cerebro_config SET valor = '30' WHERE clave = 'derivacion_atendida_caduca_minutos';
  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_config);
  IF v_released IS NOT NULL OR (SELECT assigned_agent_id IS DISTINCT FROM v_bot_profile FROM conversations WHERE id = v_config) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] with the window at 30 min a 10 min handoff must stay; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 8] the window is read from cerebro_config';
  END IF;

  -- ---- case 9: the sweep reuses the rule -------------------------------------
  UPDATE cerebro_config SET valor = '5' WHERE clave = 'derivacion_atendida_caduca_minutos';
  v_count := cerebro_caducar_derivaciones_atendidas();
  IF v_count < 1
     OR (SELECT assigned_agent_id IS NOT NULL FROM conversations WHERE id = v_config)
     OR (SELECT assigned_agent_id IS DISTINCT FROM v_bot_profile OR NOT ai_autoreply_disabled FROM conversations WHERE id = v_unattended)
     OR (SELECT assigned_agent_id IS DISTINCT FROM v_bot_profile OR NOT ai_autoreply_disabled FROM conversations WHERE id = v_manual_pause)
     OR (SELECT assigned_agent_id IS DISTINCT FROM v_owner_user FROM conversations WHERE id = v_teammate) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] the sweep must release expired attended handoffs only; count=%', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 9] the sweep releases expired attended handoffs and nothing else (% released)', v_count;
  END IF;

  -- ---- case 10: pg_cron runs the sweep every minute ----------------------
  SELECT schedule, command, active INTO v_job FROM cron.job WHERE jobname = 'caducar-derivaciones-atendidas';
  IF NOT FOUND OR v_job.schedule <> '* * * * *' OR NOT v_job.active
     OR v_job.command NOT LIKE '%cerebro_caducar_derivaciones_atendidas()%' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] expected an active every-minute cron job calling the sweep; got %', v_job;
  ELSE
    RAISE NOTICE 'PASS [case 10] pg_cron runs the sweep every minute';
  END IF;

  -- ---- case 11: ACL -----------------------------------------------------------
  IF has_function_privilege('anon', 'public.cerebro_caducar_derivaciones_atendidas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_caducar_derivaciones_atendidas()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_caducar_derivacion_atendida(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_caducar_derivacion_atendida(uuid)', 'EXECUTE') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 11] anon/authenticated must not execute the functions';
  ELSE
    RAISE NOTICE 'PASS [case 11] anon and authenticated cannot execute the functions';
  END IF;

  -- ---- cases 12-13: assignment removed by hand, bot still paused ------------
  -- 12 · attended (person wrote 6 min ago, after the handoff) -> released
  -- 13 · nobody attended after the handoff -> stays
  UPDATE conversations SET assigned_agent_id = NULL, ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '1 hour' WHERE id = v_recent_human;
  DELETE FROM messages WHERE conversation_id = v_recent_human;
  INSERT INTO messages (conversation_id, sender_type, sender_id, content_type, content_text, ai_generated, created_at)
  VALUES (v_recent_human, 'agent', v_owner_user, 'text', 'Atendido', false, now() - interval '6 minutes');

  UPDATE conversations SET assigned_agent_id = NULL WHERE id = v_unattended;

  SELECT array_agg(id) INTO v_released FROM cerebro_caducar_derivacion_atendida(v_recent_human);
  IF v_released IS DISTINCT FROM ARRAY[v_recent_human]
     OR (SELECT ai_autoreply_disabled OR ai_handoff_reason IS NOT NULL FROM conversations WHERE id = v_recent_human) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 12] an attended handoff whose assignment was removed by hand must be released; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 12] an attended handoff whose assignment was removed by hand is released';
  END IF;

  PERFORM cerebro_caducar_derivaciones_atendidas();
  IF NOT (SELECT ai_autoreply_disabled AND ai_handoff_reason = 'bucle' FROM conversations WHERE id = v_unattended)
     OR NOT (SELECT ai_autoreply_disabled AND ai_handoff_reason IS NULL FROM conversations WHERE id = v_manual_pause) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 13] an unattended unassigned handoff and a manual pause must stay paused';
  ELSE
    RAISE NOTICE 'PASS [case 13] an unattended unassigned handoff and a manual pause stay paused';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'derivacion-atendida-caduca: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'derivacion-atendida-caduca: ALL PASS (13 expectations)';
END $$;

ROLLBACK TO SAVEPOINT derivacion_atendida_caduca;
