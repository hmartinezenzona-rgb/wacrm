-- ROLLBACK of 187_panel_quote.sql: the panel can no longer read the bot's current quote.
DROP FUNCTION IF EXISTS public.crm_cotizacion_de_conversacion(uuid);
