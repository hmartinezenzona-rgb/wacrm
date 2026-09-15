-- =====================================================================
-- ROLLBACK de 104 — las derivaciones del bot vuelven a no caducar
--
-- No reasigna los chats ya liberados: la foto previa está en
-- ~/backups/wacrm-n8n/snapshot-derivaciones-produccion-<fecha>.json.
-- =====================================================================

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'caducar-derivaciones-atendidas';

DROP FUNCTION IF EXISTS public.cerebro_caducar_derivaciones_atendidas();
DROP FUNCTION IF EXISTS public.cerebro_caducar_derivacion_atendida(uuid);

DELETE FROM public.cerebro_config WHERE clave = 'derivacion_atendida_caduca_minutos';
