-- ROLLBACK for 397_reseller_totals.sql.
--
-- Drops the five RPCs, the period helper, the append-only trigger function,
-- both ledger tables and the operations index added by the migration.
--
-- WARNING: dropping reseller_counter_resets and reseller_total_adjustments
-- destroys every reset marker and every manual adjustment (both are
-- append-only history). Export both tables FIRST if that history must be kept:
--   \copy (SELECT * FROM public.reseller_counter_resets)      TO 'reseller_counter_resets.csv' CSV HEADER
--   \copy (SELECT * FROM public.reseller_total_adjustments)   TO 'reseller_total_adjustments.csv' CSV HEADER
--
-- Every remittance_operations row is untouched: the migration only read that
-- table and added an index to it. remittance_admin_audit rows written by the
-- RPCs stay; ROLLBACK-395 restores the previous action list NOT VALID.

DROP FUNCTION IF EXISTS public.crm_revendedores_reiniciar_todos(uuid, text, numeric);
DROP FUNCTION IF EXISTS public.crm_revendedor_reiniciar(uuid, text, numeric);
DROP FUNCTION IF EXISTS public.crm_revendedor_ajustar(uuid, numeric, text);
DROP FUNCTION IF EXISTS public.crm_revendedor_detalle(uuid);
DROP FUNCTION IF EXISTS public.crm_revendedores_resumen(uuid);

DROP FUNCTION IF EXISTS public._reseller_period_totals(uuid, uuid, timestamptz, timestamptz);

-- The triggers are dropped with their tables; the function is shared.
DROP TABLE IF EXISTS public.reseller_total_adjustments;
DROP TABLE IF EXISTS public.reseller_counter_resets;

DROP FUNCTION IF EXISTS public.reseller_ledger_no_update();

DROP INDEX IF EXISTS public.remittance_operations_contact_created_idx;

NOTIFY pgrst, 'reload schema';
