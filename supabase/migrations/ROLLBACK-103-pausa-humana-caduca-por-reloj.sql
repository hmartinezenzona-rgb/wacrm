-- =====================================================================
-- ROLLBACK de 103 — la pausa por envío humano deja de caducar por reloj
--
-- La 102 sigue activa: la pausa se quita cuando el cliente escribe. Para
-- deshacer también la 102, ejecutar después ROLLBACK-102 (y antes revertir
-- el nodo `Contexto conversacion`, ver ese fichero).
-- =====================================================================

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'caducar-pausas-humanas';

DROP FUNCTION IF EXISTS public.cerebro_caducar_pausas_humanas();
