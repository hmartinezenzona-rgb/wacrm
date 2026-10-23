-- ROLLBACK 284: back to the 7-argument cerebro_guardar_beneficiario.
DROP FUNCTION IF EXISTS public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'gestionar_beneficiario'::text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t text := cerebro_norm_tarjeta(p_tarjeta);
  v_c text := cerebro_norm_celular_cu(p_celular);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_r record; v_cur record; v_tiene boolean;
  v_card text; v_phone text; v_name text; v_deal uuid; v_falta text;
  v_slots int; v_k int; v_libre int; v_tarjetas text;
BEGIN
  IF v_t = '!' OR v_c = '!' THEN
    RETURN QUERY SELECT NULL::uuid, ('ERROR: no se guardo nada. ' ||
      CASE WHEN v_t = '!' THEN 'La tarjeta tiene que tener 16 digitos. ' ELSE '' END ||
      CASE WHEN v_c = '!' THEN 'El celular cubano son 8 digitos y empieza por 5 o por 63. ' ELSE '' END ||
      'Pidele al cliente ese dato otra vez, con naturalidad.')::text;
    RETURN;
  END IF;
  IF v_t IS NULL AND v_c IS NULL AND v_n IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_nombre, p_tarjeta, p_celular), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  -- (184) A vigente reparto (2-3 card slots) is never replaced by a single beneficiary: the data
  -- completes the reparto slot it belongs to, or the bot is sent to the reparto tool.
  SELECT count(*), max(b.position) FILTER (WHERE b.card_number = v_t),
         min(b.position) FILTER (WHERE b.phone IS NULL),
         string_agg(coalesce(b.card_number, '(sin tarjeta)'), ', ' ORDER BY b.position)
    INTO v_slots, v_k, v_libre, v_tarjetas
    FROM remittance_beneficiaries b
   WHERE b.operation_id = v_r.o_op AND b.status = 'vigente'
     AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical') AND b.position BETWEEN 1 AND 3;
  IF v_slots >= 2 THEN
    IF v_t IS NULL AND v_c IS NOT NULL THEN
      v_k := v_libre;   -- D1: a lone phone completes the first card still without one
    END IF;
    IF v_k IS NULL THEN
      -- a card not in the reparto, a phone when every slot has one, or a name alone (no name per slot)
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: este envio es un REPARTO entre ' || v_slots
        || ' tarjetas (' || v_tarjetas || ')'
        || CASE WHEN v_t IS NOT NULL THEN ' y la tarjeta ' || v_t || ' no esta en el reparto'
                WHEN v_c IS NOT NULL THEN ' y todas ya tienen celular' ELSE '' END
        || '. Usa registrar_reparto_multiple, por posicion. Si no esta claro a que tarjeta va el dato, o si el'
        || ' cliente cambio de idea, preguntaselo con naturalidad.')::text;
      RETURN;
    END IF;
    RETURN QUERY SELECT * FROM cerebro_guardar_reparto(p_conv,
      CASE WHEN v_k = 1 THEN coalesce(v_t, '') ELSE '' END, CASE WHEN v_k = 1 THEN coalesce(v_c, '') ELSE '' END, '',
      CASE WHEN v_k = 2 THEN coalesce(v_t, '') ELSE '' END, CASE WHEN v_k = 2 THEN coalesce(v_c, '') ELSE '' END, '',
      CASE WHEN v_k = 3 THEN coalesce(v_t, '') ELSE '' END, CASE WHEN v_k = 3 THEN coalesce(v_c, '') ELSE '' END, '',
      p_exec, v_r.o_op, p_tool);
    RETURN;
  END IF;

  SELECT b.card_number, b.phone, b.name INTO v_cur
    FROM remittance_beneficiaries b
   WHERE b.operation_id = v_r.o_op AND b.status = 'vigente' AND b.beneficiary_type = 'cuban_card'
   ORDER BY b.block_index DESC LIMIT 1;

  -- D1: a different card starts without a phone; otherwise the given fields patch the saved ones.
  IF v_t IS NOT NULL AND v_cur.card_number IS NOT NULL AND v_t <> v_cur.card_number THEN
    v_card := v_t; v_phone := v_c; v_name := v_n;
  ELSE
    v_card := coalesce(v_t, v_cur.card_number);
    v_phone := coalesce(v_c, v_cur.phone);
    v_name := coalesce(v_n, v_cur.name);
  END IF;
  v_falta := concat_ws(' y ', CASE WHEN v_card IS NULL THEN 'la tarjeta' END, CASE WHEN v_phone IS NULL THEN 'el celular' END);

  IF v_card IS NOT DISTINCT FROM v_cur.card_number AND v_phone IS NOT DISTINCT FROM v_cur.phone
     AND v_name IS NOT DISTINCT FROM v_cur.name THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: esos datos ya estaban guardados'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op,
      CASE WHEN v_tiene THEN 'BENEFICIARIO ACTUALIZADO - reemplaza al anterior' ELSE 'BENEFICIARIO' END
      || CASE WHEN v_name IS NOT NULL THEN ' (' || v_name || ')' ELSE '' END
      || E'\nTarjeta: ' || coalesce(v_card, '-') || E'\nCelular: ' || coalesce(v_phone, '-'));
  RETURN QUERY SELECT v_deal, ('guardado: tarjeta ' || coalesce(v_card, '(falta)') || ', celular ' || coalesce(v_phone, '(falta)')
    || CASE WHEN v_name IS NOT NULL THEN ', nombre ' || v_name ELSE '' END
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente.' ELSE '. Completo.' END)::text;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text) TO service_role;

-- audit action list as before 284 (rows written by the correction must be gone or renamed first)
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
  'agent_recharge_number_removed'::text]));
