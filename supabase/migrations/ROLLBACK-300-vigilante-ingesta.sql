-- ROLLBACK 300: removes the ingestion watchdog.

DO $cron$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'vigilar-ingesta') THEN
    PERFORM cron.unschedule('vigilar-ingesta');
  END IF;
END;
$cron$;

DROP FUNCTION IF EXISTS public.cerebro_vigilar_ingesta();
DROP TABLE IF EXISTS public.cerebro_ingesta_perdida;
