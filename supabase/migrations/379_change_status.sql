-- 379: an agent moves an open operation between open states from the operations panel (T4 of odd/tasks/panel-fully-editable.md).
--
-- Verify (crm_verificar_deposito) and force-verify (crm_forzar_verificacion) only work from `deposit_verification` or `incident`, so an
-- operation created from scratch (378, it starts in `collecting_information`) could not be verified from the panel, and a wrong verification
-- could not be taken back. 11 of the developer's audited corrections of 2026-10-03..11-13 were status changes.
--
-- Targets: collecting_information, awaiting_deposit, deposit_verification, ready_to_transfer, from any OPEN state (a closed operation keeps its
-- own actions). Leaving an incident clears its reason. The same state is a no-op. The customer notice of the new state is muted unless the
-- agent asks for it and the target is ready_to_transfer: then the notifier needs to see a person verified, so a `human_forced_verification`
-- audit row (reason "estado cambiado desde el panel") is written as well. Audit action human_status_change keeps before and after.
--
-- The audit table only accepts the actions it lists: add `human_status_change` (the list of staging after 378).

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
  'human_beneficiary_removed'::text,
  'human_operation_created'::text,
  'human_status_change'::text
]));

CREATE OR REPLACE FUNCTION public.crm_cambiar_estado(p_operation_id uuid, p_estado text, p_notify boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_status     text;
  v_estado     text := lower(btrim(coalesce(p_estado, '')));
  v_avisa      boolean;
BEGIN
  SELECT account_id, status INTO v_account_id, v_status FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to change the state of this operation' USING ERRCODE = '42501';
  END IF;
  IF v_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;
  IF v_estado NOT IN ('collecting_information', 'awaiting_deposit', 'deposit_verification', 'ready_to_transfer') THEN
    RAISE EXCEPTION 'state not allowed: %', p_estado USING ERRCODE = '22023';
  END IF;
  IF v_status = v_estado THEN
    RETURN jsonb_build_object('operation_id', p_operation_id, 'changed', false, 'new_status', v_status);
  END IF;

  v_avisa := coalesce(p_notify, false) AND v_estado = 'ready_to_transfer';

  UPDATE remittance_operations
     SET status = v_estado,
         incident_reason = CASE WHEN v_status = 'incident' THEN NULL ELSE incident_reason END,
         customer_notice_muted_for = CASE WHEN v_avisa THEN NULL ELSE v_estado END
   WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_status_change', wacrm_current_actor(),
          jsonb_build_object('status', v_status), jsonb_build_object('status', v_estado));

  IF v_avisa THEN
    -- The notifier speaks about a deposit only when a person verified it from the panel.
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_forced_verification', wacrm_current_actor(),
            'estado cambiado desde el panel', jsonb_build_object('status', v_status), jsonb_build_object('status', v_estado));
  END IF;

  RETURN jsonb_build_object('operation_id', p_operation_id, 'changed', true, 'previous', v_status, 'new_status', v_estado);
END $function$;

REVOKE ALL ON FUNCTION public.crm_cambiar_estado(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cambiar_estado(uuid, text, boolean) TO authenticated;
