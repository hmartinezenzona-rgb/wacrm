-- =====================================================================
-- ROLLBACK-163 — remove the reparto + USD-destination node adapters
--
-- 163 is purely additive: two new functions, two REVOKE/GRANT pairs,
-- one PostgREST schema reload. Nothing else was created, dropped,
-- redefined or altered, so the rollback is the two DROPs below.
--
-- Dropping them cannot lose data: no table was touched here, and no
-- trigger, view or other function references either one (nothing calls
-- them yet — WU5 is what wires the callers).
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_registrar_reparto_multiple(uuid, text, text, text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_marcar_destino_usd(uuid, text, text);

NOTIFY pgrst, 'reload schema';
