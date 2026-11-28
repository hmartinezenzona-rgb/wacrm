\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 363 (cerebro_control_bucle: the closed-question loop hands the chat off once, alerts once). Run as
--   BEGIN; 363; <this file>; ROLLBACK;  or with 363 applied. Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- RED before 363: the function does not exist and the first expectation fails.
-- Alerts are counted in net.http_request_queue (rolled back with the transaction, so nothing is ever sent).
-- Synthetic PRUEBA fixtures. Cases:
--   1. a loop seen on four consecutive passes with nobody holding the chat: the first pass hands off and alerts once, later passes are silent;
--   2. the BUCLE payload keeps type, cliente_phone, eventos, preguntas_repetidas;
--   3. a chat the bot already holds for abuso stays silent and keeps its reason; a person-held chat is untouched;
--   4. no loop (en_bucle false) does nothing; abuse limit exceeded (excede true) does nothing here (the limit decides);
--   5. the team unassigns / re-enables the chat, then a new loop alerts again (second alert), then silent again;
--   6. a chat held by the bot for another reason is re-labelled bucle once and alerts once;
--   7. cerebro_registrar_derivacion and cerebro_control_abuso are not changed by 363;
--   8. grants: service_role only.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t363.fail', (coalesce(nullif(current_setting('t363.fail', true), ''), '0')::int + 1)::text, true);
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
  o_phone := '59900363' || p_tag;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, o_phone, 'PRUEBA363' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.alerts(p_phone text) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM net.http_request_queue q WHERE convert_from(q.body, 'UTF8') LIKE '%' || p_phone || '%'
$$;

