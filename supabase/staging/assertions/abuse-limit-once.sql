\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 361 (cerebro_control_abuso: the message-rate limit locks once, alerts once, and never fires on a chat a
-- team member is attending). Run as  BEGIN; 361; <this file>; ROLLBACK;  or with 361 applied. Self-reverting: ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. RED before 361: the function does not exist and the first expectation fails.
-- Alerts are counted in net.http_request_queue (rolled back with the transaction, so nothing is ever sent).
-- Synthetic PRUEBA fixtures. Cases:
--   1. the real shape (64 events in the hour, nobody attending): the first pass locks and alerts once, three more passes are silent;
--   2. a team member wrote 5 min ago: no lock, no alert, continue; a bot message does not count as a person; a person 45 min ago does not
--      protect the chat; a person protects only an unlocked chat (an abuse-locked chat stays silent);
--   3. under or at the limit (40 events) continues, 41 locks (boundary); events older than an hour do not count;
--   4. the team unassigns / re-enables the chat, then a new flood locks and alerts again (second alert);
--   5. a chat assigned to a person is never locked (silent, no alert);
--   6. a chat held by the bot for another reason (bucle) is re-labelled abuso once and alerts once;
--   7. cerebro_registrar_derivacion is unchanged for other motivos (still returns a row on a repeat for the bot-held chat, not for a
--      person-held chat, and not when the condition is false);
--   8. the LIMITE payload keeps type, cliente_phone, eventos, preguntas_repetidas; grants: service_role only.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t361.fail', (coalesce(nullif(current_setting('t361.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, OUT o_conv uuid, OUT o_phone text) LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  o_phone := '59900361' || p_tag;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, o_phone, 'PRUEBA361' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
END $$;

-- n customer events spread over the last 50 minutes (or, with p_ago, all older than that interval).
CREATE OR REPLACE FUNCTION pg_temp.ev(p_conv uuid, p_phone text, p_n int, p_ago interval DEFAULT interval '0') RETURNS void LANGUAGE sql AS $$
  INSERT INTO session_events (conversation_id, contact_phone, tipo, creado_at)
  SELECT p_conv, p_phone, 'text', now() - p_ago - make_interval(secs => g * 20) FROM generate_series(1, p_n) g
$$;

CREATE OR REPLACE FUNCTION pg_temp.msg(p_conv uuid, p_ai boolean, p_ago interval) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action, created_at)
  VALUES (p_conv, 'agent', 'text', 'PRUEBA361', 'sent', p_ai, false, now() - p_ago)
$$;

