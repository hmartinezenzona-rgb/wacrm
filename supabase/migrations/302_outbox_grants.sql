-- =====================================================================
-- 302 -- DML grants for the durable-delivery outbox
--
-- 301 created webhook_outbox and revoked it from PUBLIC/anon/authenticated, but the project's default
-- privileges do not grant DML to service_role on new tables: production returned
-- "permission denied for table webhook_outbox" (2026-10-24 17:41:48Z), the enqueue failed and the webhook
-- route fell back to the in-process delivery. The outbox needs service_role because the panel writes,
-- leases, updates and purges rows with the service key; browser roles keep no access.
-- Assertion: supabase/staging/assertions/outbox-grants.sql. Rollback: ROLLBACK-302-outbox-grants.sql.
-- =====================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.webhook_outbox TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_webhook_outbox_reclamar(integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_webhook_outbox_ping() TO service_role;
