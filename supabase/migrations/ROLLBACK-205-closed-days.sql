-- ROLLBACK of 205_closed_days.sql. Restore the Cerebro's 'Contexto conversacion', 'Decisor' and 'Agente Remesas' (gate101 backup) first.
DROP FUNCTION IF EXISTS public.cerebro_cierre_especial_info(date);
DROP FUNCTION IF EXISTS public.cerebro_proximo_dia_habil(date);
DROP FUNCTION IF EXISTS public.cerebro_dia_cerrado(date);
DELETE FROM public.cerebro_config WHERE clave = 'dias_cerrados';
