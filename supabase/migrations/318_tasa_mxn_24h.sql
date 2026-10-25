-- =====================================================================
-- 318 -- The USD-MXN rate updates around the clock
--
-- Owner 2026-10-25: "que corra de noche también, así sale fresca la tasa al
-- empezar el negocio". 297 scheduled both steps only from 12:00 to 22:00 UTC
-- (08:00-18:00 Guyana), so the first quote of the morning could be 13 hours old.
--
-- The two steps keep their 30-minute rhythm and their 2-minute gap:
--   solicitar-tasa-usd-mxn  */30 * * * *     (queue the ARQ + erapi GETs)
--   procesar-tasa-usd-mxn   2,32 * * * *     (parse what arrived a moment ago)
-- Commands are unchanged; only the schedule moves. Nothing else is touched.
--
-- Assertion: supabase/staging/assertions/tasa-mxn-24h.sql.
-- Rollback: ROLLBACK-318-tasa-mxn-24h.sql (back to 12-22 UTC).
-- =====================================================================

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

  PERFORM cron.schedule('solicitar-tasa-usd-mxn', '*/30 * * * *', v_solicitar);
  PERFORM cron.schedule('procesar-tasa-usd-mxn', '2,32 * * * *', v_procesar);
END;
$cron$;
