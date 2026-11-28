-- ROLLBACK of 192_force_verify_without_reason.sql: back to the 191 body (a reason of at least 5 characters required).
DROP FUNCTION public.crm_forzar_verificacion(uuid, text, boolean);

CREATE OR REPLACE FUNCTION public.crm_forzar_verificacion(p_operation_id uuid, p_reason text, p_notify boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id     uuid;
  v_status_before  text;
  v_status_after   text;
  v_deal_id        uuid;
  v_reason         text;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to force-verify this operation' USING ERRCODE = '42501';
  END IF;

  v_reason := btrim(coalesce(p_reason, ''));
  IF length(v_reason) < 5 THEN
    RAISE EXCEPTION 'reason must be at least 5 characters' USING ERRCODE = '22023';
  END IF;

  -- (165) A deal-free operation is force-verifiable; the old guard is gone.
  -- The deal lock stays, but only while a deal exists.
  IF v_deal_id IS NOT NULL THEN
    PERFORM 1 FROM deals WHERE id = v_deal_id FOR UPDATE;
  END IF;

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before NOT IN ('deposit_verification', 'incident') THEN
    RAISE EXCEPTION 'operation is not awaiting deposit verification' USING ERRCODE = '22023';
  END IF;

  -- (165) The notes write stays, unchanged, for a row that still has a deal.
  -- The status write and the audit row below are the operation-keyed
  -- equivalent and run either way.
  IF v_deal_id IS NOT NULL THEN
    UPDATE deals
       SET notes = replace(coalesce(notes, ''),
                            'VERIFICADO: casa con el correo de MMG',
                            'VERIFICADO EN PANEL: casa con el correo de MMG')
                   || chr(10) || 'VERIFICACION FORZADA EN PANEL: ' || v_reason,
           updated_at = now()
     WHERE id = v_deal_id;
  END IF;

  -- (114) Direct write replacing the retired bridge trigger.
  UPDATE remittance_operations
     SET status = 'ready_to_transfer',
         -- (191) The panel's notify-customer choice, in the row image the notifier reads.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'ready_to_transfer' END
   WHERE id = p_operation_id;

  SELECT status INTO v_status_after FROM remittance_operations WHERE id = p_operation_id;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_forced_verification',
          wacrm_current_actor(), v_reason,
          jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', v_status_after));

  RETURN jsonb_build_object('new_status', v_status_after);
END $function$;

REVOKE ALL ON FUNCTION public.crm_forzar_verificacion(uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_forzar_verificacion(uuid, text, boolean) TO authenticated, service_role;
