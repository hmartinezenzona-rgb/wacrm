-- ROLLBACK 281: drop the general operation tool and its helpers.
DROP FUNCTION IF EXISTS public.cerebro_modificar_operacion(uuid, uuid, text, jsonb, text);
DROP FUNCTION IF EXISTS public._cerebro_nombre_servicio(text);
DROP FUNCTION IF EXISTS public._cerebro_op_tiene_dinero(uuid);
-- audit action list as before 281 (rows written by the tool must be gone or renamed first)
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
  'agent_mexico_recipient_registered'::text]));
