-- 378: an agent creates an operation from scratch from the operations panel (T2 of odd/tasks/panel-fully-editable.md).
--
-- Owner, 2026-11-17: "poder crear desde cero cualquier operacion". Operations were only created by the bot and by developer corrections.
--
-- The new operation is an open one (collecting_information) in the conversation, with the amount the agent typed (GYD). The service is one of
-- the panel's "Servicio" choices and is applied by the same core the panel's "change service" uses (_cambiar_servicio_core): service type,
-- rail, destination currency (a Mexico send pays out in MXN) and the lock of the rail against the bot. Recipients, the deposit and the closing
-- go through the panel's existing functions (crm_agregar_beneficiario, crm_verificar_deposito / crm_forzar_verificacion, ...).
-- An amount greater than 0 is required (a 0 GYD send is a ghost: it made the bot ask for a deposit of someone who had paid), except for a combo,
-- whose total is the sum of its recipients. Audit action human_operation_created keeps the service and the amount.
--
-- The audit table only accepts the actions it lists: add `human_operation_created` (the list of staging after 377).

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
  'human_operation_created'::text
]));

CREATE OR REPLACE FUNCTION public.crm_crear_operacion(p_conversation_id uuid, p_servicio text, p_monto numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_contact_id uuid;
  v_servicio   text := lower(btrim(coalesce(p_servicio, '')));
  v_monto      numeric := p_monto;
  v_op_id      uuid;
BEGIN
  SELECT c.account_id, c.contact_id INTO v_account_id, v_contact_id FROM conversations c WHERE c.id = p_conversation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to create an operation in this conversation' USING ERRCODE = '42501';
  END IF;

  IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo', 'mexico') THEN
    RAISE EXCEPTION 'unknown service: %', p_servicio USING ERRCODE = '22023';
  END IF;

  IF v_servicio = 'combo' THEN
    v_monto := coalesce(v_monto, 0);
    IF v_monto < 0 THEN
      RAISE EXCEPTION 'amount must not be negative' USING ERRCODE = '22023';
    END IF;
  ELSIF v_monto IS NULL OR v_monto <= 0 THEN
    RAISE EXCEPTION 'amount must be greater than 0' USING ERRCODE = '22023';
  END IF;

  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, quoted_source_amount, source_currency)
  VALUES (v_account_id, p_conversation_id, v_contact_id, 'collecting_information', 'remesa', v_monto, 'GYD')
  RETURNING id INTO v_op_id;

  -- The service, applied the way the panel's "change service" applies it.
  PERFORM _cambiar_servicio_core(v_op_id, v_servicio, 'human_correction', wacrm_current_actor(), NULL);

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', v_op_id, 'service,quoted_source_amount', 'human_operation_created',
          wacrm_current_actor(), NULL,
          jsonb_build_object('service', v_servicio, 'quoted_source_amount', v_monto, 'conversation_id', p_conversation_id));

  RETURN jsonb_build_object('id', v_op_id, 'service', v_servicio);
END $function$;

REVOKE ALL ON FUNCTION public.crm_crear_operacion(uuid, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_crear_operacion(uuid, text, numeric) TO authenticated;
