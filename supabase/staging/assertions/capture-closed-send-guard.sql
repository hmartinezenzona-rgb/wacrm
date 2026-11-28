\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 390 (the beneficiary writer never opens an operation for a closed send's data, nor while the bot is paused).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only (contacts 'PRUEBA390', phones 59900390xx).
-- Shape of the production case (2026-11-24): a Zelle number correction for a send completed ~53 h earlier opened a remesa that
-- absorbed an unrelated deposit later.
-- Cases:
--   1  rule A is window-free: a zelle / card / phone / reparto write that matches a recipient of a send completed 53 h ago, nothing open,
--      opens nothing; a cancelled send counts as closed too
--   2  a genuinely new recipient after a send completed 53 h ago (not paused, nothing open) still opens a send
--   3  an explicit new-send intent (declared service) newer than the old close lets the same recipient open
--   4  inside the window: correction refused (rule A), new recipient without signal refused (rule B), as before
--   5  paused conversation (ai_autoreply_disabled): nothing open -> no op opens, with or without a closed send; the reply says capture mode
--   6  paused + an open remesa: the data still lands on it; paused + an open visa: the writer refuses to open a remesa next to it
--   7  not paused and no history at all: the first send still opens (account first, deposit later)
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t390.fail', (coalesce(nullif(current_setting('t390.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE
    RAISE NOTICE 'ok   [%]', p_label;
  END IF;
END $$;

-- A synthetic conversation, optionally with one operation already completed p_hours ago whose recipient is a Zelle account,
-- a card and a phone (the "send that just ended").
CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, p_hours numeric, OUT o_conv uuid, OUT o_done uuid) LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900390' || p_tag, 'PRUEBA390' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
  IF p_hours IS NOT NULL THEN
    -- an automation cannot complete an operation (the trigger suppresses it): insert open, complete as the admin origin
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
    VALUES (v_acc, o_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 5000, now() - make_interval(hours => p_hours::int + 1))
    RETURNING id INTO o_done;
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = 'completed', completed_at = now() - make_interval(secs => p_hours * 3600) WHERE id = o_done;
    PERFORM set_config('wacrm.origin', '', true);
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
    VALUES (o_done, 'zelle', 'PRUEBA Titular Uno', 'prueba390done@example.com', 1, 1, 'notes_parse', 'vigente');
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, block_index, source, status)
    VALUES (o_done, 'cuban_card', 'PRUEBA Titular Dos', '9238123432101987', '53821201', 1, 2, 'notes_parse', 'vigente');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.nops(p_conv uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv
$$;
CREATE OR REPLACE FUNCTION pg_temp.naudit(p_conv uuid) RETURNS int LANGUAGE sql AS $$
  SELECT count(*)::int FROM remittance_admin_audit a JOIN remittance_operations o ON o.id = a.row_id
   WHERE o.conversation_id = p_conv AND a.action = 'agent_service_change' AND a.reason LIKE 'recipient write opened%'
$$;
CREATE OR REPLACE FUNCTION pg_temp.x() RETURNS text LANGUAGE sql AS $$ SELECT 'x' || gen_random_uuid()::text $$;

-- The four writers, with the given recipient data.
-- (367) the customer types the account in a message before the bot's tool writes it (the Zelle history guard refuses an account that
-- is not in a customer message written after the last closed send)
CREATE OR REPLACE FUNCTION pg_temp.typed(p_conv uuid, p_acct text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action)
  VALUES (p_conv, 'customer', 'text', 'mi zelle es ' || coalesce(p_acct, ''), 'sent', false, false) $$;
