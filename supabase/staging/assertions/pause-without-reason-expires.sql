\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 385 (a bot pause without reason expires after pausa_humana_caduca_minutos, like agent_replied).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA385', phones 5990385xxxx. Needs 375 (cerebro_humano_atendiendo) loaded.
-- Cases:
--   1  NULL reason, paused 10 minutes ago, no human activity -> released by cerebro_caducar_pausa_humana; fact says false
--   2  NULL reason, paused 2 minutes ago -> kept; fact says true
--   3  NULL reason, old pause but a human wrote 3 minutes ago -> kept
--   4  NULL reason without ai_handoff_at: counts from the last human message (old -> released, none -> released)
--   5  agent_replied still expires after 5 minutes (unchanged)
--   6  other reasons never expire: solicitud_cliente / abuso 3 days old -> kept; fact says true
--   7  the cron sweep cerebro_caducar_pausas_humanas releases NULL-reason pauses and leaves the others
--   8  a released pause clears reason and handoff time
-- =====================================================================
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t385.fail', (coalesce(nullif(current_setting('t385.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE RAISE NOTICE 'ok   [%]', p_label; END IF;
END $f$;

CREATE FUNCTION pg_temp.fx(p_n int) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990385' || lpad(p_n::text, 4, '0'), 'PRUEBA385 ' || p_n) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $f$;
CREATE FUNCTION pg_temp.msg(p_conv uuid, p_ago interval) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action, created_at)
  VALUES (p_conv, 'agent', 'text', 'prueba385', 'sent', false, false, now() - p_ago)
$f$;
CREATE FUNCTION pg_temp.pausa(p_conv uuid, p_reason text, p_ago interval) RETURNS void LANGUAGE sql AS $f$
  UPDATE conversations SET ai_autoreply_disabled = true, ai_handoff_reason = p_reason, ai_handoff_at = now() - p_ago WHERE id = p_conv
$f$;
CREATE FUNCTION pg_temp.libera(p_conv uuid) RETURNS boolean LANGUAGE sql AS $f$
  SELECT EXISTS (SELECT 1 FROM cerebro_caducar_pausa_humana(p_conv))
$f$;
CREATE FUNCTION pg_temp.pausada(p_conv uuid) RETURNS boolean LANGUAGE sql AS $f$
  SELECT coalesce(ai_autoreply_disabled, false) FROM conversations WHERE id = p_conv
$f$;

DO $$
DECLARE
  c uuid; c2 uuid; c3 uuid; v_n int; r record;
BEGIN
  -- 1 NULL reason, 10 minutes, nothing else
  c := pg_temp.fx(1); PERFORM pg_temp.pausa(c, NULL, interval '10 minutes');
  PERFORM pg_temp.chk(cerebro_humano_atendiendo(c) IS FALSE, '1a fact: expired NULL-reason pause is not a person attending');
  PERFORM pg_temp.chk(pg_temp.libera(c), '1b NULL-reason pause 10 minutes old is released');
  PERFORM pg_temp.chk(pg_temp.pausada(c) IS FALSE, '1c conversation no longer paused');

  -- 2 NULL reason, 2 minutes
  c := pg_temp.fx(2); PERFORM pg_temp.pausa(c, NULL, interval '2 minutes');
  PERFORM pg_temp.chk(cerebro_humano_atendiendo(c) IS TRUE, '2a fact: fresh NULL-reason pause is attended');
  PERFORM pg_temp.chk(NOT pg_temp.libera(c), '2b fresh NULL-reason pause is kept');
  PERFORM pg_temp.chk(pg_temp.pausada(c), '2c still paused');

  -- 3 NULL reason, old pause, recent human message
  c := pg_temp.fx(3); PERFORM pg_temp.pausa(c, NULL, interval '1 hour'); PERFORM pg_temp.msg(c, interval '3 minutes');
  PERFORM pg_temp.chk(NOT pg_temp.libera(c), '3 old NULL-reason pause with a human message 3 minutes ago is kept');

  -- 4 NULL reason without ai_handoff_at
  c := pg_temp.fx(4); PERFORM pg_temp.pausa(c, NULL, NULL); PERFORM pg_temp.msg(c, interval '2 hours');
  PERFORM pg_temp.chk(pg_temp.libera(c), '4a no handoff time, last human message 2 hours ago -> released');
  c := pg_temp.fx(5); PERFORM pg_temp.pausa(c, NULL, NULL);
  PERFORM pg_temp.chk(pg_temp.libera(c), '4b no handoff time and no human message -> released');

  -- 5 agent_replied unchanged
  c := pg_temp.fx(6); PERFORM pg_temp.pausa(c, 'agent_replied', interval '10 minutes');
  PERFORM pg_temp.chk(pg_temp.libera(c), '5a agent_replied 10 minutes old is released');
  c := pg_temp.fx(7); PERFORM pg_temp.pausa(c, 'agent_replied', interval '2 minutes');
  PERFORM pg_temp.chk(NOT pg_temp.libera(c), '5b agent_replied 2 minutes old is kept');

  -- 6 other reasons never expire
  c := pg_temp.fx(8); PERFORM pg_temp.pausa(c, 'solicitud_cliente', interval '3 days');
  PERFORM pg_temp.chk(NOT pg_temp.libera(c), '6a solicitud_cliente 3 days old is kept');
  PERFORM pg_temp.chk(cerebro_humano_atendiendo(c) IS TRUE, '6b fact: solicitud_cliente pause is attended');
  c := pg_temp.fx(9); PERFORM pg_temp.pausa(c, 'abuso', interval '3 days');
  PERFORM pg_temp.chk(NOT pg_temp.libera(c), '6c abuso 3 days old is kept');

  -- 7 cron sweep
  c := pg_temp.fx(10); PERFORM pg_temp.pausa(c, NULL, interval '20 minutes');
  c2 := pg_temp.fx(11); PERFORM pg_temp.pausa(c2, 'solicitud_cliente', interval '20 minutes');
  c3 := pg_temp.fx(12); PERFORM pg_temp.pausa(c3, NULL, interval '1 minute');
  PERFORM cerebro_caducar_pausas_humanas();
  PERFORM pg_temp.chk(pg_temp.pausada(c) IS FALSE, '7a sweep released the old NULL-reason pause');
  PERFORM pg_temp.chk(pg_temp.pausada(c2), '7b sweep kept the solicitud_cliente pause');
  PERFORM pg_temp.chk(pg_temp.pausada(c3), '7c sweep kept the fresh NULL-reason pause');

  -- 8 a release clears reason and time
  SELECT ai_handoff_reason, ai_handoff_at INTO r FROM conversations WHERE id = c;
  PERFORM pg_temp.chk(r.ai_handoff_reason IS NULL AND r.ai_handoff_at IS NULL, '8 released pause has no reason and no handoff time');

  v_n := coalesce(nullif(current_setting('t385.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
