-- 300: the ingestion watchdog records a customer message that never reached the bot and queues one admin alert.
DO $$
DECLARE
  v_acc uuid; v_user uuid; v_conv uuid; v_contact uuid; v_admin uuid;
  v_admin_tag constant uuid := 'aaa95c92-63a4-4bc1-a300-1cca6d87c072';
  v_miss  text := 'prueba-ingesta-' || gen_random_uuid();
  v_rec   text := 'prueba-ingesta-rec-' || gen_random_uuid();
  v_done  text := 'prueba-ingesta-ok-' || gen_random_uuid();
  v_old   text := 'prueba-ingesta-old-' || gen_random_uuid();
  v_n integer;
  v_fail text := '';
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc FROM profiles p ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT c.id, c.contact_id INTO v_conv, v_contact FROM conversations c LIMIT 1;

  INSERT INTO contacts (user_id, phone, name, account_id)
  VALUES (v_user, '5990299999', 'PRUEBA ingesta admin', v_acc) RETURNING id INTO v_admin;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_admin, v_admin_tag);

  INSERT INTO messages (conversation_id, sender_type, content_type, status, content_text, ai_generated, is_panel_action, message_id, created_at)
  VALUES (v_conv, 'customer', 'text', 'delivered', 'prueba ingesta perdida', false, false, v_miss, now() - interval '10 minutes'),
         (v_conv, 'customer', 'text', 'delivered', 'prueba ingesta reciente', false, false, v_rec, now() - interval '1 minute'),
         (v_conv, 'customer', 'text', 'delivered', 'prueba ingesta procesada', false, false, v_done, now() - interval '10 minutes'),
         (v_conv, 'customer', 'text', 'delivered', 'prueba ingesta vieja', false, false, v_old, now() - interval '25 hours');

  INSERT INTO session_events (conversation_id, contact_phone, tipo, whatsapp_message_id)
  VALUES (v_conv, '5990299999', 'text', v_done);

  v_n := cerebro_vigilar_ingesta();

  IF v_n <> 1 THEN v_fail := v_fail || ' 1:conteo=' || v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_ingesta_perdida WHERE message_id = v_miss AND alerta) THEN
    v_fail := v_fail || ' 2:sin-registro';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM message_outbox
                  WHERE conversation_id = v_conv AND telefono_e164 = '5990299999'
                    AND payload ->> 'text' LIKE 'AVISO INGESTA%') THEN
    v_fail := v_fail || ' 3:sin-aviso';
  END IF;
  IF EXISTS (SELECT 1 FROM cerebro_ingesta_perdida WHERE message_id IN (v_rec, v_done, v_old)) THEN
    v_fail := v_fail || ' 4:no-deberia';
  END IF;

  -- Idempotent: the same message is never recorded or alerted twice.
  IF cerebro_vigilar_ingesta() <> 0 THEN
    v_fail := v_fail || ' 5:repite';
  END IF;
  IF (SELECT count(*) FROM cerebro_ingesta_perdida WHERE message_id = v_miss) <> 1 THEN
    v_fail := v_fail || ' 6:duplicado';
  END IF;
  IF (SELECT count(*) FROM message_outbox
       WHERE conversation_id = v_conv AND payload ->> 'text' LIKE 'AVISO INGESTA%') <> 1 THEN
    v_fail := v_fail || ' 7:aviso-duplicado';
  END IF;

  IF (SELECT count(*) FROM cron.job WHERE jobname = 'vigilar-ingesta') <> 1 THEN
    v_fail := v_fail || ' 8:cron';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
