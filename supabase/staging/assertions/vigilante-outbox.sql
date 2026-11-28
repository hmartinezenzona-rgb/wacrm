-- 303: the outbox watchdog alerts the admin about a stalled outbox, once per hour per conversation.
DO $$
DECLARE
  v_acc uuid; v_user uuid; v_conv uuid; v_admin uuid; v_ep uuid;
  v_admin_tag constant uuid := 'aaa95c92-63a4-4bc1-a300-1cca6d87c072';
  v_wamid text := 'prueba-outbox-salud-' || gen_random_uuid();
  v_n integer;
  v_fail text := '';
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc FROM profiles p ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT c.id INTO v_conv FROM conversations c LIMIT 1;
  SELECT id INTO v_ep FROM webhook_endpoints LIMIT 1;
  IF v_ep IS NULL THEN
    INSERT INTO webhook_endpoints (account_id, url, secret, events, is_active)
    VALUES (v_acc, 'https://n8n.test/webhook', 'x', ARRAY['message.received'], true)
    RETURNING id INTO v_ep;
  END IF;

  INSERT INTO contacts (user_id, phone, name, account_id)
  VALUES (v_user, '5990299998', 'PRUEBA outbox admin', v_acc) RETURNING id INTO v_admin;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_admin, v_admin_tag);

  -- Healthy rows: not due yet, and a fresh failure outside the window.
  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload, status, next_attempt_at)
  VALUES (v_acc, v_ep, 'message.received',
          jsonb_build_object('data', jsonb_build_object('conversation_id', v_conv, 'whatsapp_message_id', v_wamid || '-ok')),
          'pending', now() + interval '5 minutes');
  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload, status, created_at)
  VALUES (v_acc, v_ep, 'message.received',
          jsonb_build_object('data', jsonb_build_object('conversation_id', v_conv, 'whatsapp_message_id', v_wamid || '-old')),
          'failed', now() - interval '3 hours');

  -- Stuck rows: one due and never claimed, one with an expired lease.
  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload, status, next_attempt_at)
  VALUES (v_acc, v_ep, 'message.received',
          jsonb_build_object('data', jsonb_build_object('conversation_id', v_conv, 'whatsapp_message_id', v_wamid)),
          'pending', now() - interval '20 minutes');
  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload, status, locked_until)
  VALUES (v_acc, v_ep, 'message.received',
          jsonb_build_object('data', jsonb_build_object('conversation_id', v_conv, 'whatsapp_message_id', v_wamid || '-lease')),
          'sending', now() - interval '15 minutes');

  v_n := cerebro_vigilar_outbox();

  IF v_n <> 2 THEN v_fail := v_fail || ' 1:conteo=' || v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM message_outbox
                  WHERE conversation_id = v_conv AND telefono_e164 = '5990299998'
                    AND payload ->> 'text' LIKE 'AVISO OUTBOX%') THEN
    v_fail := v_fail || ' 2:sin-aviso';
  END IF;

  -- The same hour does not duplicate the alert.
  PERFORM cerebro_vigilar_outbox();
  IF (SELECT count(*) FROM message_outbox
       WHERE conversation_id = v_conv AND payload ->> 'text' LIKE 'AVISO OUTBOX%') <> 1 THEN
    v_fail := v_fail || ' 3:aviso-duplicado';
  END IF;

  IF (SELECT count(*) FROM cron.job WHERE jobname = 'vigilar-outbox') <> 1 THEN
    v_fail := v_fail || ' 4:cron';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
