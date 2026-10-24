-- 304: the claim takes message.received before an older status update.
DO $$
DECLARE
  v_acc uuid; v_ep uuid; v_estado uuid; v_mensaje uuid; v_ids uuid[];
  v_fail text := '';
BEGIN
  SELECT account_id, id INTO v_acc, v_ep FROM webhook_endpoints LIMIT 1;
  IF v_ep IS NULL THEN
    SELECT account_id INTO v_acc FROM conversations LIMIT 1;
    INSERT INTO webhook_endpoints (account_id, url, secret, events, is_active)
    VALUES (v_acc, 'https://n8n.test/webhook', 'x', ARRAY['message.received'], true)
    RETURNING id INTO v_ep;
  END IF;

  -- Only the rows this assertion creates may be claimable.
  UPDATE webhook_outbox SET status = 'skipped', sent_at = clock_timestamp()
   WHERE status IN ('pending', 'sending');

  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload, next_attempt_at)
  VALUES (v_acc, v_ep, 'message.status_updated',
          jsonb_build_object('data', jsonb_build_object('whatsapp_message_id', 'prueba-prio-estado')),
          clock_timestamp() - interval '2 minutes')
  RETURNING id INTO v_estado;

  INSERT INTO webhook_outbox (account_id, endpoint_id, event, payload, next_attempt_at)
  VALUES (v_acc, v_ep, 'message.received',
          jsonb_build_object('data', jsonb_build_object('whatsapp_message_id', 'prueba-prio-mensaje')),
          clock_timestamp() - interval '1 minute')
  RETURNING id INTO v_mensaje;

  SELECT array_agg(id) INTO v_ids FROM cerebro_webhook_outbox_reclamar(1);

  IF v_ids IS DISTINCT FROM ARRAY[v_mensaje] THEN
    v_fail := v_fail || ' 1:prioridad=' || coalesce(v_ids::text, 'null');
  END IF;

  -- The status row is still claimable afterwards, not lost.
  IF NOT EXISTS (SELECT 1 FROM cerebro_webhook_outbox_reclamar(10) WHERE id = v_estado) THEN
    v_fail := v_fail || ' 2:estado-perdido';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
