-- =====================================================================
-- ROLLBACK-123 — reverts 123_add_beneficiary_rpc.sql
--
-- Drops crm_agregar_beneficiario and restores the remittance_admin_audit
-- action CHECK to its exact 098 vocabulary (without human_beneficiary_added).
-- =====================================================================

-- Audit rows using the action this migration introduced would violate the
-- restored CHECK constraint, so they must be deleted first. This is a
-- destructive step: any human_beneficiary_added audit history written
-- while 123 was applied is lost on rollback.
DELETE FROM remittance_admin_audit
 WHERE action = 'human_beneficiary_added';

-- Restores the exact set 104_calculator_ledger_feed.sql left in place
-- immediately before 123 (098/099/101/104's cumulative vocabulary, minus
-- the one action this migration added).
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
    'human_forced_verification',
    'human_delivery',
    'calculator_feed_failed',
    'calculator_pending_resolved'
  ));

DROP FUNCTION IF EXISTS crm_agregar_beneficiario(uuid, jsonb);
