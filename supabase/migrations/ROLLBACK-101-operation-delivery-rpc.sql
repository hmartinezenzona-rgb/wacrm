-- =====================================================================
-- ROLLBACK-101 — reverts 101_operation_delivery_rpc.sql
--
-- Drops the operation delivery RPC, restores the remittance_admin_audit
-- action CHECK to its 099/100 list, and drops the delivery evidence
-- columns.
-- =====================================================================

-- Audit rows using the action this migration introduced would violate
-- the restored CHECK constraint, so they must be deleted first. This is
-- a destructive step: any human_delivery audit history written while
-- 101 was applied is lost on rollback.
DELETE FROM remittance_admin_audit WHERE action = 'human_delivery';

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment',
    'human_deposit_verification',
    'human_forced_verification'
  ));

DROP FUNCTION IF EXISTS crm_entregar_operacion(uuid, jsonb);

ALTER TABLE remittance_operations
  DROP COLUMN IF EXISTS delivery_mode,
  DROP COLUMN IF EXISTS delivery_proof_wamid,
  DROP COLUMN IF EXISTS delivery_proof_path,
  DROP COLUMN IF EXISTS delivered_by;
