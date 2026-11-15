-- ============================================================
-- 311 — Avisos de AP Suministros (va DESPUÉS de 302; NO aplicar en Doña Miriam)
--
-- 302 deja los avisos apuntando a la app de Doña Miriam. Aquí se apuntan
-- a la de AP y el resumen de la noche se cambia por un aviso de
-- seguimiento: lun–vie 9 am Saltillo, cotizaciones enviadas que llevan
-- 3 días o más sin respuesta.
-- ============================================================

CREATE OR REPLACE FUNCTION public._avisar_encargo_nuevo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  PERFORM net.http_post(
    url := 'https://crm-ap-suministros.vercel.app/api/avisos/evento',
    body := jsonb_build_object('tipo', 'nuevo', 'deal_id', NEW.id),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._avisar_encargo_nuevo() FROM PUBLIC, anon, authenticated;

-- 9 am Saltillo (UTC-6) = 15:00 UTC, lunes a viernes.
DO $$
BEGIN
  PERFORM cron.unschedule('dona-miriam-resumen-noche')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'dona-miriam-resumen-noche');
  PERFORM cron.unschedule('ap-seguimiento-cotizaciones')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ap-seguimiento-cotizaciones');
  PERFORM cron.schedule(
    'ap-seguimiento-cotizaciones',
    '0 15 * * 1-5',
    $job$SELECT net.http_post(
      url := 'https://crm-ap-suministros.vercel.app/api/avisos/resumen',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb
    )$job$
  );
END $$;