CREATE OR REPLACE FUNCTION pg_temp.st(p_conv uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(c.ai_autoreply_disabled::text, '_') || '/' || coalesce(c.ai_handoff_reason, '_') || '/' ||
         CASE WHEN c.assigned_agent_id IS NULL THEN 'none'
              WHEN c.assigned_agent_id = '377b0c8c-c025-46ff-8088-7a929080831e' THEN 'bot' ELSE 'person' END
    FROM conversations c WHERE c.id = p_conv
$$;

-- one pass as the node makes it: loop seen (4 repeated questions), abuse limit not exceeded, 7 events in the hour
CREATE OR REPLACE FUNCTION pg_temp.pass(p_conv uuid, p_en_bucle boolean DEFAULT true, p_excede boolean DEFAULT false) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text;
BEGIN
  EXECUTE format('SELECT cerebro_control_bucle(%L::uuid, %L::boolean, 4, %L::boolean, 7)::text', p_conv, p_en_bucle, p_excede) INTO v;
  RETURN v;
END $$;

DO $$
DECLARE
  v_person uuid; v_conv uuid; v_phone text; v_r text; v_i int; v_n int; v_body jsonb;
BEGIN
  PERFORM pg_temp.chk(to_regprocedure('public.cerebro_control_bucle(uuid,boolean,integer,boolean,integer)') IS NOT NULL, '0 cerebro_control_bucle exists');
  IF to_regprocedure('public.cerebro_control_bucle(uuid,boolean,integer,boolean,integer)') IS NULL THEN
    RAISE EXCEPTION '% expectation(s) failed (function missing)', coalesce(nullif(current_setting('t363.fail', true), ''), '0');
  END IF;
  SELECT p.user_id INTO v_person FROM profiles p WHERE p.user_id <> '377b0c8c-c025-46ff-8088-7a929080831e' ORDER BY p.user_id LIMIT 1;

  -- 1. a loop on consecutive passes, nobody holding the chat
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('01');
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 0, '1 no alert before the first pass');
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'true', '1 first pass hands off now: ' || v_r);
  PERFORM pg_temp.chk(pg_temp.st(v_conv) = 'true/bucle/bot', '1 chat held by the bot for bucle: ' || pg_temp.st(v_conv));
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 1, '1 exactly one alert after the first pass');
  FOR v_i IN 1..3 LOOP
    v_r := pg_temp.pass(v_conv);
    PERFORM pg_temp.chk(v_r = 'false', '1 repeated pass ' || v_i || ' is silent: ' || v_r);
  END LOOP;
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 1, '1 still exactly one alert after four passes');
  PERFORM pg_temp.chk(pg_temp.st(v_conv) = 'true/bucle/bot', '1 state unchanged by the silent passes');

  -- 2. payload
  SELECT convert_from(q.body, 'UTF8')::jsonb INTO v_body FROM net.http_request_queue q WHERE convert_from(q.body, 'UTF8') LIKE '%' || v_phone || '%';
  PERFORM pg_temp.chk(v_body ->> 'type' = 'BUCLE' AND v_body ->> 'cliente_phone' = v_phone AND (v_body ->> 'eventos')::int = 7
                      AND (v_body ->> 'preguntas_repetidas')::int = 4, '2 payload keeps type, cliente_phone, eventos, preguntas_repetidas');

  -- 3. held by the bot for abuso: silent, reason kept; held by a person: untouched
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('02');
  PERFORM cerebro_registrar_derivacion(v_conv, 'x', 'abuso', true);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'false' AND pg_temp.st(v_conv) = 'true/abuso/bot' AND pg_temp.alerts(v_phone) = 0,
                      '3 abuso-held chat: silent, reason stays abuso, no alert: ' || v_r);
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('03');
  UPDATE conversations SET assigned_agent_id = v_person WHERE id = v_conv;
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'false' AND pg_temp.st(v_conv) = 'false/_/person' AND pg_temp.alerts(v_phone) = 0,
                      '3 person-held chat is not taken over, no alert: ' || v_r);

  -- 4. no loop, or the abuse limit decides
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('04');
  v_r := pg_temp.pass(v_conv, false);
  PERFORM pg_temp.chk(v_r = 'false' AND pg_temp.st(v_conv) = 'false/_/none' AND pg_temp.alerts(v_phone) = 0, '4 no loop: nothing happens: ' || v_r);
  v_r := pg_temp.pass(v_conv, true, true);
  PERFORM pg_temp.chk(v_r = 'false' AND pg_temp.st(v_conv) = 'false/_/none' AND pg_temp.alerts(v_phone) = 0, '4 abuse limit exceeded: this function does nothing: ' || v_r);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'true' AND pg_temp.alerts(v_phone) = 1, '4 the loop then hands off once: ' || v_r);

  -- 5. the team unassigns / re-enables, then a new loop alerts again
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('05');
  PERFORM pg_temp.pass(v_conv);
  PERFORM pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(pg_temp.alerts(v_phone) = 1, '5 one alert for the first loop');
  UPDATE conversations SET assigned_agent_id = NULL, ai_autoreply_disabled = false, ai_handoff_reason = NULL, ai_handoff_summary = NULL,
                           ai_handoff_at = NULL WHERE id = v_conv;
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'true' AND pg_temp.st(v_conv) = 'true/bucle/bot' AND pg_temp.alerts(v_phone) = 2, '5 after re-enabling a new loop hands off and alerts again: ' || v_r);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'false' AND pg_temp.alerts(v_phone) = 2, '5 then silent again: ' || v_r);

  -- 6. held by the bot for another reason: re-labelled bucle once, alert once
  SELECT * INTO v_conv, v_phone FROM pg_temp.fx('06');
  PERFORM cerebro_registrar_derivacion(v_conv, 'x', 'manual', true);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'true' AND pg_temp.st(v_conv) = 'true/bucle/bot' AND pg_temp.alerts(v_phone) = 1, '6 other-reason chat becomes bucle with one alert: ' || v_r);
  v_r := pg_temp.pass(v_conv);
  PERFORM pg_temp.chk(v_r = 'false' AND pg_temp.alerts(v_phone) = 1, '6 then silent: ' || v_r);

  -- 7. neighbours unchanged
  PERFORM pg_temp.chk(md5(pg_get_functiondef('public.cerebro_registrar_derivacion(uuid,text,text,boolean)'::regprocedure)) = '62fc4ddf6fddd4e13cafe98e292d710d',
                      '7 cerebro_registrar_derivacion unchanged');
  PERFORM pg_temp.chk(md5(pg_get_functiondef('public.cerebro_control_abuso(uuid,integer)'::regprocedure)) = 'b8ccdeb8385c7171da20ac08ab3b773b',
                      '7 cerebro_control_abuso unchanged');

  -- 8. grants
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_control_bucle(uuid,boolean,integer,boolean,integer)', 'EXECUTE')
                      AND NOT has_function_privilege('anon', 'public.cerebro_control_bucle(uuid,boolean,integer,boolean,integer)', 'EXECUTE')
                      AND NOT has_function_privilege('authenticated', 'public.cerebro_control_bucle(uuid,boolean,integer,boolean,integer)', 'EXECUTE'),
                      '8 grants: service_role only');
END $$;

DO $$
DECLARE v_fail int := coalesce(nullif(current_setting('t363.fail', true), ''), '0')::int;
BEGIN
  IF v_fail > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
