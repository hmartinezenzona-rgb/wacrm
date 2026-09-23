-- =====================================================================
-- ROLLBACK-099 — reverts 099_deposit_review_rpcs.sql
--
-- Drops the deposit review RPCs and restores the remittance_admin_audit
-- action CHECK to its 098 list.
-- =====================================================================

-- Audit rows using the two actions this migration introduced would violate
-- the restored CHECK constraint, so they must be deleted first. This is a
-- destructive step: any human_deposit_verification/human_forced_verification
-- audit history written while 099 was applied is lost on rollback.
DELETE FROM remittance_admin_audit
 WHERE action IN ('human_deposit_verification', 'human_forced_verification');

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed',
    'human_correction',
    'human_reassignment'
  ));

DROP FUNCTION IF EXISTS crm_comprobantes_de_operacion(uuid);
DROP FUNCTION IF EXISTS crm_verificar_deposito(uuid, jsonb);
DROP FUNCTION IF EXISTS crm_forzar_verificacion(uuid, text);
