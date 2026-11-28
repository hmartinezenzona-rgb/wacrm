\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 364 ("not business" chats + one stuck-chat alert per customer message).
-- Run as  BEGIN; 364; <this file>; ROLLBACK;  or with 364 applied. Self-reverting: ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. RED before 364: crm_marcar_no_negocio does not exist.
-- Synthetic PRUEBA fixtures; the detection loop is called through _cerebro_atascados_detectar so the test also
-- runs outside business hours. Cases:
--   1  objects exist; grants (authenticated runs the RPC, anon does not; the detector is service_role only);
--   2  bot-derived chat (assignment never expires) with a customer message 2 h old alerts once per profile; a second pass is silent;
--   3  the alert is read: the next passes do not re-create it (the 323 six-hour re-insert is gone);
--   4  a new customer message re-arms it: one new alert per profile;
--   5  person-assigned chat (the other real shape) alerts once and stays silent on the repeat;
--   6  RPC: a team member marks a chat not business (who/when stored, its unread alerts are deleted); the chat stays silent;
--   7  the customer writes again: the mark clears by itself and the chat alerts again; an agent message does not clear it;
--   8  RPC clear (false) removes the mark; a stranger and an unauthenticated caller get 42501; unknown chat gets P0002;
--   9  cutoff (chat_atascado_max_dias default 2): a customer message 3 days old never alerts, 1 day old does;
--   10 courtesy last message ("gracias") still does not alert;
--   11 money alerts do not look at the flag (no money emitter mentions not_business);
--   12 hiding a chat (deleted_at NULL -> value): its unread chat_atascado rows are deleted for every profile, read rows and
--      other types stay, un-hiding without a new customer message does not re-alert, a new customer message re-arms;
--   13 marking not business (RPC) deletes the unread chat_atascado rows too, keeps read rows and other types, and a new
--      customer message re-arms.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t364.fail', (coalesce(nullif(current_setting('t364.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, p_assignee uuid) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM profiles p JOIN auth.users au ON au.id = p.user_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900364' || p_tag, 'PRUEBA364' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id, status, assigned_agent_id)
  VALUES (v_user, v_acc, v_ct, 'open', p_assignee) RETURNING id INTO v_conv;
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.msg(p_conv uuid, p_sender text, p_text text, p_ago interval) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, created_at)
  VALUES (p_conv, p_sender, 'text', p_text, 'sent', now() - p_ago)
$$;

CREATE OR REPLACE FUNCTION pg_temp.rows(p_conv uuid, p_unread boolean DEFAULT false) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM notifications WHERE type = 'chat_atascado' AND conversation_id = p_conv
     AND (NOT p_unread OR read_at IS NULL)
$$;

CREATE OR REPLACE FUNCTION pg_temp.pass() RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM atascados FROM _cerebro_atascados_detectar(15); END $$;

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_user uuid) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims',
    CASE WHEN p_user IS NULL THEN '' ELSE json_build_object('sub', p_user, 'role', 'authenticated')::text END, true);
END $$;

DO $$
DECLARE
  v_bot constant uuid := '377b0c8c-c025-46ff-8088-7a929080831e';
  v_person uuid; v_stranger uuid; v_acc uuid; v_np int;
  v_a uuid; v_b uuid; v_c uuid; v_d uuid; v_e uuid; v_f uuid; v_g uuid; v_h uuid; v_i uuid; v_j uuid; v_u uuid; v_n int;
  v_state text; v_err text; v_r jsonb;
