-- ROLLBACK 303: removes the outbox health watchdog.

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vigilar-outbox') THEN
    PERFORM cron.unschedule('vigilar-outbox');
  END IF;
END;
$cron$;

DROP FUNCTION IF EXISTS public.cerebro_vigilar_outbox();
