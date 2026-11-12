\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 367, part 2 (a Zelle account is written to a send only when the customer gave it for this send,
-- or explicitly asked for the same account as before). Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT). Synthetic fixtures only:
-- contacts 'PRUEBA367Z', phones 5990368xxxx.
-- Shape of conversation 1727ef31: a previous send closed with account A; the new send's first message "Pasame 58 zelle a la cuenta" has
-- no account, and the model still called registrar_beneficiario_zelle with A.
-- Cases:
--   1  previous send (closed yesterday, recipient A, A typed in an OLD message), open new send, message without account, call with A
--      -> refused, nothing written (0 vigente recipients)
--   2  the customer then sends account B in a later message (the batch race) -> B saved as the only recipient
--   3  the customer says "a la misma cuenta de la otra vez" -> A saved (several phrasings)
--   4  first-ever send (no closed operation) -> saved, with or without a message
--   5  a phone typed with spaces/dashes/+1 in a customer message matches the normalized 10 digits; an email matches case-insensitively
--   6  the account already vigente on the operation -> not refused ("sin cambios")
--   7  other callers (p_tool not a bot tool) are never guarded
--   8  the automatic reader (cerebro_guardar_zelle_auto) is guarded too
--   9  messages of the agent/bot do not count as the customer giving the account; a message older than the last closed send does not
-- =====================================================================
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t367z.fail', (coalesce(nullif(current_setting('t367z.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE RAISE NOTICE 'ok   [%]', p_label; END IF;
END $f$;

-- conversation with (optionally) a previous send closed p_hours ago whose Zelle recipient is p_prev, and a NEW open send
CREATE FUNCTION pg_temp.fx(p_n int, p_prev text, OUT o_conv uuid, OUT o_op uuid, OUT o_acc uuid) LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_ct uuid; v_old uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, o_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, o_acc, '5990368' || lpad(p_n::text, 4, '0'), 'PRUEBA367Z ' || p_n) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, o_acc, v_ct) RETURNING id INTO o_conv;
  IF p_prev IS NOT NULL THEN
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
    VALUES (o_acc, o_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 5000, now() - interval '3 days') RETURNING id INTO v_old;
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = 'completed', completed_at = now() - interval '24 hours' WHERE id = v_old;
    PERFORM set_config('wacrm.origin', '', true);
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
    VALUES (v_old, 'zelle', 'PRUEBA Titular Uno', p_prev, 1, 1, 'notes_parse', 'vigente');
    PERFORM pg_temp.msg(o_conv, 'customer', 'Mi zelle es ' || p_prev, interval '30 hours');
  END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (o_acc, o_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO o_op;
END $f$;

CREATE FUNCTION pg_temp.msg(p_conv uuid, p_who text, p_text text, p_ago interval) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action, created_at)
  VALUES (p_conv, p_who, 'text', p_text, 'sent', false, false, now() - p_ago)
$f$;
CREATE FUNCTION pg_temp.x() RETURNS text LANGUAGE sql AS $f$ SELECT 'x' || gen_random_uuid()::text $f$;
CREATE FUNCTION pg_temp.w(p_conv uuid, p_acct text, p_tool text DEFAULT 'registrar_beneficiario_zelle') RETURNS text LANGUAGE sql AS $f$
  SELECT accion FROM cerebro_guardar_zelle(p_conv, 'PRUEBA Titular Tres', p_acct, pg_temp.x(), NULL, p_tool) $f$;
CREATE FUNCTION pg_temp.nrec(p_op uuid) RETURNS int LANGUAGE sql AS $f$
  SELECT count(*)::int FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente' AND beneficiary_type = 'zelle' $f$;

DO $$
DECLARE
  cA constant text := 'prueba367a@example.com';
  cB constant text := 'prueba367b@example.com';
  c record; v_r text; v_n int; v_alt text; v_i int := 0;
