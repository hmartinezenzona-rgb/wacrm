-- ROLLBACK 309: removes the WhatsApp rate writer.

DROP FUNCTION IF EXISTS public.cerebro_tasa_whatsapp(text, numeric);
