-- ROLLBACK 316: drop the Hermes reconciliation query.
DROP FUNCTION IF EXISTS public.hermes_cuadre_finanzas(date, date);
