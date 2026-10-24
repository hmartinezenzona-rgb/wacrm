-- ROLLBACK 301: removes the durable-delivery outbox.

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'webhook-outbox') THEN
    PERFORM cron.unschedule('webhook-outbox');
  END IF;
END;
$cron$;

DROP FUNCTION IF EXISTS public.cerebro_webhook_outbox_ping();
DROP FUNCTION IF EXISTS public.cerebro_webhook_outbox_reclamar(integer);
DROP TABLE IF EXISTS public.webhook_outbox;
