-- ROLLBACK 153 — remove the last-quote record. Run AFTER reverting the n8n
-- quote tools and `Contexto conversacion` to their pre-153 versions, or the
-- tools will fail calling a missing function.
DROP FUNCTION IF EXISTS cerebro_monto_recibe(uuid);
DROP FUNCTION IF EXISTS cerebro_registrar_cotizacion(uuid, numeric, numeric, text, text);
DROP TABLE IF EXISTS cerebro_ultima_cotizacion;
