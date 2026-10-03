-- ROLLBACK of 195_id_name_match.sql. Restore the Cerebro's 'Registrar carnet efectivo' (gate90 backup) first.
DROP FUNCTION IF EXISTS public.cerebro_nombre_coincide(text, text);
DROP FUNCTION IF EXISTS public.cerebro_un_cambio(text, text);
DROP FUNCTION IF EXISTS public.cerebro_palabras_nombre(text);
