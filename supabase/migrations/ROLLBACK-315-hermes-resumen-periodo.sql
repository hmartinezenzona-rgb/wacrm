-- ROLLBACK 315: removes the Hermes period summary.

DROP FUNCTION IF EXISTS public.hermes_resumen_periodo(timestamptz, timestamptz, integer);