CREATE OR REPLACE FUNCTION pg_temp.w_zelle(p_conv uuid, p_acct text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_r text;
BEGIN
  PERFORM pg_temp.typed(p_conv, p_acct);
  SELECT accion INTO v_r FROM cerebro_guardar_zelle(p_conv, 'PRUEBA Titular Tres', p_acct, pg_temp.x());
  RETURN v_r;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.w_auto(p_conv uuid, p_acct text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_r text;
BEGIN
  PERFORM pg_temp.typed(p_conv, p_acct);
  SELECT accion INTO v_r FROM cerebro_guardar_zelle_auto(p_conv, 'PRUEBA Titular Tres', p_acct, pg_temp.x());
  RETURN v_r;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.w_card(p_conv uuid, p_card text, p_phone text) RETURNS text LANGUAGE sql AS $$
  SELECT accion FROM cerebro_guardar_beneficiario(p_conv, 'PRUEBA Titular Cuatro', p_card, p_phone, pg_temp.x()) $$;
CREATE OR REPLACE FUNCTION pg_temp.w_rep(p_conv uuid, p_c1 text, p_c2 text) RETURNS text LANGUAGE sql AS $$
  SELECT accion FROM cerebro_guardar_reparto(p_conv, p_c1, '53821301', '20000 CUP', p_c2, '53821302', '20000 CUP', '', '', '', pg_temp.x()) $$;


CREATE OR REPLACE FUNCTION pg_temp.x() RETURNS text LANGUAGE sql AS $$ SELECT 'x' || gen_random_uuid()::text $$;
CREATE OR REPLACE FUNCTION pg_temp.typed(p_conv uuid, p_acct text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action)
  VALUES (p_conv, 'customer', 'text', 'mi zelle es ' || coalesce(p_acct, ''), 'sent', false, false) $$;
CREATE OR REPLACE FUNCTION pg_temp.w_zelle(p_conv uuid, p_acct text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v_r text;
BEGIN
  PERFORM pg_temp.typed(p_conv, p_acct);
  SELECT accion INTO v_r FROM cerebro_guardar_zelle(p_conv, 'PRUEBA Titular Tres', p_acct, pg_temp.x());
  RETURN v_r;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.w_card(p_conv uuid, p_card text, p_phone text) RETURNS text LANGUAGE sql AS $$
  SELECT accion FROM cerebro_guardar_beneficiario(p_conv, 'PRUEBA Titular Cuatro', p_card, p_phone, pg_temp.x()) $$;
CREATE OR REPLACE FUNCTION pg_temp.w_rep(p_conv uuid, p_c1 text, p_c2 text) RETURNS text LANGUAGE sql AS $$
  SELECT accion FROM cerebro_guardar_reparto(p_conv, p_c1, '53821301', '20000 CUP', p_c2, '53821302', '20000 CUP', '', '', '', pg_temp.x()) $$;
CREATE OR REPLACE FUNCTION pg_temp.pausar(p_conv uuid) RETURNS void LANGUAGE sql AS $$
  UPDATE conversations SET ai_autoreply_disabled = true WHERE id = p_conv $$;

DO $$
DECLARE
  cA constant text := '9238123432101237';
  cB constant text := '9205129978614908';
  v_conv uuid; v_done uuid; v_op uuid; v_r text; v_n int; v_acc uuid; v_ok boolean;
BEGIN
  -- 1. Rule A without a window: closed 53 h ago.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('01', 53);
  v_r := pg_temp.w_zelle(v_conv, 'PRUEBA390DONE@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '1a zelle correction of a 53 h old send: no op (ops=' || pg_temp.nops(v_conv) || '): ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('02', 53);
  v_r := pg_temp.w_card(v_conv, '9238123432101987', '');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '1b same card, 53 h: no op: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('03', 53);
  v_r := pg_temp.w_card(v_conv, '', '53821201');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '1c same phone, 53 h: no op: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('04', 53);
  v_r := pg_temp.w_rep(v_conv, '9238123432101987', cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '1d reparto with the old card, 53 h: no op: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('05', 200);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '1e same account, 200 h: no op');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('06', 53);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_done;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '1f recipient of a cancelled send: no op: ' || coalesce(v_r, 'null'));

  -- 2. A new recipient after an old send opens as before.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('07', 53);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2 AND pg_temp.naudit(v_conv) = 1 AND v_r ILIKE '%SE ABRIO UN ENVIO NUEVO%', '2a new zelle recipient, 53 h: opens, audited: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('08', 53);
  v_r := pg_temp.w_card(v_conv, cA, '53821999');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '2b new card, 53 h: opens');

  -- 3. Explicit intent newer than the old close.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('09', 53);
  INSERT INTO cerebro_servicio_declarado (conversation_id, servicio, declarado_at, actor) VALUES (v_conv, 'cuban_card', now(), 'agent:test');
  v_r := pg_temp.w_zelle(v_conv, 'prueba390done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '3a same recipient + declared service newer than the close: opens (ops=' || pg_temp.nops(v_conv) || ')');

  -- 4. Inside the window.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('10', 1);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '4a correction within the window: refused');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('11', 1);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '4b new recipient within the window, no signal: refused (rule B)');

  -- 5. Paused conversation.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('12', NULL);
  PERFORM pg_temp.pausar(v_conv);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%' AND v_r ILIKE '%pausad%', '5a paused, no history, zelle: no op: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('13', NULL);
  PERFORM pg_temp.pausar(v_conv);
  v_r := pg_temp.w_card(v_conv, cA, '53821999');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '5b paused, card: no op');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('14', NULL);
  PERFORM pg_temp.pausar(v_conv);
  v_r := pg_temp.w_rep(v_conv, cA, cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 0 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '5c paused, reparto: no op');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('15', 53);
  PERFORM pg_temp.pausar(v_conv);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1, '5d paused after an old send, new recipient: no op');

  -- 6. Paused with something open.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('16', 53);
  PERFORM pg_temp.pausar(v_conv);
  SELECT account_id INTO v_acc FROM remittance_operations WHERE id = v_done;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO v_op;
  v_r := pg_temp.w_zelle(v_conv, 'prueba390otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2 AND EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND zelle_account = 'prueba390otro@example.com'),
                      '6a paused with an open remesa: data lands on it, nothing new');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('17', NULL);
  PERFORM pg_temp.pausar(v_conv);
  SELECT account_id INTO v_acc FROM conversations WHERE id = v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, 'collecting_information', 'visa', 'GYD', 0) RETURNING id INTO v_op;
  v_ok := false;
  BEGIN
    PERFORM cerebro_escribir_bloque_beneficiario(v_conv, v_op, 'ZELLE VARIOS DESTINATARIOS' || E'\n1) Nombre: PRUEBA | Cuenta Zelle: prueba390x@example.com | Recibe: -');
  EXCEPTION WHEN OTHERS THEN v_ok := true;
  END;
  PERFORM pg_temp.chk(v_ok AND pg_temp.nops(v_conv) = 1, '6b paused + open visa: the writer refuses to open a remesa next to it (ops=' || pg_temp.nops(v_conv) || ')');

  -- 7. No history, not paused: the first send opens.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('18', NULL);
  v_r := pg_temp.w_zelle(v_conv, 'prueba390otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND pg_temp.naudit(v_conv) = 1, '7a first send, not paused: opens, audited');

  v_n := coalesce(nullif(current_setting('t390.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
