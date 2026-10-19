-- =====================================================================
-- 249 -- A manual close names the service the way the panel's service change does
--
-- Production 2026-10-19 (operation 02a2d634): a Zelle deposit misfiled as a combo (fixed upstream by 247). The panel
-- asks the service when closing an operation without recipient and method (196). crm_cerrar_operacion_manual only set
-- service_type for recarga/combo/visa/saldo (200/208/213/223); a remesa rail only set delivery_method. So closing that
-- combo as 'zelle' would have left a COMBO with method zelle, billed by the calculator as COMBO: there was no correct
-- choice. The operator chose 'saldo', which kept the combo cost the panel had just asked for on a mobile balance.
--
-- The chosen service now maps the way _cambiar_servicio_core (222) maps it:
--   - recarga / combo / visa / saldo -> that service_type, delivery_method unchanged (as before);
--   - a remesa rail (cuban_card, zelle, clasica, tropical, efectivo_usd) -> service_type 'remesa' with that method;
--   - combo_costo_gyd survives only when the result is a combo;
--   - a change of service_type is audited in the same human_manual_close row (service_type, service_type_before).
-- No chosen service: nothing about the service changes. Signature, ACL, guards and the calculator feed are unchanged.
--
-- Assertion: supabase/staging/assertions/manual-close-service-type.sql. Rollback: ROLLBACK-249-manual-close-names-the-service.sql.
-- odd/tasks/combo-negated-mention.md
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text DEFAULT NULL::text, p_notify boolean DEFAULT false, p_delivery_method text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_service_before text;
  v_service_after text;
  v_completed_at  timestamptz;
  v_motivo        text := coalesce(nullif(btrim(p_motivo), ''), 'Closed manually from the panel');
BEGIN
  SELECT account_id, status, service_type INTO v_account_id, v_status_before, v_service_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  -- (191) No typed reason any more: the fixed note above is audited unless one is given.
  IF length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'the reason must be at most 500 characters' USING ERRCODE = '22023';
  END IF;
  -- (196) The service chosen in the panel when the remesa has no beneficiary, so the calculator can price it.
  IF p_delivery_method IS NOT NULL THEN
    IF p_delivery_method NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      RAISE EXCEPTION 'unknown service: %', p_delivery_method USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'this remesa already has a beneficiary: its service comes from it' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- (249) The chosen service IS the operation's service, as in _cambiar_servicio_core (222): a remesa rail makes a remesa.
  v_service_after := CASE WHEN p_delivery_method IS NULL THEN v_service_before
                          WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN p_delivery_method
                          ELSE 'remesa' END;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid(),
         -- (196) In the same UPDATE, so the calculator feed (AFTER UPDATE OF status) sees the service.
         -- (200) 'recarga' is a kind of operation, not a delivery method: it sets service_type. (208) So is 'combo'. (213) And 'visa'. (223) And 'saldo'.
         delivery_method = CASE WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN delivery_method ELSE coalesce(p_delivery_method, delivery_method) END,
         service_type = v_service_after,
         -- (249) A combo cost belongs to a combo only.
         combo_costo_gyd = CASE WHEN v_service_after = 'combo' THEN combo_costo_gyd END,
         -- (191) Silent by default (p_notify false); the bell on the panel can turn the notice on.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually', 'notify', p_notify)
            || CASE WHEN p_delivery_method IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('delivery_method', p_delivery_method) END
            -- (249) A change of service is visible in the audit row.
            || CASE WHEN v_service_after IS DISTINCT FROM v_service_before
                    THEN jsonb_build_object('service_type', v_service_after, 'service_type_before', v_service_before)
                    ELSE '{}'::jsonb END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

NOTIFY pgrst, 'reload schema';
