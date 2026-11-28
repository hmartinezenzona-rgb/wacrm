-- ROLLBACK of 230_bot_change_service.sql: restores crm_cambiar_servicio exactly as 223 left it (pg_get_functiondef md5 on staging,
-- 2026-10-08: ee82240e976cd036b8b23b085c8d8ca9), drops cerebro_cambiar_servicio and the internal core, and restores
-- remittance_admin_audit_action_chk without 'automation_service_change' (constraint definition text + newline md5
-- a3453bb94deeb54ef1037f81e9ccfe73). It refuses (and changes nothing) when an automation_service_change audit row exists: the row would
-- violate the restored constraint and the audit is evidence; export or keep it first. Operations the bot already switched keep their
-- data (rail, quote, retired recipients) and their rail lock stamped 'automation:'.
-- Run it only after the n8n tool that calls cerebro_cambiar_servicio is removed from the bot, or the tool answers with an error.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM remittance_admin_audit WHERE action = 'automation_service_change') THEN
    RAISE EXCEPTION 'ROLLBACK-230 refused: automation_service_change audit rows exist; export them first' USING ERRCODE = 'P0001';
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.cerebro_cambiar_servicio(uuid, text, text);

CREATE OR REPLACE FUNCTION public.crm_cambiar_servicio(p_operation_id uuid, p_servicio text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op         remittance_operations%ROWTYPE;
  v_servicio   text := lower(btrim(coalesce(p_servicio, '')));
  v_actual     text;
  v_card_types constant text[] := ARRAY['cuban_card', 'clasica', 'tropical'];
  v_new_type   text;
  v_new_dm     text;
  v_fit        integer;
  v_mixed      integer;
  v_retired    uuid[];
  v_retyped    uuid[];
  v_before     jsonb;
  v_after      jsonb;
  v_lock       jsonb;
  v_single     remittance_beneficiaries%ROWTYPE;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_op.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to change the service of this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'operation is closed' USING ERRCODE = '22023';
  END IF;

  IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
    RAISE EXCEPTION 'unknown service: %', p_servicio USING ERRCODE = '22023';
  END IF;

  IF v_op.service_type NOT IN ('remesa', 'recarga', 'combo', 'visa', 'saldo') THEN
    RAISE EXCEPTION 'the service of a % operation cannot be changed here', v_op.service_type USING ERRCODE = '22023';
  END IF;

  v_actual := cerebro_riel_op(p_operation_id);
  IF v_actual IS NOT DISTINCT FROM v_servicio THEN
    RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', false);
  END IF;

  v_new_type := CASE WHEN v_servicio IN ('recarga', 'combo', 'visa', 'saldo') THEN v_servicio ELSE 'remesa' END;
  v_new_dm   := CASE WHEN v_new_type = 'remesa' THEN v_servicio END;

  -- Which current recipients fit the new service (a card rail also takes multiple_distribution on CUP).
  SELECT count(*) INTO v_fit
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
     AND CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
              WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
              WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
              WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
              ELSE false END;

  -- Several card shares with their own amounts cannot move between CUP and USD: there is nothing to recompute them from.
  IF v_servicio IN ('cuban_card', 'clasica', 'tropical') AND v_fit > 1 THEN
    SELECT count(*) INTO v_mixed
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND b.beneficiary_type = ANY (v_card_types)
       AND (b.beneficiary_type = 'cuban_card') <> (v_servicio = 'cuban_card');
    IF v_mixed > 0 THEN
      RAISE EXCEPTION 'several recipients with their own amounts cannot change between CUP and USD: correct them one by one' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_before := jsonb_build_object(
    'service', v_actual, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'recipients', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'type', b.beneficiary_type) ORDER BY b.position), '[]'::jsonb)
                     FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente'));

  -- 1. The operation: new service, quote cleared, rail locked against the bot. The 096 guard locks the changed
  --    destination fields for a human writer; they are released right after (2).
  UPDATE remittance_operations
     SET service_type = v_new_type,
         delivery_method = v_new_dm,
         destination_currency = NULL,
         quoted_destination_amount = NULL,
         quoted_destination_rate = NULL,
         quoted_destination_origin = NULL,
         combo_costo_gyd = CASE WHEN v_new_type = 'combo' THEN combo_costo_gyd END,
         admin_locked_fields = coalesce(admin_locked_fields, '{}'::jsonb)
           || jsonb_build_object('delivery_method', jsonb_build_object('by', wacrm_current_actor(), 'at', now()),
                                 'service_type', jsonb_build_object('by', wacrm_current_actor(), 'at', now()))
   WHERE id = p_operation_id;

  -- 2. The quote is calculated, not manual: release the destination locks so the calculation can write it.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
   WHERE id = p_operation_id;

  -- 3. Recipients that do not fit are retired.
  WITH r AS (
    UPDATE remittance_beneficiaries b
       SET status = 'reemplazado', replaced_at = now()
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND NOT CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
                    WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
                    WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
                    WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
                    ELSE false END
    RETURNING b.id)
  SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_retired FROM r;

  -- 4. Recipients that fit: a card rail re-types the card; a lone recipient is priced again.
  IF v_servicio IN ('cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd') THEN
    WITH k AS (
      UPDATE remittance_beneficiaries b
         SET beneficiary_type = CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN v_servicio ELSE b.beneficiary_type END,
             amount = CASE WHEN v_fit = 1 THEN NULL ELSE b.amount END,
             currency = CASE WHEN v_fit = 1 THEN NULL ELSE b.currency END,
             amount_origin = CASE WHEN v_fit = 1 THEN NULL ELSE b.amount_origin END
       WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
         AND (v_fit = 1 OR (v_servicio IN ('cuban_card', 'clasica', 'tropical') AND b.beneficiary_type <> v_servicio))
         AND NOT (v_servicio = 'cuban_card' AND b.beneficiary_type = 'multiple_distribution')
      RETURNING b.id)
    SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_retyped FROM k;
  ELSE
    v_retyped := ARRAY[]::uuid[];
  END IF;

  -- 5. The existing calculation prices the operation again (the recipient triggers have already run it; this covers
  --    the case where nothing was re-typed). A lone recipient of an operation whose recipients were locked by an earlier
  --    correction does not get its amount from the calculation, so it takes the recalculated quote here.
  PERFORM crm_calcular_monto_destino(p_operation_id);
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF v_op.quoted_destination_origin = 'calculated' THEN
    SELECT * INTO v_single FROM remittance_beneficiaries
     WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'combo' ORDER BY position LIMIT 1;
    IF v_single.id IS NOT NULL
       AND (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = p_operation_id AND status = 'vigente') = 1
       AND (v_single.amount IS DISTINCT FROM v_op.quoted_destination_amount
            OR v_single.currency IS DISTINCT FROM v_op.destination_currency) THEN
      UPDATE remittance_beneficiaries
         SET amount = v_op.quoted_destination_amount, currency = v_op.destination_currency, amount_origin = 'calculated'
       WHERE id = v_single.id;
    END IF;
  END IF;

  -- 6. The calculation's own writes were locked by the guard (the writer is a human): release them again.
  UPDATE remittance_operations
     SET admin_locked_fields = admin_locked_fields - 'quoted_destination_amount' - 'destination_currency'
   WHERE id = p_operation_id
     AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];

  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  v_after := jsonb_build_object(
    'service', v_servicio, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'retired_recipients', to_jsonb(v_retired), 'retyped_recipients', to_jsonb(v_retyped));

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_op.account_id, 'remittance_operations', p_operation_id, 'service', 'human_correction',
          wacrm_current_actor(), v_before, v_after);

  RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', true,
                            'retired_recipients', coalesce(array_length(v_retired, 1), 0),
                            'retyped_recipients', coalesce(array_length(v_retyped, 1), 0));
END $function$;

REVOKE ALL ON FUNCTION public.crm_cambiar_servicio(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cambiar_servicio(uuid, text) TO authenticated;

DROP FUNCTION IF EXISTS public._cambiar_servicio_core(uuid, text, text, text, text);

ALTER TABLE remittance_admin_audit DROP CONSTRAINT remittance_admin_audit_action_chk;
ALTER TABLE remittance_admin_audit ADD CONSTRAINT remittance_admin_audit_action_chk CHECK (action = ANY (ARRAY[
  'automation_write_suppressed', 'automation_completion_suppressed', 'automation_revert_suppressed', 'human_correction',
  'human_reassignment', 'human_deposit_verification', 'human_forced_verification', 'human_delivery', 'calculator_feed_failed',
  'calculator_pending_resolved', 'human_beneficiary_added', 'automation_reparto_registered', 'human_calculator_correction',
  'automation_cash_delivery_data_registered', 'automation_late_deposit_verification', 'human_manual_close',
  'human_operation_deleted', 'automation_recharge_numbers_registered', 'automation_combo_recipient_registered',
  'human_combo_cost_set', 'automation_visa_registered', 'human_calculator_entry_deleted', 'human_calculator_manual_added']));
