-- =====================================================================
-- Assertion for migration 132 (the Zelle name the bot confirms reaches the panel).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- (2026-10-05) Fixture rebuilt: operations come from cerebro_crear_operacion (a deal no longer creates one since 161/172/183), with the deal
-- linked where a case writes notes; two open remesas of case 11 are two operations. User and account come from whatsapp_config + profiles.
-- Texts are the shapes of real prod chats (Sep 2026).
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_deal uuid; v_op uuid; v_n text; v_r text;
  c_pipeline CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_solicitada CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900132777', 'test132') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  -- The deterministic path registered the contact LABEL (real case Liliana, b0e9ee19).
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_solicitada, 'test132', 0, 'GYD',
          E'BENEFICIARIO ZELLE\nNombre: Liliana\nCuenta Zelle: 6025563888', 'open') RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 0, 'GYD', c_solicitada);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  -- ...and the Cerebro accumulated it ('Merge beneficiario').
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_nombre, zelle_cuenta, zelle_nombre_cuenta)
  VALUES (v_conv, 'Liliana', '6025563888', '6025563888');
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', '[Contacto] Liliana 16025563888', now() - interval '3 minutes'),
    (v_conv, 'customer', 'text', 'Liliana Gonzales Velázquez', now() - interval '3 minutes');

  -- 1. The bot confirms the full name for THAT account → the panel takes it.
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'agent', 'text',
    E'Anotado. La cuenta Zelle queda así:\n\n*Nombre:* Liliana Gonzales Velázquez\n*Celular:* 16025563888\n\n¿Desde dónde va a depositar?');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n IS DISTINCT FROM 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 1: the confirmed name should reach the panel, got %', v_n; END IF;
  SELECT zelle_nombre INTO v_n FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv;
  IF v_n IS DISTINCT FROM 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 1: the accumulated name must follow, got %', v_n; END IF;
  RAISE NOTICE 'PASS 1: the name the bot confirms for the registered account reaches the panel';

  -- 2. A bot typo (real case b2952375: customer "Mairenys", bot "Mairensy") never overwrites.
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'Anotado. La cuenta Zelle queda así:\n\n*Nombre:* Lilianna Gonzales Velázquez\n*Celular:* +1 (602) 556-3888');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r <> 'no_escrito_por_cliente' OR v_n <> 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 2: a name the customer never wrote must be ignored, got % / %', v_r, v_n; END IF;
  RAISE NOTICE 'PASS 2: a name the customer did not write is ignored';

  -- 3. Another account → nothing (only corrects the name of the registered account).
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', 'Jaime Rodriguez');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'Anotado. La cuenta Zelle queda así:\n\n*Nombre:* Jaime Rodriguez\n*Celular:* 2392695584');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r NOT IN ('otro_beneficiario', 'cuenta_no_escrita_por_cliente') OR v_n <> 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 3: another account must not change anything, got % / %', v_r, v_n; END IF;
  RAISE NOTICE 'PASS 3: a confirmation for a different account changes nothing';

  -- 4. Repartos (two accounts in one message) are left to the reparto path.
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'Anotado la primera cuenta Zelle:\n\n*Nombre:* Jaime Rodriguez\n*Celular:* 6025563888\n\n*Nombre:* Otra Persona\n*Celular:* 2392695584');
  IF v_r <> 'varias_cuentas' THEN RAISE EXCEPTION 'case 4: a message with two Zelle blocks must be ignored, got %', v_r; END IF;
  RAISE NOTICE 'PASS 4: a message with several accounts is ignored';

  -- 5. Locked beneficiaries (operator correction) are never touched.
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb) || '{"beneficiaries": {"by": "test"}}' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', 'Liliana Gonzales');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'La cuenta Zelle queda así:\n\n*Nombre:* Liliana Gonzales\n*Celular:* 6025563888');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r <> 'bloqueado' OR v_n <> 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 5: locked beneficiaries must not change, got % / %', v_r, v_n; END IF;
  RAISE NOTICE 'PASS 5: locked beneficiaries are never touched';

  -- 6. Emojis and flags in the confirmed name are dropped; garbage input never raises.
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = admin_locked_fields - 'beneficiaries' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', 'Liliana Gonzales Velazquez Perez💙🇺🇸');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'La cuenta Zelle queda así:\n\n*Nombre:* Liliana Gonzales Velazquez Perez💙🇺🇸\n*Celular:* 6025563888');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r <> 'aplicado' OR v_n <> 'Liliana Gonzales Velazquez Perez' THEN RAISE EXCEPTION 'case 6: emojis must be dropped, got % / %', v_r, v_n; END IF;
  v_r := cerebro_aplicar_nombre_confirmado(NULL, NULL);
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, '*Nombre:*');
  RAISE NOTICE 'PASS 6: emojis are dropped and invalid input never raises';

  IF has_function_privilege('anon', 'cerebro_aplicar_nombre_confirmado(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 7: anon must not execute it';
  END IF;
  RAISE NOTICE 'PASS 7: not exposed to anon';

  -- 8. (135) The bot confirmed an account that was NEVER stored (real case 00ced244, Yamile: the
  --    number on one line and the name on the next, a format the extractor does not read). The
  --    remesa has no beneficiary → the confirmed account is registered.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900135008', 'test135') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_solicitada, 'test135', 13000, 'GYD', 'DEPOSITO: 13,000 GYD', 'open') RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 13000, 'GYD', c_solicitada);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', 'Hola buenos días para comprar 50 selle', now() - interval '3 minutes'),
    (v_conv, 'customer', 'text', '+1 (602) 317-3696', now() - interval '2 minutes'),
    (v_conv, 'customer', 'text', 'Yamile Dominguez', now() - interval '2 minutes');
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'agent', 'text',
    E'Anotado. La cuenta Zelle queda así:\n\n*Nombre:* Yamile Dominguez\n*Celular:* +1 (602) 317-3696\n\nEstamos fuera de horario.');
  SELECT name || '|' || zelle_account INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n IS DISTINCT FROM 'Yamile Dominguez|6023173696' THEN RAISE EXCEPTION 'case 8: the confirmed account must be registered, got %', v_n; END IF;
  RAISE NOTICE 'PASS 8: an account the bot confirmed and nobody stored is registered';

  -- 9. The customer never wrote that account (the bot made it up or copied it from elsewhere) → nothing.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900135009', 'test135b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_solicitada, 'test135b', 13000, 'GYD', 'DEPOSITO: 13,000 GYD', 'open') RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 13000, 'GYD', c_solicitada);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', 'Yamile Dominguez', now() - interval '2 minutes');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'La cuenta Zelle queda así:\n\n*Nombre:* Yamile Dominguez\n*Celular:* +1 (602) 317-3696');
  IF v_r <> 'cuenta_no_escrita_por_cliente' OR EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op) THEN
    RAISE EXCEPTION 'case 9: an account the customer never wrote must not be registered, got %', v_r;
  END IF;
  RAISE NOTICE 'PASS 9: an account the customer did not write is never registered';

  -- 10. The remesa already has a DIFFERENT beneficiary → never replaced from a confirmation.
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', '+1 (602) 317-3696');
  UPDATE deals SET notes = notes || E'\n---\nBENEFICIARIO ZELLE\nNombre: Otra Persona\nCuenta Zelle: 3055550000' WHERE id = v_deal;
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'La cuenta Zelle queda así:\n\n*Nombre:* Yamile Dominguez\n*Celular:* +1 (602) 317-3696');
  SELECT string_agg(zelle_account, ',') INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r <> 'otro_beneficiario' OR v_n <> '3055550000' THEN RAISE EXCEPTION 'case 10: a different beneficiary must be kept, got % / %', v_r, v_n; END IF;
  RAISE NOTICE 'PASS 10: never replaces a different beneficiary';

  -- 11. Two open remesas and no evidence for either → the matcher abstains → nothing.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900135011', 'test135c') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_crear_operacion(v_conv, 13000, 'GYD', c_solicitada);
  PERFORM cerebro_crear_operacion(v_conv, 26000, 'GYD', c_solicitada);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', E'Yamile Dominguez\n+1 (602) 317-3696', now() - interval '70 minutes');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'La cuenta Zelle queda así:\n\n*Nombre:* Yamile Dominguez\n*Celular:* +1 (602) 317-3696');
  IF v_r <> 'ambigua' OR EXISTS (SELECT 1 FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = v_conv) THEN
    RAISE EXCEPTION 'case 11: with two remesas and no evidence nothing must be registered, got %', v_r;
  END IF;
  RAISE NOTICE 'PASS 11: with several remesas and no evidence it abstains';

  -- 12. A Cuban card confirmation ("*Celular:* +53 5474 3463" = 10 digits) is never taken as Zelle.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900135012', 'test135e') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_solicitada, 'test135e', 20000, 'GYD', 'DEPOSITO: 20,000 GYD', 'open') RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 20000, 'GYD', c_solicitada);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', E'Yony de la Cruz\nTarjeta: 9204 9598 7520 9704\nMóvil: +53 5474 3463', now() - interval '2 minutes');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'Anotado:\n\n*Nombre:* Yony de la Cruz\n*Tarjeta:* 9204 9598 7520 9704\n*Celular:* +53 5474 3463');
  IF v_r = 'registrado' OR EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op) THEN
    RAISE EXCEPTION 'case 12: a Cuban card confirmation must never be registered as Zelle, got %', v_r;
  END IF;
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'Anotado. La cuenta Zelle queda así:\n\n*Nombre:* Yony de la Cruz\n*Celular:* +53 5474 3463');
  IF v_r = 'registrado' OR EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op) THEN
    RAISE EXCEPTION 'case 12: a +53 number is a Cuban mobile, never a Zelle account, got %', v_r;
  END IF;
  RAISE NOTICE 'PASS 12: Cuban card confirmations and +53 numbers are never registered as Zelle';
END $$;

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
