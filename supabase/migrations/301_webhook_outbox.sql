-- =====================================================================
-- 301 -- Durable delivery of message.received (the bot ingestion)
--
-- The CRM's delivery to n8n is in-process: when the 3 attempts fail the event is lost (2026-10-24: the owner's
-- "Hola"; the logs show 103 timeouts and 5 give-ups). This adds an outbox for message.received only:
--   * dispatchWebhookEvent stores one row per endpoint before sending and tries once inline; a failure stays pending;
--   * a pg_cron job calls /api/cron/webhook-outbox every minute (the app signs each attempt and checks that the wamid
--     has no session_event before retrying, so a retry cannot duplicate a turn the Cerebro already processed);
--   * sent/skipped rows are purged by the worker after 7 days.
-- The pg_cron job is a no-op until cerebro_config 'outbox_url' points at the panel of this environment.
-- Assertion: supabase/staging/assertions/webhook-outbox.sql. Rollback: ROLLBACK-301-webhook-outbox.sql.
-- =====================================================================

CREATE TABLE IF NOT EXISTS public.webhook_outbox (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id      uuid NOT NULL,
  endpoint_id     uuid NOT NULL REFERENCES public.webhook_endpoints(id) ON DELETE CASCADE,
  event           text NOT NULL,
  payload         jsonb NOT NULL,
  status          text NOT NULL DEFAULT 'pending',
  attempts        integer NOT NULL DEFAULT 0,
  next_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  locked_until    timestamptz,
  last_error      text,
  created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
  sent_at         timestamptz,
  CONSTRAINT webhook_outbox_status_chk CHECK (status IN ('pending', 'sending', 'sent', 'skipped', 'failed'))
);

CREATE INDEX IF NOT EXISTS webhook_outbox_due_idx
  ON public.webhook_outbox (status, next_attempt_at);
CREATE INDEX IF NOT EXISTS webhook_outbox_sent_idx
  ON public.webhook_outbox (sent_at) WHERE status IN ('sent', 'skipped');

COMMENT ON TABLE public.webhook_outbox IS
  'Durable deliveries for message.received: one row per endpoint, written before the first attempt. A failed '
  'attempt stays pending and the cron worker retries with backoff; a wamid that already has a session_event is '
  'skipped so a retry cannot duplicate a turn.';

REVOKE ALL ON TABLE public.webhook_outbox FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.cerebro_webhook_outbox_reclamar(p_limit integer DEFAULT 20)
RETURNS SETOF public.webhook_outbox
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $function$
  UPDATE public.webhook_outbox o
     SET status = 'sending',
         locked_until = clock_timestamp() + interval '2 minutes'
   WHERE o.id IN (
           SELECT w.id
             FROM public.webhook_outbox w
            WHERE w.next_attempt_at <= clock_timestamp()
              AND (w.status = 'pending' OR (w.status = 'sending' AND w.locked_until < clock_timestamp()))
            ORDER BY w.next_attempt_at
            LIMIT p_limit
              FOR UPDATE SKIP LOCKED)
  RETURNING o.*;
$function$;

COMMENT ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) IS
  'Claims due outbox rows (pending, or a sending row whose 2-minute lease expired) and leases them to the worker.';

REVOKE ALL ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) TO service_role;

-- Calls the panel worker. No-op until outbox_url is configured for the environment.
CREATE OR REPLACE FUNCTION public.cerebro_webhook_outbox_ping()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net
AS $function$
DECLARE
  v_url     text := nullif(cerebro_config_get('outbox_url'), '');
  v_secreto text := nullif(cerebro_config_get('notify_secret'), '');
BEGIN
  IF v_url IS NULL OR v_secreto IS NULL THEN
    RETURN;
  END IF;
  PERFORM net.http_post(
    url := rtrim(v_url, '/') || '/api/cron/webhook-outbox',
    body := '{}'::jsonb,
    headers := jsonb_build_object('x-cerebro-secret', v_secreto),
    timeout_milliseconds := 10000);
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_webhook_outbox_ping() FROM PUBLIC, anon, authenticated;

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'webhook-outbox'
              AND command IS DISTINCT FROM 'SELECT public.cerebro_webhook_outbox_ping()') THEN
    PERFORM cron.unschedule('webhook-outbox');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'webhook-outbox') THEN
    PERFORM cron.schedule('webhook-outbox', '* * * * *', 'SELECT public.cerebro_webhook_outbox_ping()');
  END IF;
END;
$cron$;
