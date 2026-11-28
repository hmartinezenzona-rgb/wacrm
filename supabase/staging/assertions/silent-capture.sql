\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migrations 374 and 376 (silent capture while a human of the team attends the chat; 376: it NEVER opens a send).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA374', phones 5990374xxxx.
-- Shape of production exec 736897 (2026-11-14): the Decisor routed `silencio` because an admin had just written; the batch carried one
-- Zelle account (the same number listed twice by the snapshot) and an open send existed. Nothing stored the account.
-- Cases:
--   1  human-attending silence + open send + one account listed twice -> the account is the only vigente Zelle recipient
--   2  each human-attending reason is accepted (paused, assigned, human just wrote)
--   3  any other silence reason (admin message, hidden chat, courtesy, empty) -> nothing written
--   4  two different accounts in the batch -> nothing written
--   5  a split between several people in the batch -> nothing written
--   6  the send already has a vigente Zelle recipient with ANOTHER account (agent or admin wrote it) -> not overwritten
--   7  the send already has that same account -> still one recipient
--   8  no open send: nothing is written and NO send is opened, with the account alone or with holder + account (376; 374 opened one)
--   8c shape of production conversation 78e3540b (2026-11-17): the previous send is COMPLETED, the customer sends holder + account to
--      have the money re-sent -> no new send, nothing written (374 opened a 0 GYD send that made the bot ask for a new deposit)
--   10 two open sends and no way to tell which one -> nothing written
--   9  no account in the batch -> nothing written
-- =====================================================================
CREATE FUNCTION pg_temp.chk(p_ok boolean, p_label text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS NOT TRUE THEN
    PERFORM set_config('t374.fail', (coalesce(nullif(current_setting('t374.fail', true), ''), '0')::int + 1)::text, true);
    RAISE NOTICE 'FAIL [%]', p_label;
  ELSE RAISE NOTICE 'ok   [%]', p_label; END IF;
END $f$;

-- conversation with (optionally) an open send
CREATE FUNCTION pg_temp.fx(p_n int, p_open boolean, OUT o_conv uuid, OUT o_op uuid, OUT o_acc uuid) LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, o_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, o_acc, '5990374' || lpad(p_n::text, 4, '0'), 'PRUEBA374 ' || p_n) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, o_acc, v_ct) RETURNING id INTO o_conv;
  IF p_open THEN
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
    VALUES (o_acc, o_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 14000, 'zelle') RETURNING id INTO o_op;
  END IF;
END $f$;
CREATE FUNCTION pg_temp.msg(p_conv uuid, p_text text) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, status, ai_generated, is_panel_action, created_at)
  VALUES (p_conv, 'customer', 'text', p_text, 'sent', false, false, now() - interval '20 seconds')
$f$;
CREATE FUNCTION pg_temp.x() RETURNS text LANGUAGE sql AS $f$ SELECT 'x' || gen_random_uuid()::text $f$;
CREATE FUNCTION pg_temp.nops(p_conv uuid) RETURNS int LANGUAGE sql AS $f$ SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv $f$;
-- a second open send, empty
CREATE FUNCTION pg_temp.abierta(p_conv uuid) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_acc uuid; v_ct uuid;
BEGIN
  SELECT account_id, contact_id INTO v_acc, v_ct FROM conversations WHERE id = p_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, p_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 14000, 'zelle');
END $f$;
-- a send already completed (the closing needs the admin origin)
CREATE FUNCTION pg_temp.cerrada(p_conv uuid) RETURNS void LANGUAGE plpgsql AS $f$
DECLARE v_acc uuid; v_ct uuid; v_op uuid;
BEGIN
  SELECT account_id, contact_id INTO v_acc, v_ct FROM conversations WHERE id = p_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, created_at)
  VALUES (v_acc, p_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 39000, 'zelle', now() - interval '1 day') RETURNING id INTO v_op;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() - interval '20 hours' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
END $f$;
CREATE FUNCTION pg_temp.nrec(p_conv uuid) RETURNS int LANGUAGE sql AS $f$
  SELECT count(*)::int FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv AND b.status = 'vigente' AND b.beneficiary_type = 'zelle' $f$;
CREATE FUNCTION pg_temp.tiene(p_conv uuid, p_digits text) RETURNS boolean LANGUAGE sql AS $f$
  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
                  WHERE o.conversation_id = p_conv AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
                    AND regexp_replace(coalesce(b.zelle_account, ''), '\D', '', 'g') LIKE '%' || p_digits) $f$;

DO $$
DECLARE
  cHumano constant text := 'un humano del equipo acaba de escribir';
  cA constant text := '5515550101';
  cB constant text := '7865550102';
  c record; v_r text; v_n int; v_m text; v_i int := 0;
