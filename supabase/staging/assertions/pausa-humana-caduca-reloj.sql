-- pausa-humana-caduca-reloj.sql — self-reverting assertion for
-- 103_pausa_humana_caduca_por_reloj.sql
--
-- Proves cerebro_caducar_pausas_humanas(): the clock-driven sweep that
-- releases every expired agent_replied pause without waiting for the client
-- to write (so the inbox stops showing the chat as owned by a person), while
-- manual pauses, bot handoffs and still-fresh human pauses stay. Also proves
-- the pg_cron job that runs it every minute and the function's ACL.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT pausa_humana_caduca_reloj;

DO $$
DECLARE
  v_owner_user   uuid := gen_random_uuid();
  v_account_id   uuid;
  v_dummy_hash   CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_bot_profile  CONSTANT uuid := '377b0c8c-c025-46ff-8088-7a929080831e';

  v_conv_expired_a uuid;
  v_conv_expired_b uuid;
  v_conv_fresh     uuid;
  v_conv_manual    uuid;
  v_conv_bot       uuid;

  v_released   integer;
  v_job        record;
  v_fail_count integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'pausa-reloj-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'pausa reloj test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO cerebro_config (clave, valor) VALUES ('pausa_humana_caduca_minutos', '5')
  ON CONFLICT (clave) DO UPDATE SET valor = excluded.valor;

  WITH c AS (
    INSERT INTO contacts (id, user_id, phone, account_id)
    SELECT gen_random_uuid(), v_owner_user, '1555000060' || g, v_account_id
      FROM generate_series(1, 5) g
    RETURNING id, phone
  ), v AS (
    INSERT INTO conversations (id, user_id, contact_id, account_id)
    SELECT gen_random_uuid(), v_owner_user, c.id, v_account_id FROM c
    RETURNING id, contact_id
  )
  SELECT
    max(v.id::text) FILTER (WHERE c.phone = '15550000601')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000602')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000603')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000604')::uuid,
    max(v.id::text) FILTER (WHERE c.phone = '15550000605')::uuid
  INTO v_conv_expired_a, v_conv_expired_b, v_conv_fresh, v_conv_manual, v_conv_bot
  FROM v JOIN c ON c.id = v.contact_id;

  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '3 days' WHERE id = v_conv_expired_a;
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '6 minutes' WHERE id = v_conv_expired_b;
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '1 minute' WHERE id = v_conv_fresh;
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = NULL, ai_handoff_at = NULL WHERE id = v_conv_manual;
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '3 days', assigned_agent_id = v_bot_profile WHERE id = v_conv_bot;

  -- ---- case 1: the sweep releases every expired agent_replied pause ------
  v_released := cerebro_caducar_pausas_humanas();
  IF v_released < 2
     OR (SELECT ai_autoreply_disabled OR ai_handoff_reason IS NOT NULL FROM conversations WHERE id = v_conv_expired_a)
     OR (SELECT ai_autoreply_disabled OR ai_handoff_reason IS NOT NULL FROM conversations WHERE id = v_conv_expired_b) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected both expired pauses released; released=%', v_released;
  ELSE
    RAISE NOTICE 'PASS [case 1] the sweep releases every expired agent_replied pause (% released)', v_released;
  END IF;

  -- ---- case 2: a fresh human pause stays ---------------------------------
  IF NOT (SELECT ai_autoreply_disabled AND ai_handoff_reason = 'agent_replied' FROM conversations WHERE id = v_conv_fresh) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a 1-minute-old human pause must stay';
  ELSE
    RAISE NOTICE 'PASS [case 2] a fresh human pause stays';
  END IF;

  -- ---- case 3: a manual pause never expires ------------------------------
  IF NOT (SELECT ai_autoreply_disabled AND ai_handoff_reason IS NULL FROM conversations WHERE id = v_conv_manual) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a manual pause must stay paused';
  ELSE
    RAISE NOTICE 'PASS [case 3] a manual pause stays paused';
  END IF;

  -- ---- case 4: a bot handoff never expires here --------------------------
  IF NOT (SELECT ai_autoreply_disabled AND ai_handoff_reason = 'solicitud_cliente' AND assigned_agent_id = v_bot_profile FROM conversations WHERE id = v_conv_bot) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a bot handoff must stay';
  ELSE
    RAISE NOTICE 'PASS [case 4] a bot handoff stays';
  END IF;

  -- ---- case 5: a second sweep is a no-op for these fixtures --------------
  PERFORM cerebro_caducar_pausas_humanas();
  IF NOT (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_fresh)
     OR NOT (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv_manual) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] repeated sweeps must not release fresh or manual pauses';
  ELSE
    RAISE NOTICE 'PASS [case 5] repeated sweeps are safe';
  END IF;

  -- ---- case 6: pg_cron runs the sweep every minute -----------------------
  SELECT schedule, command, active INTO v_job FROM cron.job WHERE jobname = 'caducar-pausas-humanas';
  IF NOT FOUND OR v_job.schedule <> '* * * * *' OR NOT v_job.active
     OR v_job.command NOT LIKE '%cerebro_caducar_pausas_humanas()%' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected an active every-minute cron job calling the sweep; got %', v_job;
  ELSE
    RAISE NOTICE 'PASS [case 6] pg_cron runs the sweep every minute';
  END IF;

  -- ---- case 7: nobody with a session or the public key can call it ------
  IF has_function_privilege('anon', 'public.cerebro_caducar_pausas_humanas()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_caducar_pausas_humanas()', 'EXECUTE') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] anon/authenticated must not execute the sweep';
  ELSE
    RAISE NOTICE 'PASS [case 7] anon and authenticated cannot execute the sweep';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'pausa-humana-caduca-reloj: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'pausa-humana-caduca-reloj: ALL PASS (7 expectations)';
END $$;

ROLLBACK TO SAVEPOINT pausa_humana_caduca_reloj;
