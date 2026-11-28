-- 381: an agent releases a verified deposit from an operation, or moves it to another open operation of the same conversation, from the
-- operations panel (T3c of odd/tasks/panel-fully-editable.md).
--
-- 36 of the developer's 298 audited corrections of 2026-10-03..11-13 were deposit <-> operation links. The bot already moves a deposit when the
-- customer confirms (cerebro_modificar_operacion, 'mover_deposito', audit agent_deposit_move); the panel had no way.
--
-- The deposit moves WHOLE (one ledger row). Release: the deposit is free again (operation and consumption cleared, its funding-case link
-- removed, so crm_depositos_sin_dueno lists it). Move: it belongs to the target (same conversation, open, not part of a mixed send); its receipts
-- of that reference follow it. The target becomes ready_to_transfer when its deposits cover its request (an empty request becomes the deposit) or
-- stays in deposit_verification. The source goes back to awaiting_deposit when that was its only money, or from ready_to_transfer to
-- deposit_verification when what is left does not cover it. The open objective of the bot follows the deposit to the target. The customer notice of
-- every new state is muted (the person tells the customer). Audit: human_deposit_release on the source, human_deposit_move on both.
--
-- The audit table only accepts the actions it lists: add the two new ones (the list of staging after 379).

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
  'human_status_change'::text,
  'human_deposit_move'::text,
  'human_deposit_release'::text
]));

