-- Rollback of 214: drop the read-only operations board RPC. Nothing else depends on it.
BEGIN;
DROP FUNCTION IF EXISTS public.crm_tablero_operaciones();
DELETE FROM supabase_migrations.schema_migrations WHERE version = '214';
COMMIT;
