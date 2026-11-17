\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 375 (cerebro_humano_atendiendo: is a person of the team attending this chat right now?).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA375', phones 5990375xxxx.
-- Same definition the Decisor uses (node "Contexto conversacion"), but READ-ONLY: the Decisor's query releases expired pauses and
-- assignments as a side effect; this function must leave the conversation untouched.
-- Cases:
--   1  a human message 2 minutes ago -> true; 6 minutes ago -> false
--   2  messages that are not a person attending: the bot/notifier (ai_generated), a panel action, the customer -> false
--   3  a human message from before the chat was handed back to the bot (ai_resumed_at) -> false
--   4  a pause left by a panel reply (agent_replied): alive while the last human activity is under 5 minutes old, expired after; an
--      expired pause is NOT released by the function
--   5  any other pause (customer asked for a person, abuse) never expires; not paused -> false
--   6  an assignment: alive under 10 minutes of human activity (assigned_at or last human message), expired after; the bot's own
--      derivation profile never expires
--   7  nothing at all, an unknown conversation and NULL -> false
-- =====================================================================
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t375.fail', (coalesce(nullif(current_setting('t375.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE RAISE NOTICE 'ok   [%]', p_label; END IF;
END $f$;

CREATE FUNCTION pg_temp.fx(p_n int) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990375' || lpad(p_n::text, 4, '0'), 'PRUEBA375 ' || p_n) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $f$;
CREATE FUNCTION pg_temp.msg(p_conv uuid, p_who text, p_ago interval, p_ai boolean DEFAULT false, p_panel boolean DEFAULT false) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action, created_at)
  VALUES (p_conv, p_who, 'text', 'prueba375', 'sent', p_ai, p_panel, now() - p_ago)
$f$;
CREATE FUNCTION pg_temp.atiende(p_conv uuid) RETURNS boolean LANGUAGE sql AS $f$ SELECT cerebro_humano_atendiendo(p_conv) $f$;

DO $$
DECLARE
  c uuid; v_n int; v_pausa boolean;
  v_bot constant uuid := '377b0c8c-c025-46ff-8088-7a929080831e';
  v_ag  constant uuid := gen_random_uuid();
BEGIN
  -- 1 recent human message
  c := pg_temp.fx(1); PERFORM pg_temp.msg(c, 'agent', interval '2 minutes');
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '1a human message 2 minutes ago');
  c := pg_temp.fx(2); PERFORM pg_temp.msg(c, 'agent', interval '6 minutes');
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '1b human message 6 minutes ago');

  -- 2 messages that are not a person attending
  c := pg_temp.fx(3); PERFORM pg_temp.msg(c, 'agent', interval '1 minute', true, false);
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '2a bot / notifier message (ai_generated)');
  c := pg_temp.fx(4); PERFORM pg_temp.msg(c, 'agent', interval '1 minute', false, true);
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '2b panel action');
  c := pg_temp.fx(5); PERFORM pg_temp.msg(c, 'customer', interval '1 minute');
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '2c customer message');

  -- 3 handed back to the bot after the human message
  c := pg_temp.fx(6); PERFORM pg_temp.msg(c, 'agent', interval '2 minutes');
  UPDATE conversations SET ai_resumed_at = now() - interval '1 minute' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '3a human message before the hand-back to the bot');
  c := pg_temp.fx(7); PERFORM pg_temp.msg(c, 'agent', interval '1 minute');
  UPDATE conversations SET ai_resumed_at = now() - interval '3 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '3b human message after the hand-back');

  -- 4 pause left by a panel reply
  c := pg_temp.fx(8);
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '2 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '4a agent_replied pause, 2 minutes old');
  c := pg_temp.fx(9);
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '10 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '4b agent_replied pause, 10 minutes old and no human activity');
  SELECT ai_autoreply_disabled INTO v_pausa FROM conversations WHERE id = c;
  PERFORM pg_temp.chk(v_pausa IS TRUE, '4c read-only: the expired pause was NOT released');
  c := pg_temp.fx(10); PERFORM pg_temp.msg(c, 'agent', interval '3 minutes');
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'agent_replied', ai_handoff_at = now() - interval '10 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '4d old pause but a human wrote 3 minutes ago');

  -- 5 other pauses never expire
  c := pg_temp.fx(11);
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '3 days' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '5a pause because the customer asked for a person, 3 days old');
  c := pg_temp.fx(12);
  UPDATE conversations SET ai_autoreply_disabled = false, ai_handoff_reason = 'solicitud_cliente', ai_handoff_at = now() - interval '1 minute' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '5b not paused (reason left over)');

  -- 6 assignment (a BEFORE trigger sets assigned_at = now() whenever assigned_agent_id changes, so the date goes in a second UPDATE)
  c := pg_temp.fx(13);
  UPDATE conversations SET assigned_agent_id = v_ag WHERE id = c;
  UPDATE conversations SET assigned_at = now() - interval '3 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '6a assigned 3 minutes ago');
  c := pg_temp.fx(14);
  UPDATE conversations SET assigned_agent_id = v_ag WHERE id = c;
  UPDATE conversations SET assigned_at = now() - interval '30 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '6b assigned 30 minutes ago, no human activity');
  SELECT assigned_agent_id IS NOT NULL INTO v_pausa FROM conversations WHERE id = c;
  PERFORM pg_temp.chk(v_pausa IS TRUE, '6c read-only: the expired assignment was NOT released');
  c := pg_temp.fx(15); PERFORM pg_temp.msg(c, 'agent', interval '7 minutes');
  UPDATE conversations SET assigned_agent_id = v_ag WHERE id = c;
  UPDATE conversations SET assigned_at = now() - interval '30 minutes' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '6d old assignment but human activity 7 minutes ago');
  c := pg_temp.fx(16);
  UPDATE conversations SET assigned_agent_id = v_bot WHERE id = c;
  UPDATE conversations SET assigned_at = now() - interval '3 days' WHERE id = c;
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS TRUE, '6e bot derivation profile never expires');

  -- 7 nothing / unknown / NULL
  c := pg_temp.fx(17);
  PERFORM pg_temp.chk(pg_temp.atiende(c) IS FALSE, '7a nothing at all');
  PERFORM pg_temp.chk(pg_temp.atiende(gen_random_uuid()) IS FALSE, '7b unknown conversation');
  PERFORM pg_temp.chk(pg_temp.atiende(NULL) IS FALSE, '7c NULL');

  v_n := coalesce(nullif(current_setting('t375.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