CREATE OR REPLACE FUNCTION public.crm_mover_deposito(p_operation_id uuid, p_trans_id text, p_destino uuid DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_dp     depositos_mmg%ROWTYPE;
  v_o      remittance_operations%ROWTYPE;
  v_x      remittance_operations%ROWTYPE;
  v_trans  text := btrim(coalesce(p_trans_id, ''));
  v_digits text;
  v_rest   numeric;
  v_tdep   numeric;
  v_q      numeric;
  v_new_o  text;
  v_new_x  text;
BEGIN
  SELECT * INTO v_dp FROM depositos_mmg WHERE trans_id = v_trans FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'deposit not found' USING ERRCODE = 'P0002';
  END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_o.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to move deposits of this operation' USING ERRCODE = '42501';
  END IF;
  IF v_dp.operation_id IS DISTINCT FROM p_operation_id OR v_dp.consumido_en IS NULL OR v_dp.anulado_en IS NOT NULL OR v_dp.descartado_en IS NOT NULL THEN
    RAISE EXCEPTION 'the deposit is not a verified deposit of this operation' USING ERRCODE = '22023';
  END IF;
  IF v_o.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;
  IF v_o.mixed_group_id IS NOT NULL THEN
    RAISE EXCEPTION 'the operation is part of a mixed send: its deposit is not moved from here' USING ERRCODE = '22023';
  END IF;

  IF p_destino IS NOT NULL THEN
    IF p_destino = p_operation_id THEN
      RAISE EXCEPTION 'the target is the same operation' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_x FROM remittance_operations WHERE id = p_destino AND conversation_id = v_o.conversation_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'the target must be an operation of the same conversation' USING ERRCODE = '22023';
    END IF;
    IF v_x.status IN ('completed', 'cancelled') THEN
      RAISE EXCEPTION 'the target operation is closed' USING ERRCODE = '22023';
    END IF;
    IF v_x.mixed_group_id IS NOT NULL THEN
      RAISE EXCEPTION 'the target is part of a mixed send: its deposit is not moved from here' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_destino IS NULL THEN
    UPDATE depositos_mmg SET operation_id = NULL, consumido_en = NULL, deal_id = NULL WHERE trans_id = v_dp.trans_id;
    DELETE FROM case_deposits WHERE deposit_trans_id = v_dp.trans_id;
  ELSE
    UPDATE depositos_mmg SET operation_id = v_x.id, deal_id = NULL WHERE trans_id = v_dp.trans_id;
    v_digits := regexp_replace(v_dp.trans_id, '[^0-9]', '', 'g');
    IF v_digits <> '' THEN
      UPDATE remittance_operation_receipts r SET operation_id = v_x.id
       WHERE r.operation_id = v_o.id AND r.reference ~ ('(^|[^0-9])' || v_digits || '([^0-9]|$)')
         AND NOT EXISTS (SELECT 1 FROM remittance_operation_receipts t WHERE t.operation_id = v_x.id AND t.comp_id IS NOT DISTINCT FROM r.comp_id AND r.comp_id IS NOT NULL);
    END IF;
  END IF;

  -- The source: what is left of its money.
  SELECT coalesce(sum(d.monto), 0) INTO v_rest FROM depositos_mmg d
   WHERE d.operation_id = v_o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL;
  v_new_o := CASE WHEN v_rest = 0 THEN 'awaiting_deposit'
                  WHEN v_rest < coalesce(v_o.quoted_source_amount, 0) AND v_o.status = 'ready_to_transfer' THEN 'deposit_verification'
                  ELSE v_o.status END;
  UPDATE remittance_operations
     SET status = v_new_o,
         incident_reason = CASE WHEN v_rest = 0 THEN NULL ELSE incident_reason END,
         customer_notice_muted_for = CASE WHEN v_new_o IS DISTINCT FROM v_o.status THEN v_new_o ELSE customer_notice_muted_for END
   WHERE id = v_o.id;

  IF p_destino IS NULL THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_o.account_id, 'remittance_operations', v_o.id, 'deposit', 'human_deposit_release', wacrm_current_actor(),
            jsonb_build_object('trans_id', v_dp.trans_id, 'monto', v_dp.monto, 'operation_id', v_o.id, 'status', v_o.status),
            jsonb_build_object('operation_id', NULL, 'status', v_new_o));
    RETURN jsonb_build_object('operation_id', v_o.id, 'trans_id', v_dp.trans_id, 'released', true, 'moved', false, 'source_status', v_new_o);
  END IF;

  -- The target: its deposits against its request (an empty request becomes the deposit).
  SELECT coalesce(sum(d.monto), 0) INTO v_tdep FROM depositos_mmg d
   WHERE d.operation_id = v_x.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL;
  v_q := CASE WHEN coalesce(v_x.quoted_source_amount, 0) = 0 THEN v_tdep ELSE v_x.quoted_source_amount END;
  v_new_x := CASE WHEN v_tdep >= v_q THEN 'ready_to_transfer' ELSE 'deposit_verification' END;
  UPDATE remittance_operations
     SET quoted_source_amount = v_q, status = v_new_x, incident_reason = NULL, customer_notice_muted_for = v_new_x
   WHERE id = v_x.id;

  IF v_tdep >= v_q THEN PERFORM cerebro_objetivo_cerrar_op(v_x.id); END IF;
  UPDATE cerebro_objetivo_envio SET operation_id = v_x.id
   WHERE conversation_id = v_o.conversation_id AND cerrado_en IS NULL AND operation_id = v_o.id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_o.account_id, 'remittance_operations', v_o.id, 'deposit', 'human_deposit_move', wacrm_current_actor(),
          jsonb_build_object('trans_id', v_dp.trans_id, 'monto', v_dp.monto, 'operation_id', v_o.id, 'status', v_o.status),
          jsonb_build_object('operation_id', v_x.id, 'status', v_new_o)),
         (v_x.account_id, 'remittance_operations', v_x.id, 'deposit', 'human_deposit_move', wacrm_current_actor(),
          jsonb_build_object('operation_id', v_o.id, 'status', v_x.status, 'quoted_source_amount', v_x.quoted_source_amount),
          jsonb_build_object('trans_id', v_dp.trans_id, 'monto', v_dp.monto, 'status', v_new_x, 'deposito_total', v_tdep));

  RETURN jsonb_build_object('operation_id', v_o.id, 'trans_id', v_dp.trans_id, 'released', false, 'moved', true,
                            'source_status', v_new_o, 'target_id', v_x.id, 'target_status', v_new_x);
END $function$;

REVOKE ALL ON FUNCTION public.crm_mover_deposito(uuid, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_mover_deposito(uuid, text, uuid) TO authenticated;
