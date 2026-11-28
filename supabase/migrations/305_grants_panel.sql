-- =====================================================================
-- 305 -- SELECT grants the panel needs and never had
--
-- The panel talks to Supabase with the service key. service_role bypasses RLS but NOT table privileges, and
-- these tables were created without a SELECT grant for it:
--   * session_events: the outbox dedupe reads it before a retry. Production logged
--     "permission denied for table session_events" on every message, so the check failed open and a retry
--     could duplicate a turn;
--   * promo_etecsa and precio_recarga: /api/promotions/etecsa reads both with the service key, so the Etecsa
--     promotions block failed at the first query.
-- Read-only grants: the panel never writes these tables.
-- Assertion: supabase/staging/assertions/grants-panel.sql. Rollback: ROLLBACK-305-grants-panel.sql.
-- =====================================================================

GRANT SELECT ON TABLE public.session_events TO service_role;
GRANT SELECT ON TABLE public.promo_etecsa TO service_role;
GRANT SELECT ON TABLE public.precio_recarga TO service_role;
