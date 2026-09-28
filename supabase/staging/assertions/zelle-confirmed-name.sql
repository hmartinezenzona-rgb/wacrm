-- =====================================================================
-- Assertion for migration 132 (the Zelle name the bot confirms reaches the panel).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Texts are the shapes of real prod chats (Sep 2026).
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_deal uuid; v_op uuid; v_n text; v_r text;
  c_pipeline CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_solicitada CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900132777', 'test132') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  -- The deterministic path registered the contact LABEL (real case Liliana, b0e9ee19).
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_solicitada, 'test132', 0, 'GYD',
          E'BENEFICIARIO ZELLE\nNombre: Liliana\nCuenta Zelle: 6025563888', 'open') RETURNING id INTO v_deal;
  SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal;
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
  IF v_r <> 'otra_cuenta' OR v_n <> 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 3: another account must not change anything, got % / %', v_r, v_n; END IF;
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
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'*Nombre:* Liliana Gonzales\n*Celular:* 6025563888');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r <> 'bloqueado' OR v_n <> 'Liliana Gonzales Velázquez' THEN RAISE EXCEPTION 'case 5: locked beneficiaries must not change, got % / %', v_r, v_n; END IF;
  RAISE NOTICE 'PASS 5: locked beneficiaries are never touched';

  -- 6. Emojis and flags in the confirmed name are dropped; garbage input never raises.
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = admin_locked_fields - 'beneficiaries' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', 'Liliana Gonzales Velazquez Perez💙🇺🇸');
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, E'*Nombre:* Liliana Gonzales Velazquez Perez💙🇺🇸\n*Celular:* 6025563888');
  SELECT name INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r <> 'aplicado' OR v_n <> 'Liliana Gonzales Velazquez Perez' THEN RAISE EXCEPTION 'case 6: emojis must be dropped, got % / %', v_r, v_n; END IF;
  v_r := cerebro_aplicar_nombre_confirmado(NULL, NULL);
  v_r := cerebro_aplicar_nombre_confirmado(v_conv, '*Nombre:*');
  RAISE NOTICE 'PASS 6: emojis are dropped and invalid input never raises';

  IF has_function_privilege('anon', 'cerebro_aplicar_nombre_confirmado(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 7: anon must not execute it';
  END IF;
  RAISE NOTICE 'PASS 7: not exposed to anon';
END $$;
