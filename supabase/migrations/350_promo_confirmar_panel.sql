-- =====================================================================
-- 350 -- the panel can confirm or discard an Etecsa promo again
--
-- Found 2026-10-28: "Confirmar" in the panel's promo banner failed for promo 6bec68e3. The route
-- /api/promotions/etecsa (POST) updates promo_etecsa with the service key, and service_role only has
-- SELECT on that table (305 assumed "the panel never writes these tables"), so the UPDATE is refused
-- with "permission denied" and the panel shows "No se pudo confirmar la promoción".
-- Column-level UPDATE on exactly the three columns the route writes (estado, confirmada_at,
-- confirmada_por); the promo's figures and dates stay read-only for the service key.
-- Staging had a table-level UPDATE for service_role that production never had (why the 2026-10-04
-- staging test passed): it is revoked first, a no-op on production, so both end the same.
-- Assertion: supabase/staging/assertions/promo-confirmar-panel.sql. Rollback: ROLLBACK-350-promo-confirmar-panel.sql.
-- =====================================================================

REVOKE UPDATE ON TABLE public.promo_etecsa FROM service_role;
GRANT UPDATE (estado, confirmada_at, confirmada_por) ON TABLE public.promo_etecsa TO service_role;
