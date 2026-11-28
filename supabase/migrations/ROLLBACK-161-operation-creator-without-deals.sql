-- =====================================================================
-- ROLLBACK-161 — remove cerebro_crear_operacion
--
-- 161 is purely additive: one new function, one REVOKE/GRANT pair, one
-- PostgREST schema reload. Nothing else was created, dropped, redefined
-- or altered, so the rollback is the single DROP below.
--
-- Dropping the function cannot lose data: no table was touched here, and
-- no trigger, view or other function references cerebro_crear_operacion
-- (nothing calls it yet — WU5 is what wires the callers).
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_crear_operacion(uuid, numeric, text, uuid);

NOTIFY pgrst, 'reload schema';
