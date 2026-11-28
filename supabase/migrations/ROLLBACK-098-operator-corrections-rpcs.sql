-- =====================================================================
-- ROLLBACK-098 — reverts 098_operator_corrections_rpcs.sql
--
-- Drops the operator correction/reassignment RPCs, restores
-- cerebro_sync_beneficiarios to its exact 042 body (no lock-suppression
-- branch), and restores the remittance_admin_audit action CHECK to its
-- original 3 actions.
-- =====================================================================

-- Audit rows using the two actions this migration introduced would violate
-- the restored CHECK constraint, so they must be deleted first. This is a
-- destructive step: any human_correction/human_reassignment audit history
-- written while 098 was applied is lost on rollback.
DELETE FROM remittance_admin_audit
 WHERE action IN ('human_correction', 'human_reassignment');

ALTER TABLE remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit
  ADD CONSTRAINT remittance_admin_audit_action_chk
  CHECK (action IN (
    'automation_write_suppressed',
    'automation_completion_suppressed',
    'automation_revert_suppressed'
  ));

DROP FUNCTION IF EXISTS crm_corregir_operacion(uuid, jsonb);
DROP FUNCTION IF EXISTS crm_corregir_beneficiario(uuid, jsonb);
DROP FUNCTION IF EXISTS crm_reasignar_beneficiario(uuid, uuid);

-- Restore cerebro_sync_beneficiarios to the exact 042 body.
CREATE OR REPLACE FUNCTION cerebro_sync_beneficiarios(p_deal_id uuid)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_op uuid; v_notes text; v_max int; v_nuevos int := 0;
BEGIN
  SELECT o.id, d.notes INTO v_op, v_notes
    FROM deals d JOIN remittance_operations o ON o.deal_id = d.id
   WHERE d.id = p_deal_id;

  IF v_op IS NULL THEN RETURN 0; END IF;

  WITH p AS (SELECT * FROM cerebro_parsear_beneficiarios(v_notes))
  INSERT INTO remittance_beneficiaries (
    operation_id, beneficiary_type, name, card_number, phone,
    zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular,
         p.cuenta_zelle, p.monto, p.moneda, p.posicion, p.block_index,
         'notes_parse', 'vigente'
    FROM p
  ON CONFLICT (operation_id, block_index, position) DO NOTHING;

  GET DIAGNOSTICS v_nuevos = ROW_COUNT;

  SELECT max(block_index) INTO v_max
    FROM remittance_beneficiaries WHERE operation_id = v_op;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_max AND status <> 'reemplazado';

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_max AND status <> 'vigente';

  RETURN v_nuevos;
END $$;
