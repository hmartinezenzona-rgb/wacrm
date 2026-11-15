-- Rollback of 374: drops the silent-capture reader. Recipients it already stored stay (they are ordinary Zelle recipients).
-- Remove the n8n node that calls it first.
DROP FUNCTION IF EXISTS public.cerebro_capturar_en_silencio(uuid, text, text, text[], boolean, text);
