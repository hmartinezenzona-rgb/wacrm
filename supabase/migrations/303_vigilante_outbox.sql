-- =====================================================================
-- 303 -- Outbox health watchdog
--
-- 301/302 made the message.received delivery durable, but the outbox itself had no alarm: if the worker stops
-- draining (wrong outbox_url, rotated notify_secret, panel down) or a row dies at the last attempt, nothing
-- surfaced. This watchdog alerts the admin through the existing message outbox (text only, like 300) when:
--   * a pending row is due and still unclaimed 10 minutes later (the worker is not draining);
--   * a sending row's 2-minute lease expired more than 5 minutes ago (the worker died mid-send);
--   * a row failed in the last hour.
-- One alert per hour per affected conversation (the outbox idempotency key uses the execution id, so a repeated
-- run in the same hour does not duplicate it). The cron runs every 5 minutes.
-- Assertion: supabase/staging/assertions/vigilante-outbox.sql. Rollback: ROLLBACK-303-vigilante-outbox.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_vigilar_outbox()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_admin text;
  v_conv  uuid;
  v_filas integer := 0;
  v_desde timestamptz;
  v_res   record;
BEGIN
  SELECT c.phone INTO v_admin
    FROM contacts c
    JOIN contact_tags ct ON ct.contact_id = c.id
    JOIN tags t ON t.id = ct.tag_id
   WHERE lower(t.name) = 'admin'
   ORDER BY c.created_at
   LIMIT 1;

  SELECT CASE WHEN o.payload->'data'->>'conversation_id' ~ '^[0-9a-f-]{36}$'
              THEN (o.payload->'data'->>'conversation_id')::uuid END,
         count(*),
         min(o.created_at)
    INTO v_conv, v_filas, v_desde
    FROM webhook_outbox o
   WHERE (o.status = 'pending' AND o.next_attempt_at < now() - interval '10 minutes')
      OR (o.status = 'sending' AND o.locked_until < now() - interval '5 minutes')
      OR (o.status = 'failed' AND o.created_at > now() - interval '1 hour')
   GROUP BY 1
   ORDER BY 3
   LIMIT 1;

  IF coalesce(v_filas, 0) = 0 THEN
    RETURN 0;
  END IF;

  IF v_admin IS NULL THEN
    RETURN v_filas;
  END IF;

  -- No conversation in the payload: fall back to the admin's own thread so the alert still goes out.
  IF v_conv IS NULL THEN
    SELECT v.id INTO v_conv
      FROM conversations v
      JOIN contacts c ON c.id = v.contact_id
     WHERE c.phone = v_admin
     ORDER BY v.created_at DESC
     LIMIT 1;
  END IF;
  IF v_conv IS NULL THEN
    RETURN v_filas;
  END IF;

  SELECT * INTO v_res FROM cerebro_outbox_encolar(
    v_conv,
    v_admin,
    'AVISO OUTBOX: la entrega durable al Cerebro no se esta drenando.' || chr(10) || chr(10)
      || 'Filas afectadas: ' || v_filas || chr(10)
      || 'Conversacion afectada: ' || left(v_conv::text, 8) || chr(10)
      || 'Desde (UTC): ' || to_char(v_desde AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || chr(10)
      || 'Revise webhook_outbox y el cron webhook-outbox.',
    NULL,
    'outbox-salud-' || to_char(date_trunc('hour', now()) AT TIME ZONE 'UTC', 'YYYYMMDDHH'));

  RETURN v_filas;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_vigilar_outbox() IS
  'Alerts the admin once per hour per conversation when the durable-delivery outbox is not draining (due rows '
  'unclaimed, expired leases, recent failures). Returns the number of affected rows in the oldest group.';

REVOKE ALL ON FUNCTION public.cerebro_vigilar_outbox() FROM PUBLIC, anon, authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vigilar-outbox'
              AND command IS DISTINCT FROM 'SELECT public.cerebro_vigilar_outbox()') THEN
    PERFORM cron.unschedule('vigilar-outbox');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vigilar-outbox') THEN
    PERFORM cron.schedule('vigilar-outbox', '*/5 * * * *', 'SELECT public.cerebro_vigilar_outbox()');
  END IF;
END;
$cron$;
