\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 360 (a recipient write never opens a ghost operation). Run as  BEGIN; 360; <this file>; ROLLBACK;
-- or with 360 applied. Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Every fixture is synthetic PRUEBA data created inside the rolled-back transaction.
-- Cases:
--   1. Sandra shape: operation completed 1 h ago, Zelle write with another account, no new-send signal -> no operation opens,
--      reply starts "NO SE ABRIO NINGUN ENVIO" (rule B). Same for the card writer, the reparto writer and the automatic Zelle reader.
--   2. Rule A: the account / card / phone of the completed send -> refused, nothing opens, reply says it belongs to the completed send.
--      Owner override: rule A yields ONLY to an explicit send intent newer than the completion (declared service, pending rail,
--      registered deposit); a quote or an agreed amount alone does not (cases 2f-2k).
--   3. Completed 7 h ago (outside the 6 h window): the operation opens, an audit row is written, the reply says a new send was opened.
--   4. No completed operation at all (legit first send "account first, deposit later"): opens, audited, reply says so (4 writers).
--   5. Inside the window with a new-send signal (mismatched declared service, quote, agreed amount, pending rail, deposit): opens.
--   6. An open operation present: unchanged (data goes to it, nothing new opens, no new-send notice).
--   7. Grants: the guard is service_role only; the writers keep service_role.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t360.fail', (coalesce(nullif(current_setting('t360.fail', true), ''), '0')::int + 1)::text, true);
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
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900360' || p_tag, 'PRUEBA360' || p_tag) RETURNING id INTO v_ct;
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
    VALUES (o_done, 'zelle', 'PRUEBA Titular Uno', 'prueba360done@example.com', 1, 1, 'notes_parse', 'vigente');
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

DO $$
DECLARE
  cA constant text := '9238123432101237';   -- a card that is not the completed send's
  cB constant text := '9205129978614908';
  v_conv uuid; v_done uuid; v_op uuid; v_r text; v_n int; v_acc uuid;
