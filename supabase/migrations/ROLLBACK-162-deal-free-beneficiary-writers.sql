-- =====================================================================
-- ROLLBACK-162 — remove the four deal-free beneficiary writers
--
-- 162 is purely additive: four new functions, four REVOKE/GRANT pairs,
-- one PostgREST schema reload. Nothing else was created, dropped,
-- redefined or altered, so the rollback is the four DROPs below.
--
-- Dropping them cannot lose data: no table was touched here, and no
-- trigger, view or other function references any of the four (nothing
-- calls them yet — WU5 is what wires the callers).
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_registrar_beneficiario_auto(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_gestionar_beneficiario(uuid, text, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_registrar_zelle_auto(uuid, text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_registrar_beneficiario_zelle(uuid, text, text, text);

NOTIFY pgrst, 'reload schema';
