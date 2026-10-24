-- 301: durable-delivery outbox (claim/lease, expiry, cron, ping no-op without outbox_url).
DO $$
DECLARE
  v_acc uuid; v_ep uuid; v_id uuid; v_n integer; v_fail text := '';
BEGIN
  SELECT account_id, id INTO v_acc, v_ep FROM webhook_endpoints LIMIT 1;
  IF v_acc IS NULL THEN
    SELECT account_id INTO v_acc FROM conversations LIMIT 1;
    INSERT INTO webhook_endpoints (account_id, url, secret, events, is_active)
    VALUES (v_acc, 'https://n8n.test/webhook', 'x', ARRAY['message.received'], true)
    RETURNING id INTO v_ep;
  END IF;

  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload)
  VALUES (v_acc, v_ep, 'message.received',
          jsonb_build_object('id', 'prueba-outbox', 'event', 'message.received',
                             'data', jsonb_build_object('whatsapp_message_id', 'prueba-outbox')))
  RETURNING id INTO v_id;

  SELECT count(*) INTO v_n FROM cerebro_webhook_outbox_reclamar(10) WHERE id = v_id;
  IF v_n <> 1 THEN v_fail := v_fail || ' 1:reclamo'; END IF;
  IF (SELECT status FROM webhook_outbox WHERE id = v_id) <> 'sending' THEN
    v_fail := v_fail || ' 2:estado';
  END IF;

  -- The lease holds: a second claim does not take it again.
  SELECT count(*) INTO v_n FROM cerebro_webhook_outbox_reclamar(10) WHERE id = v_id;
  IF v_n <> 0 THEN v_fail := v_fail || ' 3:lease'; END IF;

  -- An expired lease is claimable again.
  UPDATE webhook_outbox SET locked_until = clock_timestamp() - interval '1 minute' WHERE id = v_id;
  SELECT count(*) INTO v_n FROM cerebro_webhook_outbox_reclamar(10) WHERE id = v_id;
  IF v_n <> 1 THEN v_fail := v_fail || ' 4:reexpira'; END IF;

  IF (SELECT count(*) FROM cron.job WHERE jobname = 'webhook-outbox') <> 1 THEN
    v_fail := v_fail || ' 5:cron';
  END IF;

  -- Without outbox_url the ping is a no-op (staging has no panel URL configured here).
  PERFORM cerebro_webhook_outbox_ping();

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