BEGIN
  -- 1 the production shape
  SELECT * INTO c FROM pg_temp.fx(1, true);
  PERFORM pg_temp.msg(c.o_conv, 'Te sale registrado como PRUEBA FARM LLC ' || '+1 551 555-0101');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA, cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 1 AND pg_temp.tiene(c.o_conv, cA), '1 account stored on the open send: ' || coalesce(v_r, 'null'));

  -- 2 every human-attending reason
  FOREACH v_m IN ARRAY ARRAY['bot pausado a mano en esta conversacion', 'chat asignado a humano', cHumano] LOOP
    v_i := v_i + 1;
    SELECT * INTO c FROM pg_temp.fx(20 + v_i, true);
    PERFORM pg_temp.msg(c.o_conv, 'mi zelle +1 551 555-0101');
    SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, v_m, '', ARRAY[cA], false, pg_temp.x());
    PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 1, '2 reason accepted [' || v_m || ']: ' || coalesce(v_r, 'null'));
  END LOOP;

  -- 3 other silences write nothing
  FOREACH v_m IN ARRAY ARRAY['mensaje del admin', 'chat oculto por el operador', 'cortesia', ''] LOOP
    v_i := v_i + 1;
    SELECT * INTO c FROM pg_temp.fx(30 + v_i, true);
    PERFORM pg_temp.msg(c.o_conv, 'mi zelle +1 551 555-0101');
    SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, v_m, '', ARRAY[cA], false, pg_temp.x());
    PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND v_r LIKE 'no aplica%', '3 other silence writes nothing [' || v_m || ']: ' || coalesce(v_r, 'null'));
  END LOOP;
  SELECT * INTO c FROM pg_temp.fx(39, true);
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, NULL, '', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND v_r LIKE 'no aplica%', '3 null reason writes nothing: ' || coalesce(v_r, 'null'));

  -- 4 two different accounts
  SELECT * INTO c FROM pg_temp.fx(4, true);
  PERFORM pg_temp.msg(c.o_conv, '+1 551 555-0101 y +1 786 555-0102');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA, cB], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND v_r LIKE 'no se guarda%', '4 two accounts: ' || coalesce(v_r, 'null'));

  -- 5 a split in the batch
  SELECT * INTO c FROM pg_temp.fx(5, true);
  PERFORM pg_temp.msg(c.o_conv, 'mi zelle +1 551 555-0101');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA], true, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND v_r LIKE 'no se guarda%', '5 split: ' || coalesce(v_r, 'null'));

  -- 6 another account already vigente is not overwritten
  SELECT * INTO c FROM pg_temp.fx(6, true);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (c.o_op, 'zelle', 'PRUEBA Titular Admin', cB, 1, 1, 'admin_addition', 'vigente');
  PERFORM pg_temp.msg(c.o_conv, 'mi zelle +1 551 555-0101');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 1 AND pg_temp.tiene(c.o_conv, cB) AND NOT pg_temp.tiene(c.o_conv, cA) AND v_r LIKE 'no se guarda%',
                      '6 existing recipient kept: ' || coalesce(v_r, 'null'));

  -- 7 the same account already there
  SELECT * INTO c FROM pg_temp.fx(7, true);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (c.o_op, 'zelle', 'PRUEBA Titular Uno', cA, 1, 1, 'notes_parse', 'vigente');
  PERFORM pg_temp.msg(c.o_conv, 'mi zelle +1 551 555-0101');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 1 AND pg_temp.tiene(c.o_conv, cA), '7 same account, still one: ' || coalesce(v_r, 'null'));

  -- 8 no open send: never opens one (376)
  SELECT * INTO c FROM pg_temp.fx(8, false);
  PERFORM pg_temp.msg(c.o_conv, '+1 551 555-0101');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND pg_temp.nops(c.o_conv) = 0 AND v_r LIKE 'no se guarda%', '8a account alone, no send opened: ' || coalesce(v_r, 'null'));
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, 'PRUEBA Titular Dos', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND pg_temp.nops(c.o_conv) = 0 AND v_r LIKE 'no se guarda%', '8b holder + account, no send opened: ' || coalesce(v_r, 'null'));

  -- 8c the previous send is completed (re-send after a bounced transfer)
  SELECT * INTO c FROM pg_temp.fx(80, false);
  PERFORM pg_temp.cerrada(c.o_conv);
  PERFORM pg_temp.msg(c.o_conv, 'PRUEBA Titular Tres +1 551 555-0101');
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, 'PRUEBA Titular Tres', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND pg_temp.nops(c.o_conv) = 1 AND v_r LIKE 'no se guarda%', '8c completed send only, no new send: ' || coalesce(v_r, 'null'));

  -- 10 two open sends, nothing tells which one
  SELECT * INTO c FROM pg_temp.fx(100, true);
  PERFORM pg_temp.abierta(c.o_conv);
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', ARRAY[cA], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND pg_temp.nops(c.o_conv) = 2 AND v_r LIKE 'no se guarda%', '10 two open sends: ' || coalesce(v_r, 'null'));

  -- 9 no account
  SELECT * INTO c FROM pg_temp.fx(9, true);
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, 'PRUEBA Titular', ARRAY[]::text[], false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND v_r LIKE 'sin cuenta%', '9 no account: ' || coalesce(v_r, 'null'));
  SELECT accion INTO v_r FROM cerebro_capturar_en_silencio(c.o_conv, cHumano, '', NULL, false, pg_temp.x());
  PERFORM pg_temp.chk(pg_temp.nrec(c.o_conv) = 0 AND v_r LIKE 'sin cuenta%', '9 null list: ' || coalesce(v_r, 'null'));

  v_n := coalesce(nullif(current_setting('t374.fail', true), ''), '0')::int;
  IF v_n > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_n; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
