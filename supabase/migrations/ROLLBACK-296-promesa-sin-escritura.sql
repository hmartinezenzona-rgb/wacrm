-- ROLLBACK 296: removes the promise-without-write guard (trigger, functions and audit table).

DROP TRIGGER IF EXISTS zzz_messages_promesa_sin_escritura ON public.messages;
DROP FUNCTION IF EXISTS public.cerebro_promesa_sin_escritura_guardar();
DROP FUNCTION IF EXISTS public.cerebro_texto_promete(text);
DROP TABLE IF EXISTS public.cerebro_promesas_sin_escritura;