CREATE OR REPLACE FUNCTION pg_temp.alerts(p_phone text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM net.http_request_queue q WHERE convert_from(q.body, 'UTF8') LIKE '%' || p_phone || '%'
$$;

CREATE OR REPLACE FUNCTION pg_temp.st(p_conv uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(c.ai_autoreply_disabled::text, '_') || '/' || coalesce(c.ai_handoff_reason, '_') || '/' ||
         CASE WHEN c.assigned_agent_id IS NULL THEN 'none'
              WHEN c.assigned_agent_id = '377b0c8c-c025-46ff-8088-7a929080831e' THEN 'bot' ELSE 'person' END
    FROM conversations c WHERE c.id = p_conv
$$;

-- one pass: eventos|excede|bloquear_ahora
CREATE OR REPLACE FUNCTION pg_temp.pass(p_conv uuid, p_q int DEFAULT 0) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  SELECT eventos || '|' || excede || '|' || bloquear_ahora INTO v FROM cerebro_control_abuso(p_conv, p_q);
  RETURN v;
END $$;

DO $$
DECLARE
  v_bot constant uuid := '377b0c8c-c025-46ff-8088-7a929080831e';
  v_person uuid; v_conv uuid; v_phone text; v_r text; v_i int; v_n int; v_body jsonb;
BEGIN
  PERFORM pg_temp.chk(to_regprocedure('public.cerebro_control_abuso(uuid,integer)') IS NOT NULL, '0 cerebro_control_abuso exists');
  IF to_regprocedure('public.cerebro_control_abuso(uuid,integer)') IS NULL THEN
    RAISE EXCEPTION '% expectation(s) failed (function missing)', coalesce(nullif(current_setting('t361.fail', true), ''), '0');
  END IF;
  SELECT p.user_id INTO v_person FROM profiles p WHERE p.user_id <> v_bot ORDER BY p.user_id LIMIT 1;

  -- 1. the real shape: 64 events in the hour, nobody attending
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('01');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 0, '1 no alert before the first pass');
  v_r := pg_temp.pass(v_conv, 2);
  PERFORM pg_temp.chk(v_r = '64|true|true', '1 first pass locks now: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.st(v_conv) = 'true/abuso/bot', '1 chat is locked for abuse and held by the bot: ' || pg_temp.st(v_conv));
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 1, '1 exactly one alert after the first pass');
  FOR v_i IN 1..3 LOOP
    v_r := pg_temp.pass(v_conv, 2);
    PERFORM pg_temp.chk(v_r = '64|true|false', '1 repeated pass ' || v_i || ' is silent: ' || v_r);
  END LOOP;
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 1, '1 still exactly one alert after four passes');
  PERFORM pg_temp.chk(pg_temp.st(v_conv) = 'true/abuso/bot', '1 state unchanged by the silent passes');
  SELECT convert_from(q.body, 'UTF8')::jsonb INTO v_body FROM net.http_request_queue q WHERE convert_from(q.body, 'UTF8') LIKE '%' || v_phone || '%';
  PERFORM pg_temp.chk(v_body ->> 'type' = 'LIMITE' AND v_body ->> 'cliente_phone' = v_phone AND (v_body ->> 'eventos')::int = 64
                      AND (v_body ->> 'preguntas_repetidas')::int = 2, '8 payload keeps type, cliente_phone, eventos, preguntas_repetidas');

  -- 2. a team member is attending
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('02');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  PERFORM pg_temp.msg(v_conv, false, interval '5 minutes');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|false|false', '2 person wrote 5 min ago: continue, no lock: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.st(v_conv) = 'false/_/none' AND pg_temp.alerts(v_phone) = 0, '2 chat untouched and no alert');
  -- a bot message is not a person
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('03');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  PERFORM pg_temp.msg(v_conv, true, interval '5 minutes');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|true', '2 a bot message does not protect the chat: ' || v_r);
  -- a person 45 minutes ago is outside the 30 minute window
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('04');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  PERFORM pg_temp.msg(v_conv, false, interval '45 minutes');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|true', '2 a person 45 min ago does not protect the chat: ' || v_r);
  -- an abuse-locked chat stays silent even if a person writes afterwards
  PERFORM pg_temp.msg(v_conv, false, interval '1 minute');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|false' AND pg_temp.alerts(v_phone) = 1, '2 locked chat stays silent after a person writes: ' || v_r);

  -- 3. the boundary and the window
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('05');
  PERFORM pg_temp.ev(v_conv, v_phone, 40);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '40|false|false' AND pg_temp.st(v_conv) = 'false/_/none', '3 exactly 40 events continues: ' || v_r);
  PERFORM pg_temp.ev(v_conv, v_phone, 1, interval '1 minute');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '41|true|true', '3 41 events locks: ' || v_r);
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('06');
  PERFORM pg_temp.ev(v_conv, v_phone, 64, interval '2 hours');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '0|false|false' AND pg_temp.alerts(v_phone) = 0, '3 events older than an hour do not count: ' || v_r);

  -- 4. the team unassigns / re-enables, then a new flood alerts again
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('07');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  PERFORM pg_temp.pass(v_conv);
  PERFORM pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 1, '4 one alert for the first flood');
  UPDATE conversations SET assigned_agent_id = NULL, ai_autoreply_disabled = false, ai_handoff_reason = NULL, ai_handoff_summary = NULL,
                           ai_handoff_at = NULL WHERE id = v_conv;
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|true', '4 after the team re-enabled the chat a new flood locks again: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 2, '4 and alerts again (second alert)');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|false' AND pg_temp.alerts(v_phone) = 2, '4 then silent again: ' || v_r);

  -- 5. assigned to a person: never locked
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('08');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  UPDATE conversations SET assigned_agent_id = v_person WHERE id = v_conv;
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|false' AND pg_temp.alerts(v_phone) = 0 AND pg_temp.st(v_conv) = 'false/_/person',
                      '5 person-held chat is not taken over, no alert: ' || v_r);

  -- 6. held by the bot for another reason: re-labelled once, alert once
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('09');
  PERFORM pg_temp.ev(v_conv, v_phone, 64);
  PERFORM cerebro_registrar_derivacion(v_conv, 'x', 'bucle', true);
  PERFORM pg_temp.chk(pg_temp.st(v_conv) = 'true/bucle/bot', '6 setup: locked for bucle');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|true' AND pg_temp.st(v_conv) = 'true/abuso/bot' AND pg_temp.alerts(v_phone) = 1, '6 bucle-held chat becomes abuso with one alert: ' || v_r);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = '64|true|false' AND pg_temp.alerts(v_phone) = 1, '6 then silent: ' || v_r);

  -- 7. cerebro_registrar_derivacion itself is unchanged for other motivos
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('10');
  SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(v_conv, 'x', 'bucle', true);
  PERFORM pg_temp.chk(v_n = 1, '7 first bucle derivation returns a row');
  SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(v_conv, 'x', 'bucle', true);
  PERFORM pg_temp.chk(v_n = 1, '7 repeat on the bot-held chat still returns a row (unchanged behaviour)');
  SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(v_conv, 'x', 'bucle', false);
  PERFORM pg_temp.chk(v_n = 0, '7 false condition returns nothing');
  UPDATE conversations SET assigned_agent_id = v_person WHERE id = v_conv;
  SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(v_conv, 'x', 'bucle', true);
  PERFORM pg_temp.chk(v_n = 0, '7 person-held chat returns nothing');
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 0, '7 registrar_derivacion posts no alert by itself');

  -- 8. grants
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_control_abuso(uuid,integer)', 'EXECUTE')
                      AND NOT has_function_privilege('anon', 'public.cerebro_control_abuso(uuid,integer)', 'EXECUTE')
                      AND NOT has_function_privilege('authenticated', 'public.cerebro_control_abuso(uuid,integer)', 'EXECUTE'),
                      '8 grants: service_role only');
END $$;

DO $$
DECLARE v_fail int := coalesce(nullif(current_setting('t361.fail', true), ''), '0')::int;
BEGIN
  IF v_fail > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
