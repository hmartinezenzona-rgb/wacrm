\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 368 (cerebro_repeticion_turno: the two facts the Decisor needs so the bot does not repeat itself).
-- Run as  BEGIN; 368; <this file>; ROLLBACK;  or with 368 applied. Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back
-- on purpose)'. RED before 368: the function does not exist. Synthetic PRUEBA fixtures. Cases:
--   1. a conversation with no messages: horario_ya_dicho_hoy false, ultimo_pedido_bot NULL;
--   2. hours line: an agent message of today (Guyana date) with "fuera de horario" or "a partir de las 9" -> true; the same text from the
--      customer, or from yesterday (Guyana date), -> false;
--   3. last ask: newest ai_generated agent message with a "?" within 6 h; texto is cut to 500 chars and hace_min is whole minutes;
--      a newer message without "?" , a human (non ai) message with "?" and anything older than 6 h are ignored;
--   4. grants: service_role only.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t368.fail', (coalesce(nullif(current_setting('t368.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900368' || p_tag, 'PRUEBA368' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.msg(p_conv uuid, p_sender text, p_ai boolean, p_text text, p_at timestamptz) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action, created_at)
  VALUES (p_conv, p_sender, 'text', p_text, 'sent', p_ai, false, p_at)
$$;

DO $$
DECLARE
  v_c uuid; r record;
  -- 00:30 Guyana today and 23:30 Guyana yesterday, as instants; "today" cases use now() when it is not too early in the Guyana day.
  v_hoy0 timestamptz := ((now() AT TIME ZONE 'America/Guyana')::date)::timestamp AT TIME ZONE 'America/Guyana';
BEGIN
  -- 1
  v_c := pg_temp.fx('1');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.horario_ya_dicho_hoy IS FALSE AND r.ultimo_pedido_bot IS NULL, '1 empty conversation');

  -- 2
  v_c := pg_temp.fx('2');
  PERFORM pg_temp.msg(v_c, 'customer', false, 'Estamos fuera de horario', now());
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.horario_ya_dicho_hoy IS FALSE, '2a customer text does not count');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Hola. Ahora mismo estamos fuera de horario.', v_hoy0 - interval '1 hour');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.horario_ya_dicho_hoy IS FALSE, '2b yesterday (Guyana date) does not count');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Queda registrado y se procesa a partir de las 9:00am.', v_hoy0 + interval '1 minute');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.horario_ya_dicho_hoy IS TRUE, '2c "a partir de las 9" today counts');
  v_c := pg_temp.fx('3');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Estamos Fuera de Horario, le atendemos igual.', v_hoy0 + interval '1 minute');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.horario_ya_dicho_hoy IS TRUE, '2d "fuera de horario" today counts, case-insensitive');

  -- 3
  v_c := pg_temp.fx('4');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Me pasa la tarjeta vieja?', now() - interval '5 hours');
  PERFORM pg_temp.msg(v_c, 'agent', true, left(repeat('x', 600), 600) || '?', now() - interval '10 minutes 20 seconds');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Perfecto, queda anotado.', now() - interval '5 minutes');
  PERFORM pg_temp.msg(v_c, 'agent', false, 'Humano: me pasa el celular?', now() - interval '2 minutes');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk((r.ultimo_pedido_bot->>'hace_min')::int = 10, '3a newest ai message with a question, whole minutes');
  PERFORM pg_temp.chk(length(r.ultimo_pedido_bot->>'texto') = 500, '3b texto cut to 500');
  v_c := pg_temp.fx('5');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Me pasa la tarjeta?', now() - interval '7 hours');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.ultimo_pedido_bot IS NULL, '3c older than 6 h is NULL');
  PERFORM pg_temp.msg(v_c, 'agent', true, 'Me pasa la tarjeta?', now() - interval '3 minutes');
  SELECT * INTO r FROM cerebro_repeticion_turno(v_c);
  PERFORM pg_temp.chk(r.ultimo_pedido_bot->>'texto' = 'Me pasa la tarjeta?' AND (r.ultimo_pedido_bot->>'hace_min')::int = 3, '3d shape {texto, hace_min}');

  -- 4
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_repeticion_turno(uuid)', 'EXECUTE')
                      AND NOT has_function_privilege('anon', 'public.cerebro_repeticion_turno(uuid)', 'EXECUTE')
                      AND NOT has_function_privilege('authenticated', 'public.cerebro_repeticion_turno(uuid)', 'EXECUTE'),
                      '4 grants: service_role only');
END $$;

DO $$
DECLARE v_fail int := coalesce(nullif(current_setting('t368.fail', true), ''), '0')::int;
BEGIN
  IF v_fail > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