BEGIN
  PERFORM pg_temp.chk(to_regprocedure('public.cerebro_guardia_envio_nuevo(uuid,text[],text[],text[])') IS NOT NULL, '0 cerebro_guardia_envio_nuevo exists');

  -- 1. Sandra shape: completed 1 h ago, a Zelle write of another account, no signal.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('01', 1);
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1, '1a zelle: no operation opened (ops=' || pg_temp.nops(v_conv) || ')');
  PERFORM pg_temp.chk(v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '1b zelle reply: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('02', 1);
  v_r := pg_temp.w_auto(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '1c zelle auto: refused, no op: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('03', 1);
  v_r := pg_temp.w_card(v_conv, cA, '53821999');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '1d card: refused, no op: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('04', 1);
  v_r := pg_temp.w_rep(v_conv, cA, cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '1e reparto: refused, no op: ' || coalesce(v_r, 'null'));
  PERFORM pg_temp.chk(v_r ILIKE '%pregunt%nuevo%', '1f the reply tells the model to ask about a new send');

  -- 2. Rule A: the data of the completed send.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('05', 1);
  v_r := pg_temp.w_zelle(v_conv, 'PRUEBA360DONE@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%' AND v_r ILIKE '%ya se completo%', '2a same zelle account (case-insensitive): ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('06', 1);
  v_r := pg_temp.w_card(v_conv, '9238123432101987', '');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%' AND v_r ILIKE '%ya se completo%', '2b same card: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('07', 1);
  v_r := pg_temp.w_card(v_conv, '', '53821201');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '2c same phone: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('08', 1);
  v_r := pg_temp.w_rep(v_conv, '9238123432101987', cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '2d reparto with the completed card: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('09', 1);
  v_r := pg_temp.w_auto(v_conv, 'prueba360done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '2e zelle auto with the completed account: ' || coalesce(v_r, 'null'));

  -- 2f-2k. Rule A and explicit intent: same recipient + declared service / pending rail / deposit opens; quote or agreed amount alone is refused.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('23', 1);
  INSERT INTO cerebro_servicio_declarado (conversation_id, servicio, declarado_at, actor) VALUES (v_conv, 'cuban_card', now(), 'agent:test');
  v_r := pg_temp.w_zelle(v_conv, 'prueba360done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2 AND pg_temp.naudit(v_conv) = 1, '2f same recipient + declared service: opens, audited (ops=' || pg_temp.nops(v_conv) || ')');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('24', 1);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv, 'clasica', now(), 'cliente');
  v_r := pg_temp.w_card(v_conv, '9238123432101987', '53821201');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2 AND pg_temp.naudit(v_conv) = 1, '2g same recipient + pending rail: opens, audited');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('25', 1);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id)
  VALUES ('361' || (extract(epoch FROM clock_timestamp()) * 1000)::bigint::text, 5000, 'GYD', 'PRUEBA360', now(), v_done);
  v_r := pg_temp.w_zelle(v_conv, 'prueba360done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '2h same recipient + deposit: opens');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('26', 1);
  INSERT INTO cerebro_cotizacion (conversation_id, gyd, texto, cotizado_en) VALUES (v_conv, 9000, 'PRUEBA', now());
  v_r := pg_temp.w_zelle(v_conv, 'prueba360done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '2i same recipient + quote only: refused: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('27', 1);
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en) VALUES (v_conv, 50, 'USD', now())
  ON CONFLICT (conversation_id) DO UPDATE SET monto = 50, moneda = 'USD', fijado_en = now(), cerrado_en = NULL, operation_id = NULL;
  v_r := pg_temp.w_card(v_conv, '9238123432101987', '53821201');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '2j same recipient + agreed amount only: refused: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('28', 1);
  v_r := pg_temp.w_rep(v_conv, '9238123432101987', cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE GUARDO NADA%', '2k same recipient, no signal (reparto): refused');

  -- 3. Completed 7 h ago: outside the window, the write opens a send, audited, and the reply says so.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('10', 7);
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '3a opened a new operation (ops=' || pg_temp.nops(v_conv) || ')');
  PERFORM pg_temp.chk(pg_temp.naudit(v_conv) = 1, '3b audit row written (' || pg_temp.naudit(v_conv) || ')');
  PERFORM pg_temp.chk(v_r ILIKE '%SE ABRIO UN ENVIO NUEVO%', '3c reply says a new send was opened: ' || coalesce(v_r, 'null'));
  -- same account as the long-completed send is NOT refused outside the window
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('11', 7);
  v_r := pg_temp.w_zelle(v_conv, 'prueba360done@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '3d same account outside the window still opens');

  -- 4. No completed operation: the legit first send, account first, deposit later; every writer.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('12', NULL);
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND pg_temp.naudit(v_conv) = 1 AND v_r ILIKE '%SE ABRIO UN ENVIO NUEVO%', '4a zelle: opens, audited, reply: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('13', NULL);
  v_r := pg_temp.w_auto(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND pg_temp.naudit(v_conv) = 1 AND v_r ILIKE '%SE ABRIO UN ENVIO NUEVO%', '4b zelle auto: opens, audited: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('14', NULL);
  v_r := pg_temp.w_card(v_conv, cA, '53821999');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND pg_temp.naudit(v_conv) = 1 AND v_r ILIKE '%SE ABRIO UN ENVIO NUEVO%', '4c card: opens, audited: ' || coalesce(v_r, 'null'));
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('15', NULL);
  v_r := pg_temp.w_rep(v_conv, cA, cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND pg_temp.naudit(v_conv) = 1 AND v_r ILIKE '%SE ABRIO UN ENVIO NUEVO%', '4d reparto: opens, audited: ' || coalesce(v_r, 'null'));

  -- 5. Inside the window with a new-send signal: the operation opens normally (audited, reply says so).
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('16', 1);
  INSERT INTO cerebro_servicio_declarado (conversation_id, servicio, declarado_at, actor) VALUES (v_conv, 'cuban_card', now(), 'agent:test');
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');   -- declared rail differs from the tool's: the resolver gives NULL, the signal lets it open
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2 AND pg_temp.naudit(v_conv) = 1, '5a declared service: opens, audited (ops=' || pg_temp.nops(v_conv) || ')');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('17', 1);
  INSERT INTO cerebro_cotizacion (conversation_id, gyd, texto, cotizado_en) VALUES (v_conv, 9000, 'PRUEBA', now());
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '5b quote after the completion: opens');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('18', 1);
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, fijado_en) VALUES (v_conv, 50, 'USD', now())
  ON CONFLICT (conversation_id) DO UPDATE SET monto = 50, moneda = 'USD', fijado_en = now(), cerrado_en = NULL, operation_id = NULL;
  v_r := pg_temp.w_card(v_conv, cA, '53821999');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '5c agreed amount after the completion: opens');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('19', 1);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv, 'clasica', now(), 'cliente');
  v_r := pg_temp.w_rep(v_conv, cA, cB);
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '5d pending rail after the completion: opens');
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('20', 1);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id)
  VALUES ('360' || (extract(epoch FROM clock_timestamp()) * 1000)::bigint::text, 5000, 'GYD', 'PRUEBA360', now(), v_done);
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2, '5e deposit registered after the completion: opens');
  -- a quote made BEFORE the completion is not a signal
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('21', 1);
  INSERT INTO cerebro_cotizacion (conversation_id, gyd, texto, cotizado_en) VALUES (v_conv, 9000, 'PRUEBA', now() - interval '3 hours');
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 1 AND v_r LIKE 'NO SE ABRIO NINGUN ENVIO%', '5f a quote from before the completion is no signal');

  -- 6. An open operation present: unchanged, the data goes to it and nothing new opens.
  SELECT * INTO v_conv, v_done FROM pg_temp.fx('22', 1);
  SELECT account_id INTO v_acc FROM remittance_operations WHERE id = v_done;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO v_op;
  v_r := pg_temp.w_zelle(v_conv, 'prueba360otro@example.com');
  PERFORM pg_temp.chk(pg_temp.nops(v_conv) = 2 AND pg_temp.naudit(v_conv) = 0, '6a open op: no new op, no new-send audit');
  PERFORM pg_temp.chk(v_r LIKE 'guardado%' AND v_r NOT ILIKE '%SE ABRIO UN ENVIO NUEVO%', '6b open op: normal reply: ' || coalesce(v_r, 'null'));
  PERFORM pg_temp.chk(EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND zelle_account = 'prueba360otro@example.com'), '6c data landed on the open op');

  -- 7. Grants.
  IF to_regprocedure('public.cerebro_guardia_envio_nuevo(uuid,text[],text[],text[])') IS NOT NULL THEN
    PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_guardia_envio_nuevo(uuid,text[],text[],text[])', 'EXECUTE')
                        AND NOT has_function_privilege('anon', 'public.cerebro_guardia_envio_nuevo(uuid,text[],text[],text[])', 'EXECUTE')
                        AND NOT has_function_privilege('authenticated', 'public.cerebro_guardia_envio_nuevo(uuid,text[],text[],text[])', 'EXECUTE'),
                        '7a guard: service_role only');
  END IF;
  PERFORM pg_temp.chk(has_function_privilege('service_role', 'public.cerebro_guardar_zelle(uuid,text,text,text,uuid,text,integer,boolean,numeric)', 'EXECUTE')
                      AND has_function_privilege('service_role', 'public.cerebro_guardar_beneficiario(uuid,text,text,text,text,uuid,text,integer,text)', 'EXECUTE')
                      AND has_function_privilege('service_role', 'public.cerebro_guardar_reparto(uuid,text,text,text,text,text,text,text,text,text,text,uuid,text)', 'EXECUTE')
                      AND has_function_privilege('service_role', 'public.cerebro_guardar_zelle_auto(uuid,text,text,text)', 'EXECUTE'),
                      '7b the writers keep service_role');

  v_n := coalesce(nullif(current_setting('t360.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
