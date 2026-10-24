-- 296: an agent reply that promises a write with no tool_execution_log row in the turn is recorded and gets a
-- system memory note for the next turn. Customer messages, non-AI messages and replies that did write are ignored.
DO $$
DECLARE
  v_conv uuid;
  v_msg uuid := gen_random_uuid();
  v_msg_write uuid := gen_random_uuid();
  v_nota integer;
  v_fail text := '';
BEGIN
  SELECT c.id INTO v_conv FROM conversations c LIMIT 1;

  IF NOT cerebro_texto_promete('Anotado, es Oberto') THEN v_fail := v_fail || ' 1:anotado'; END IF;
  IF NOT cerebro_texto_promete('La cuenta queda así: Rodolfo') THEN v_fail := v_fail || ' 2:queda-asi'; END IF;
  IF NOT cerebro_texto_promete('Quedó registrado el celular') THEN v_fail := v_fail || ' 3:quedo'; END IF;
  IF cerebro_texto_promete('Listo, cualquier cosa me dices') THEN v_fail := v_fail || ' 4:listo'; END IF;

  -- 1. Promise, no write in the turn -> audit row + memory note.
  INSERT INTO messages (id, conversation_id, sender_type, content_type, status, content_text, ai_generated, is_panel_action)
  VALUES (v_msg, v_conv, 'agent', 'text', 'sent', 'Anotado, es Oberto', true, false);

  IF (SELECT count(*) FROM cerebro_promesas_sin_escritura WHERE message_id = v_msg) <> 1 THEN
    v_fail := v_fail || ' 5:sin-auditoria';
  END IF;
  SELECT note_id INTO v_nota FROM cerebro_promesas_sin_escritura WHERE message_id = v_msg;
  IF v_nota IS NULL OR NOT EXISTS (
       SELECT 1 FROM cerebro_memoria
        WHERE id = v_nota AND session_id = v_conv::text
          AND message->>'type' = 'human'
          AND message->>'content' LIKE '[CONTEXTO DEL SISTEMA%'
  ) THEN
    v_fail := v_fail || ' 6:sin-nota';
  END IF;

  -- 2. Same promise, but a write tool ran a minute before -> ignored.
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, outcome)
  VALUES ('prueba-296-' || gen_random_uuid(), 'registrar_beneficiario', 'prueba-296', v_conv, 'ok');
  INSERT INTO messages (id, conversation_id, sender_type, content_type, status, content_text, ai_generated, is_panel_action)
  VALUES (v_msg_write, v_conv, 'agent', 'text', 'sent', 'Anotado el celular', true, false);
  IF EXISTS (SELECT 1 FROM cerebro_promesas_sin_escritura WHERE message_id = v_msg_write) THEN
    v_fail := v_fail || ' 7:ignora-escritura';
  END IF;

  -- 3. Customer message with the same words -> ignored.
  INSERT INTO messages (conversation_id, sender_type, content_type, status, content_text, ai_generated, is_panel_action)
  VALUES (v_conv, 'customer', 'text', 'delivered', 'anotado', false, false);
  IF (SELECT count(*) FROM cerebro_promesas_sin_escritura WHERE content_excerpt = 'anotado') > 0 THEN
    v_fail := v_fail || ' 8:cliente';
  END IF;

  -- 4. Non-AI agent message (panel) -> ignored.
  INSERT INTO messages (conversation_id, sender_type, content_type, status, content_text, ai_generated, is_panel_action)
  VALUES (v_conv, 'agent', 'text', 'sent', 'Anotado por el panel', false, true);
  IF (SELECT count(*) FROM cerebro_promesas_sin_escritura WHERE content_excerpt = 'Anotado por el panel') > 0 THEN
    v_fail := v_fail || ' 9:panel';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