BEGIN
  -- 1 refused: the account is only in the old send's message
  SELECT * INTO c FROM pg_temp.fx(1, cA);
  PERFORM pg_temp.msg(c.o_conv, 'customer', 'Pásame 58 zelle a la cuenta', interval '1 minute');
  v_r := pg_temp.w(c.o_conv, cA);
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%' AND v_r ILIKE '%no ha dado%' AND v_r ILIKE '%pregunta%', '1a refused: ' || coalesce(v_r, 'null'));
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_op) = 0, '1b nothing written');
  -- 2 the real account arrives in a later message
  PERFORM pg_temp.msg(c.o_conv, 'customer', 'es ' || upper(cB), interval '10 seconds');
  v_r := pg_temp.w(c.o_conv, cB);
  PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND pg_temp.nrec(c.o_op) = 1
                      AND EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = c.o_op AND status = 'vigente' AND lower(zelle_account) = cB), '2 later account saved, only recipient: ' || coalesce(v_r, 'null'));

  -- 3 explicit "same account"
  FOREACH v_alt IN ARRAY ARRAY['a la misma cuenta de la otra vez', 'la de siempre', 'igual que la vez pasada', 'la anterior porfa', 'mismo zelle', 'igual que la otra'] LOOP
    v_i := v_i + 1;
    SELECT * INTO c FROM pg_temp.fx(300 + v_i, cA);
    PERFORM pg_temp.msg(c.o_conv, 'customer', 'Pásame 58 zelle ' || v_alt, interval '1 minute');
    v_r := pg_temp.w(c.o_conv, cA);
    PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND pg_temp.nrec(c.o_op) = 1, '3 same-account phrase saved [' || v_alt || ']: ' || coalesce(v_r, 'null'));
  END LOOP;
  -- 4 first-ever send
  SELECT * INTO c FROM pg_temp.fx(4, NULL);
  PERFORM pg_temp.msg(c.o_conv, 'customer', 'quiero enviar 58 zelle', interval '1 minute');
  v_r := pg_temp.w(c.o_conv, cA);
  PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND pg_temp.nrec(c.o_op) = 1, '4a first-ever send, no account in a message: saved: ' || coalesce(v_r, 'null'));
  SELECT * INTO c FROM pg_temp.fx(41, NULL);
  PERFORM pg_temp.msg(c.o_conv, 'customer', cA, interval '1 minute');
  v_r := pg_temp.w(c.o_conv, cA);
  PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND pg_temp.nrec(c.o_op) = 1, '4b first-ever send, account typed: saved');

  -- 5 normalization
  SELECT * INTO c FROM pg_temp.fx(5, cA);
  PERFORM pg_temp.msg(c.o_conv, 'customer', 'mi numero es +1 (602) 317-3696', interval '1 minute');
  v_r := pg_temp.w(c.o_conv, '6023173696');
  PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND pg_temp.nrec(c.o_op) = 1, '5a phone with +1, spaces and dashes matches: ' || coalesce(v_r, 'null'));
  SELECT * INTO c FROM pg_temp.fx(51, cA);
  PERFORM pg_temp.msg(c.o_conv, 'customer', 'mi numero es 602 317 3696', interval '1 minute');
  v_r := pg_temp.w(c.o_conv, '+1 602-317-3696');
  PERFORM pg_temp.chk(v_r LIKE 'guardado%', '5b typed another way matches by last 10 digits: ' || coalesce(v_r, 'null'));
  SELECT * INTO c FROM pg_temp.fx(52, cA);
  PERFORM pg_temp.msg(c.o_conv, 'customer', 'mi numero es 602 317 3697', interval '1 minute');
  v_r := pg_temp.w(c.o_conv, '6023173696');
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%', '5c a different phone does not match: ' || coalesce(v_r, 'null'));

  -- 6 already vigente on the operation
  SELECT * INTO c FROM pg_temp.fx(6, cA);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (c.o_op, 'zelle', 'PRUEBA Titular Tres', cA, 1, 1, 'notes_parse', 'vigente');
  v_r := pg_temp.w(c.o_conv, cA);
  PERFORM pg_temp.chk(v_r LIKE 'sin cambios%', '6 account already on the operation is not refused: ' || coalesce(v_r, 'null'));

  -- 7 other callers
  SELECT * INTO c FROM pg_temp.fx(7, cA);
  v_r := pg_temp.w(c.o_conv, cA, 'panel_manual');
  PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND pg_temp.nrec(c.o_op) = 1, '7 non-bot caller is never guarded: ' || coalesce(v_r, 'null'));

  -- 8 the automatic reader
  SELECT * INTO c FROM pg_temp.fx(8, cA);
  SELECT accion INTO v_r FROM cerebro_guardar_zelle_auto(c.o_conv, 'PRUEBA Titular Tres', cA, pg_temp.x());
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%' AND pg_temp.nrec(c.o_op) = 0, '8 automatic reader guarded: ' || coalesce(v_r, 'null'));

  -- 9 bot/agent messages do not count; the cut is the last closed send
  SELECT * INTO c FROM pg_temp.fx(9, cA);
  PERFORM pg_temp.msg(c.o_conv, 'agent', 'tu cuenta es ' || cA, interval '1 minute');
  v_r := pg_temp.w(c.o_conv, cA);
  PERFORM pg_temp.chk(v_r LIKE 'NO SE GUARDO NADA%', '9a an agent message with the account does not count: ' || coalesce(v_r, 'null'));

  v_n := coalesce(nullif(current_setting('t367z.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