BEGIN
  PERFORM pg_temp.chk(to_regprocedure('public.crm_marcar_no_negocio(uuid,boolean)') IS NOT NULL, '1 crm_marcar_no_negocio exists');
  IF to_regprocedure('public.crm_marcar_no_negocio(uuid,boolean)') IS NULL THEN
    RAISE EXCEPTION '% expectation(s) failed (migration 364 missing)', coalesce(nullif(current_setting('t364.fail', true), ''), '0');
  END IF;
  PERFORM pg_temp.chk(has_function_privilege('authenticated', 'public.crm_marcar_no_negocio(uuid,boolean)', 'EXECUTE'), '1 authenticated runs the RPC');
  PERFORM pg_temp.chk(NOT has_function_privilege('anon', 'public.crm_marcar_no_negocio(uuid,boolean)', 'EXECUTE'), '1 anon does not');
  PERFORM pg_temp.chk(NOT has_function_privilege('authenticated', 'public._cerebro_atascados_detectar(integer)', 'EXECUTE'), '1 detector is not for authenticated');
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public._cerebro_atascados_detectar(integer)', 'EXECUTE'), '1 detector runs as service_role');

  SELECT p.user_id, p.account_id INTO v_person, v_acc FROM profiles p JOIN auth.users au ON au.id = p.user_id
   WHERE p.user_id <> v_bot ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT count(*) INTO v_np FROM profiles p WHERE p.account_id = v_acc AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
  SELECT au.id INTO v_stranger FROM auth.users au WHERE NOT EXISTS (SELECT 1 FROM profiles p WHERE p.user_id = au.id AND p.account_id = v_acc) LIMIT 1;

  -- 2 + 3 + 4: bot-derived chat
  v_a := pg_temp.fx('01', v_bot);
  PERFORM pg_temp.msg(v_a, 'customer', 'necesito enviar dinero a Cuba hoy', interval '2 hours');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_a) = v_np AND v_np > 0, '2 bot chat: one alert per profile (' || pg_temp.rows(v_a) || '/' || v_np || ')');
  PERFORM pg_temp.pass(); PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_a) = v_np, '2 repeat passes add nothing');
  UPDATE notifications SET read_at = now() WHERE type = 'chat_atascado' AND conversation_id = v_a;
  PERFORM pg_temp.pass(); PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_a) = v_np AND pg_temp.rows(v_a, true) = 0, '3 read alert is not re-created');
  PERFORM pg_temp.msg(v_a, 'customer', 'hola?? alguien me atiende', interval '30 minutes');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_a) = 2 * v_np AND pg_temp.rows(v_a, true) = v_np, '4 new customer message re-arms: one new alert per profile');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_a) = 2 * v_np, '4 and only one');

  -- 5: person-assigned chat
  v_b := pg_temp.fx('02', v_person);
  PERFORM pg_temp.msg(v_b, 'customer', 'ya hice la transferencia, cuando llega', interval '1 hour');
  PERFORM pg_temp.pass(); PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_b) = v_np AND v_np > 0, '5 person chat alerts once per profile');

  -- 6: mark not business
  v_c := pg_temp.fx('03', v_bot);
  PERFORM pg_temp.msg(v_c, 'customer', 'vendo cartuchos de tinta baratos', interval '2 hours');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_c, true) = v_np, '6 spam chat alerts first');
  PERFORM pg_temp.as_user(v_person);
  v_r := crm_marcar_no_negocio(v_c, true);
  PERFORM pg_temp.as_user(NULL);
  PERFORM pg_temp.chk((v_r ->> 'no_negocio')::boolean AND (v_r ->> 'not_business_by')::uuid = v_person, '6 RPC returns the mark and who');
  PERFORM pg_temp.chk((SELECT not_business_at IS NOT NULL AND not_business_by = v_person FROM conversations WHERE id = v_c), '6 who/when stored');
  PERFORM pg_temp.chk(pg_temp.rows(v_c, true) = 0, '6 its unread alerts are gone');
  UPDATE notifications SET read_at = NULL WHERE conversation_id = v_c AND type = 'chat_atascado';
  DELETE FROM notifications WHERE conversation_id = v_c AND type = 'chat_atascado';
  DELETE FROM chat_atascado_avisos WHERE conversation_id = v_c;
  PERFORM pg_temp.pass(); PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_c) = 0, '6 marked chat stays silent even without alert memory');

  -- 7: the customer writes again
  PERFORM pg_temp.msg(v_c, 'agent', 'no vendemos eso', interval '25 minutes');
  PERFORM pg_temp.chk((SELECT not_business_at IS NOT NULL FROM conversations WHERE id = v_c), '7 an agent message does not clear the mark');
  PERFORM pg_temp.msg(v_c, 'customer', 'y ahora quiero enviar remesa', interval '20 minutes');
  PERFORM pg_temp.chk((SELECT not_business_at IS NULL AND not_business_by IS NULL FROM conversations WHERE id = v_c), '7 a customer message clears the mark');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_c, true) = v_np, '7 and the chat alerts again');

  -- 8: clear by RPC, authorization
  PERFORM pg_temp.as_user(v_person);
  PERFORM crm_marcar_no_negocio(v_c, true);
  v_r := crm_marcar_no_negocio(v_c, false);
  PERFORM pg_temp.chk(NOT (v_r ->> 'no_negocio')::boolean AND (SELECT not_business_at IS NULL FROM conversations WHERE id = v_c), '8 RPC clear removes the mark');
  IF v_stranger IS NOT NULL THEN
    PERFORM pg_temp.as_user(v_stranger);
    BEGIN PERFORM crm_marcar_no_negocio(v_c, true); v_err := 'no error';
    EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE; END;
    PERFORM pg_temp.chk(v_err = '42501', '8 stranger is refused (' || v_err || ')');
  END IF;
  PERFORM pg_temp.as_user(NULL);
  BEGIN PERFORM crm_marcar_no_negocio(v_c, true); v_err := 'no error';
  EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE; END;
  PERFORM pg_temp.chk(v_err = '42501', '8 unauthenticated is refused (' || v_err || ')');
  PERFORM pg_temp.as_user(v_person);
  BEGIN PERFORM crm_marcar_no_negocio(gen_random_uuid(), true); v_err := 'no error';
  EXCEPTION WHEN OTHERS THEN v_err := SQLSTATE; END;
  PERFORM pg_temp.as_user(NULL);
  PERFORM pg_temp.chk(v_err = 'P0002', '8 unknown chat is P0002 (' || v_err || ')');

  -- 9: cutoff
  v_d := pg_temp.fx('04', v_bot);
  PERFORM pg_temp.msg(v_d, 'customer', 'mensaje viejo de hace 3 dias', interval '3 days');
  v_e := pg_temp.fx('05', v_bot);
  PERFORM pg_temp.msg(v_e, 'customer', 'mensaje de hace 1 dia', interval '1 day');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_d) = 0, '9 3-day-old message does not alert');
  PERFORM pg_temp.chk(pg_temp.rows(v_e) = v_np, '9 1-day-old message alerts');

  -- 10: courtesy
  v_f := pg_temp.fx('06', v_bot);
  PERFORM pg_temp.msg(v_f, 'customer', 'gracias', interval '2 hours');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_f) = 0, '10 courtesy last message does not alert');

  -- 11: money emitters do not look at the flag
  PERFORM pg_temp.chk(NOT EXISTS (SELECT 1 FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
      AND p.proname IN ('cerebro_avisar_envios_sin_beneficiario', 'cerebro_avisar_envios_incompletos')
      AND p.prosrc ILIKE '%not_business%'), '11 money alert emitters ignore the flag');

  -- 12: hiding the chat (the panel sets deleted_at)
  v_g := pg_temp.fx('07', v_bot);
  PERFORM pg_temp.msg(v_g, 'customer', 'necesito enviar dinero, me atienden?', interval '2 hours');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_g, true) = v_np AND v_np > 0, '12 chat alerts first (' || pg_temp.rows(v_g, true) || '/' || v_np || ')');
  SELECT user_id INTO v_u FROM notifications WHERE type = 'chat_atascado' AND conversation_id = v_g LIMIT 1;
  -- a second chat whose row for v_u was already read (read rows may stay)
  v_i := pg_temp.fx('09', v_bot);
  PERFORM pg_temp.msg(v_i, 'customer', 'otra consulta de envio', interval '2 hours');
  PERFORM pg_temp.pass();
  UPDATE notifications SET read_at = now() WHERE type = 'chat_atascado' AND conversation_id = v_i AND user_id = v_u;
  v_n := pg_temp.rows(v_i) - pg_temp.rows(v_i, true);
  INSERT INTO notifications (account_id, user_id, type, conversation_id, title, body)
  VALUES (v_acc, v_u, 'deal_incidencia', v_g, 'PRUEBA364 money alert', 'must stay');
  UPDATE conversations SET deleted_at = now() WHERE id = v_g;
  UPDATE conversations SET deleted_at = now() WHERE id = v_i;
  PERFORM pg_temp.chk(pg_temp.rows(v_g) = 0, '12 hide deletes the pending chat_atascado rows for every profile');
  PERFORM pg_temp.chk(pg_temp.rows(v_i) = v_n AND v_n = 1 AND pg_temp.rows(v_i, true) = 0, '12 hide keeps the read row and deletes the unread ones');
  PERFORM pg_temp.chk((SELECT count(*) FROM notifications WHERE type = 'deal_incidencia' AND conversation_id = v_g) = 1, '12 other types stay');
  PERFORM pg_temp.chk((SELECT message_id FROM chat_atascado_avisos WHERE conversation_id = v_g)
      = (SELECT id FROM messages WHERE conversation_id = v_g AND sender_type = 'customer' ORDER BY created_at DESC LIMIT 1),
      '12 alert state is closed for the last customer message');
  UPDATE conversations SET deleted_at = NULL WHERE id = v_g;
  PERFORM pg_temp.pass(); PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_g) = 0, '12 un-hiding without a new customer message does not re-alert');
  PERFORM pg_temp.msg(v_g, 'customer', 'sigo esperando', interval '20 minutes');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_g, true) = v_np, '12 a new customer message re-arms (' || pg_temp.rows(v_g, true) || '/' || v_np || ')');

  -- 13: marking not business
  v_h := pg_temp.fx('08', v_bot);
  PERFORM pg_temp.msg(v_h, 'customer', 'quiero cambiar dolares, hay alguien?', interval '2 hours');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_h, true) = v_np, '13 chat alerts first');
  v_j := pg_temp.fx('10', v_bot);
  PERFORM pg_temp.msg(v_j, 'customer', 'consulta de cambio', interval '2 hours');
  PERFORM pg_temp.pass();
  UPDATE notifications SET read_at = now() WHERE type = 'chat_atascado' AND conversation_id = v_j AND user_id = v_u;
  INSERT INTO notifications (account_id, user_id, type, conversation_id, title, body)
  VALUES (v_acc, v_u, 'deal_incidencia', v_h, 'PRUEBA364 money alert', 'must stay');
  PERFORM pg_temp.as_user(v_person);
  PERFORM crm_marcar_no_negocio(v_h, true);
  PERFORM crm_marcar_no_negocio(v_j, true);
  PERFORM pg_temp.as_user(NULL);
  PERFORM pg_temp.chk(pg_temp.rows(v_h) = 0, '13 not business deletes the pending chat_atascado rows');
  PERFORM pg_temp.chk(pg_temp.rows(v_j) = 1 AND pg_temp.rows(v_j, true) = 0, '13 the read row stays, unread ones go');
  PERFORM pg_temp.chk((SELECT count(*) FROM notifications WHERE type = 'deal_incidencia' AND conversation_id = v_h) = 1, '13 other types stay');
  PERFORM pg_temp.pass(); PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_h, true) = 0, '13 stays silent');
  PERFORM pg_temp.msg(v_h, 'customer', 'hola otra vez', interval '20 minutes');
  PERFORM pg_temp.pass();
  PERFORM pg_temp.chk(pg_temp.rows(v_h, true) = v_np, '13 a new customer message re-arms');

  IF coalesce(nullif(current_setting('t364.fail', true), ''), '0')::int > 0 THEN
    RAISE EXCEPTION '% expectation(s) failed', current_setting('t364.fail', true);
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
