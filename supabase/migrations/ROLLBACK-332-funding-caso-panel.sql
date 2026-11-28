-- ROLLBACK of 332: drops the two panel RPCs. No data is written by this migration.
-- =====================================================================

DROP FUNCTION IF EXISTS public.funding_caso_resolver_panel(uuid);
DROP FUNCTION IF EXISTS public.funding_caso_panel(uuid);
