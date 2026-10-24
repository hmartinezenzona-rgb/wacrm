-- ROLLBACK 312: removes the written-TransID verifier.

DROP FUNCTION IF EXISTS public.cerebro_verificar_transid(text);
