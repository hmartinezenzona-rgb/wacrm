-- ROLLBACK 318: back to the business-hours schedule of 297.
DO $cron$
DECLARE
  v_solicitar text := 'SELECT public.cerebro_tasa_solicitar()';
  v_procesar  text := 'SELECT public.cerebro_tasa_procesar()';
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'solicitar-tasa-usd-mxn') THEN
    PERFORM cron.unschedule('solicitar-tasa-usd-mxn');
  END IF;
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'procesar-tasa-usd-mxn') THEN
    PERFORM cron.unschedule('procesar-tasa-usd-mxn');
  END IF;
  PERFORM cron.schedule('solicitar-tasa-usd-mxn', '*/30 12-22 * * *', v_solicitar);
  PERFORM cron.schedule('procesar-tasa-usd-mxn', '2,32 12-22 * * *', v_procesar);
END;
$cron$;
