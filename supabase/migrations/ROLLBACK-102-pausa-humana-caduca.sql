-- =====================================================================
-- ROLLBACK de 102 — la pausa por envío humano vuelve a no caducar
--
-- ANTES de ejecutarlo, devolver el nodo `Contexto conversacion` del Cerebro
-- a su versión previa: si el nodo sigue llamando a la función, el Cerebro
-- falla en cada turno.
--   python3 pruebas/desplegar-pausa-humana.py produccion \
--     --revertir ~/backups/wacrm-n8n/ROLLBACK-v2-antes-pausa-humana-caduca-produccion-<fecha>.json
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_caducar_pausa_humana(uuid);

DELETE FROM public.cerebro_config WHERE clave = 'pausa_humana_caduca_minutos';
