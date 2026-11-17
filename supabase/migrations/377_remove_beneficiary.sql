-- 377: an agent removes a current recipient from the operations panel (T1 of odd/tasks/panel-fully-editable.md).
--
-- Owner, 2026-11-17: the panel must let an admin fix data without the developer; adding and editing a recipient existed, removing one did
-- not (Elisvan, conversation 78e3540b: a send left with recipients that had to be cleaned by hand).
--
-- Same conventions as crm_corregir_beneficiario: the account membership check, the refusal of closed operations, the row kept as
-- 'reemplazado' with replaced_at (history), the lock of the operation's recipients against automation (admin_locked_fields) and one audit
-- row. The audit row keeps the removed data in `before`. A combo's total is the sum of its vigente recipients, so it is recomputed.
-- Removing the last recipient is allowed: the operation stays open and crm_beneficiarios_completos turns false.

-- The audit table only accepts the actions it lists: add `human_beneficiary_removed` (same list as production plus the new action).
ALTER TABLE public.remittance_admin_audit DROP CONSTRAINT IF EXISTS remittance_admin_audit_action_chk;
ALTER TABLE public.remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed'::text,
  'automation_completion_suppressed'::text,
  'automation_revert_suppressed'::text,
  'human_correction'::text,
  'human_reassignment'::text,
  'human_deposit_verification'::text,
  'human_forced_verification'::text,
  'human_delivery'::text,
  'calculator_feed_failed'::text,
  'calculator_pending_resolved'::text,
  'human_beneficiary_added'::text,
  'automation_reparto_registered'::text,
  'human_calculator_correction'::text,
  'automation_cash_delivery_data_registered'::text,
  'automation_late_deposit_verification'::text,
  'human_manual_close'::text,
  'human_operation_deleted'::text,
  'automation_recharge_numbers_registered'::text,
  'automation_combo_recipient_registered'::text,
  'human_combo_cost_set'::text,
  'automation_visa_registered'::text,
  'human_calculator_entry_deleted'::text,
  'human_calculator_manual_added'::text,
  'automation_service_change'::text,
  'automation_mixed_split'::text,
  'agent_service_change'::text,
  'agent_mexico_recipient_registered'::text,
  'agent_amount_change'::text,
  'agent_operation_cancel'::text,
  'agent_operation_merge'::text,
  'agent_recharge_number_removed'::text,
  'agent_beneficiary_corrected'::text,
  'agent_deposit_move'::text,
  'human_beneficiary_removed'::text
]));

CREATE OR REPLACE FUNCTION public.crm_quitar_beneficiario(p_beneficiary_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old        remittance_beneficiaries%ROWTYPE;
  v_account_id uuid;
  v_op_status  text;
  v_service    text;
BEGIN
  SELECT * INTO v_old FROM remittance_beneficiaries WHERE id = p_beneficiary_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'beneficiary not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_old.status <> 'vigente' THEN
    RAISE EXCEPTION 'beneficiary is not current' USING ERRCODE = '22023';
  END IF;

  SELECT account_id, status, service_type INTO v_account_id, v_op_status, v_service
    FROM remittance_operations WHERE id = v_old.operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to remove this beneficiary' USING ERRCODE = '42501';
  END IF;
  IF v_op_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = now()
   WHERE id = p_beneficiary_id;

  -- A combo's total is the sum of its recipients' amounts.
  IF v_service = 'combo' THEN
    UPDATE remittance_operations o
       SET quoted_source_amount = (SELECT coalesce(sum(b.amount), 0) FROM remittance_beneficiaries b
                                    WHERE b.operation_id = o.id AND b.status = 'vigente' AND b.beneficiary_type = 'combo')
     WHERE o.id = v_old.operation_id;
  END IF;

  -- Lock the recipients of this operation so automation does not bring the removed one back.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields ||
         jsonb_build_object('beneficiaries', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = v_old.operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_beneficiaries', p_beneficiary_id, 'status', 'human_beneficiary_removed',
          wacrm_current_actor(),
          jsonb_strip_nulls(jsonb_build_object(
            'beneficiary_type', v_old.beneficiary_type, 'name', v_old.name, 'card_number', v_old.card_number, 'phone', v_old.phone,
            'zelle_account', v_old.zelle_account, 'delivery_method', v_old.delivery_method, 'amount', v_old.amount,
            'currency', v_old.currency, 'position', v_old.position, 'address', v_old.address, 'reference', v_old.reference,
            'contact_phone', v_old.contact_phone, 'clabe', v_old.clabe, 'bank_name', v_old.bank_name, 'status', v_old.status)),
          jsonb_build_object('status', 'reemplazado'));

  RETURN jsonb_build_object('id', p_beneficiary_id, 'complete', crm_beneficiarios_completos(v_old.operation_id));
END $function$;

REVOKE ALL ON FUNCTION public.crm_quitar_beneficiario(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_quitar_beneficiario(uuid) TO authenticated;
