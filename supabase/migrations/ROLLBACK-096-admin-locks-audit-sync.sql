-- ROLLBACK for 096_admin_locks_audit_sync.sql
--
-- Drops the two automation guards, the lock-enforcement trigger on
-- remittance_operations, the shared actor helpers, the admin_locked_fields
-- column, and the audit table. Does NOT touch cerebro_sync_operacion_desde_deal
-- (041/043/060), trg_cerrar_deal_entregado (052) or trg_remittance_operations_touch
-- (040) — 096 never modified them.
--
-- Safe to run even if 096 was only partially applied (every DROP is
-- IF EXISTS).

DROP TRIGGER IF EXISTS trg_admin_guard_deals_stage ON deals;
DROP FUNCTION IF EXISTS deals_admin_completion_guard();

DROP TRIGGER IF EXISTS trg_admin_guard_operations_status ON remittance_operations;
DROP FUNCTION IF EXISTS remittance_operations_completion_guard();

DROP TRIGGER IF EXISTS trg_admin_field_locks_operations ON remittance_operations;
DROP FUNCTION IF EXISTS remittance_operations_lock_guard();

DROP FUNCTION IF EXISTS wacrm_current_actor();
DROP FUNCTION IF EXISTS wacrm_is_human_actor(uuid, account_role_enum);

DROP INDEX IF EXISTS remittance_operations_locked_idx;
ALTER TABLE remittance_operations DROP COLUMN IF EXISTS admin_locked_fields;

DROP POLICY IF EXISTS remittance_admin_audit_select ON remittance_admin_audit;
DROP TABLE IF EXISTS remittance_admin_audit;
