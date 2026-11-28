-- ROLLBACK 297: removes the USD -> MXN rate jobs, functions and tables.

DO $cron$
DECLARE
  j text;
BEGIN
  FOREACH j IN ARRAY ARRAY['actualizar-tasa-usd-mxn', 'solicitar-tasa-usd-mxn', 'procesar-tasa-usd-mxn'] LOOP
    IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = j) THEN
      PERFORM cron.unschedule(j);
    END IF;
  END LOOP;
END;
$cron$;

DROP FUNCTION IF EXISTS public.cerebro_tasa_usd_mxn_info();
DROP FUNCTION IF EXISTS public.cerebro_tasa_usd_mxn();
DROP FUNCTION IF EXISTS public.cerebro_tasa_procesar();
DROP FUNCTION IF EXISTS public.cerebro_tasa_solicitar(text, text);
DROP FUNCTION IF EXISTS public.cerebro_registrar_tasa_usd_mxn(numeric, text, jsonb);
DROP FUNCTION IF EXISTS public.cerebro_parsear_tasa_arq(jsonb);
DROP FUNCTION IF EXISTS public.cerebro_parsear_tasa_erapi(jsonb);

-- Transitional revisions of this migration. Dropped only when present.
DO $legacy$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT oid::regprocedure AS sig FROM pg_proc
            WHERE proname IN ('cerebro_net_obtener', 'cerebro_actualizar_tasa_usd_mxn',
                              'cerebro_parsear_tasa_google', 'cerebro_parsear_tasa_yahoo') LOOP
    EXECUTE 'DROP FUNCTION ' || r.sig;
  END LOOP;
END;
$legacy$;

DROP TABLE IF EXISTS public.cerebro_tasas_solicitudes;
DROP TABLE IF EXISTS public.cerebro_tasas_cambio;
