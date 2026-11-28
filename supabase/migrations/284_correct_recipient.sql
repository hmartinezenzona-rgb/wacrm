-- 284: gestionar_beneficiario corrects ONE recipient (by position and / or type) and the bot may name the operation; no new tool.
--
-- cerebro_guardar_beneficiario(p_conv, p_nombre, p_tarjeta, p_celular, p_exec, p_op DEFAULT NULL, p_tool DEFAULT 'gestionar_beneficiario',
--                              p_posicion integer DEFAULT NULL, p_tipo text DEFAULT NULL)
--   * p_op: when the bot names the operation it must be an open one of this conversation, else "NO SE GUARDO NADA: esa operacion no es de esta conversacion...".
--   * p_posicion / p_tipo (tarjeta | zelle | efectivo | recarga | mexico): the data given (name, card, phone) corrects THAT recipient of the operation; the
--     others stay as they are. Several recipients and no position: nothing is written and the answer lists them and asks which. A card or phone on a
--     recipient that is not a card (Zelle, cash, recharge, Mexico) is refused naming the tool that owns it (only the name is corrected here). A card that
--     already belongs to another recipient of the operation is refused. A lock a person left on the recipients is respected. Audit action
--     agent_beneficiary_corrected (before / after).
--   * Without p_posicion / p_tipo the behaviour is exactly the old one (single recipient write, reparto slots, D1 rules).
-- The 7-argument overload is dropped (callers keep working through the defaults). Rollback: ROLLBACK-284-correct-recipient.sql.

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
  'agent_beneficiary_corrected'::text]));

DROP FUNCTION IF EXISTS public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text);

CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'gestionar_beneficiario'::text,
  p_posicion integer DEFAULT NULL::integer, p_tipo text DEFAULT NULL::text)
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
  v_tipo text := lower(btrim(coalesce(p_tipo, '')));
  v_fam text[]; v_ids uuid[]; v_pick remittance_beneficiaries%ROWTYPE; v_op_row remittance_operations%ROWTYPE;
  v_opx uuid; v_cands uuid[]; v_lista text; v_cambios text[] := ARRAY[]::text[]; v_n2 text; v_card2 text; v_phone2 text; v_tool_otro text; v_nn int;
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
  -- (284) The bot may name the operation: it must be an open one of this conversation.
  IF p_op IS NOT NULL AND NOT EXISTS (SELECT 1 FROM remittance_operations o
                                       WHERE o.id = p_op AND o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')) THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE GUARDO NADA: esa operacion no es de esta conversacion o ya no esta abierta. Revisa cual es el envio y vuelve a llamar.'::text;
    RETURN;
  END IF;

  -- (284) CORRECTION of one recipient, by position and / or type: name, card or phone of THAT recipient; the others are untouched.
  IF p_posicion IS NOT NULL OR v_tipo <> '' THEN
    v_fam := CASE v_tipo
               WHEN '' THEN NULL
               WHEN 'tarjeta' THEN ARRAY['cuban_card', 'clasica', 'tropical', 'multiple_distribution']
               WHEN 'cup' THEN ARRAY['cuban_card', 'clasica', 'tropical', 'multiple_distribution']
               WHEN 'cuban_card' THEN ARRAY['cuban_card', 'clasica', 'tropical', 'multiple_distribution']
               WHEN 'clasica' THEN ARRAY['cuban_card', 'clasica', 'tropical', 'multiple_distribution']
               WHEN 'tropical' THEN ARRAY['cuban_card', 'clasica', 'tropical', 'multiple_distribution']
               WHEN 'zelle' THEN ARRAY['zelle']
               WHEN 'efectivo' THEN ARRAY['efectivo_usd']
               WHEN 'efectivo_usd' THEN ARRAY['efectivo_usd']
               WHEN 'recarga' THEN ARRAY['recarga']
               WHEN 'mexico' THEN ARRAY['mexico_cuenta', 'mexico_retiro']
               ELSE ARRAY[]::text[] END;
    IF v_fam IS NOT NULL AND cardinality(v_fam) = 0 THEN
      RETURN QUERY SELECT NULL::uuid, 'NO SE GUARDO NADA: el tipo debe ser tarjeta, zelle, efectivo, recarga o mexico.'::text; RETURN;
    END IF;
    -- the operation: the one named, else the single open one that has recipients of that kind (no hand-over to a person here: the bot is asked)
    IF p_op IS NOT NULL THEN
      v_opx := p_op;
    ELSE
      SELECT coalesce(array_agg(DISTINCT o.id), ARRAY[]::uuid[]) INTO v_cands
        FROM remittance_operations o
       WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
         AND EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                        AND (v_fam IS NULL OR b.beneficiary_type = ANY (v_fam)));
      IF cardinality(v_cands) = 0 THEN
        RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: no hay un destinatario' || CASE WHEN v_tipo <> '' THEN ' de tipo ' || v_tipo ELSE '' END
                                          || CASE WHEN p_posicion IS NOT NULL THEN ' en la posicion ' || p_posicion ELSE '' END || ' en un envio abierto que corregir.')::text; RETURN;
      ELSIF cardinality(v_cands) > 1 THEN
        RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: hay ' || cardinality(v_cands) || ' envios abiertos con ese destinatario. Indica a cual (operacion) se refiere el cliente.')::text; RETURN;
      END IF;
      v_opx := v_cands[1];
    END IF;
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments)
    VALUES (coalesce(p_exec, '') || ':' || p_tool || ':' || md5(jsonb_build_array(p_nombre, p_tarjeta, p_celular, p_posicion, p_tipo)::text), p_tool, p_exec, p_conv, v_opx,
            jsonb_build_array(p_nombre, p_tarjeta, p_celular, p_posicion, p_tipo))
    ON CONFLICT (idempotency_key) DO NOTHING;
    SELECT * INTO v_op_row FROM remittance_operations WHERE id = v_opx FOR UPDATE;
    IF coalesce(v_op_row.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
      RETURN QUERY SELECT NULL::uuid, 'NO SE GUARDO NADA: los destinatarios de este envio los fijo una persona desde el panel; un companero lo revisa.'::text; RETURN;
    END IF;
    SELECT coalesce(array_agg(b.id ORDER BY b.position, b.id), ARRAY[]::uuid[]),
           string_agg(b.position || ') ' || coalesce(b.name, '(sin nombre)')
                      || CASE WHEN b.card_number IS NOT NULL THEN ' / tarjeta ' || b.card_number ELSE '' END
                      || CASE WHEN b.zelle_account IS NOT NULL THEN ' / ' || b.zelle_account ELSE '' END
                      || CASE WHEN b.phone IS NOT NULL THEN ' / cel ' || b.phone ELSE '' END, '; ' ORDER BY b.position, b.id)
      INTO v_ids, v_lista
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_opx AND b.status = 'vigente' AND (v_fam IS NULL OR b.beneficiary_type = ANY (v_fam));
    v_nn := cardinality(v_ids);
    IF v_nn = 0 THEN
      RETURN QUERY SELECT NULL::uuid, 'NO SE GUARDO NADA: ese envio no tiene destinatarios' || CASE WHEN v_tipo <> '' THEN ' de tipo ' || v_tipo ELSE '' END || ' que corregir.'::text; RETURN;
    END IF;
    IF p_posicion IS NOT NULL THEN
      SELECT * INTO v_pick FROM remittance_beneficiaries b
       WHERE b.id = ANY (v_ids) AND b.position = p_posicion ORDER BY b.id LIMIT 1;
      IF NOT FOUND THEN
        RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: no hay un destinatario en la posicion ' || p_posicion || '. Hay ' || v_nn || ': ' || v_lista || '. Preguntale al cliente cual es.')::text; RETURN;
      END IF;
    ELSIF v_nn = 1 THEN
      SELECT * INTO v_pick FROM remittance_beneficiaries b WHERE b.id = v_ids[1];
    ELSE
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: hay ' || v_nn || ' destinatarios ' || CASE WHEN v_tipo <> '' THEN 'de ese tipo ' ELSE '' END || '(' || v_lista || '). Indica la posicion del que se corrige, o preguntale al cliente cual es.')::text; RETURN;
    END IF;
    IF (v_t IS NOT NULL OR v_c IS NOT NULL) AND NOT (v_pick.beneficiary_type = ANY (ARRAY['cuban_card', 'clasica', 'tropical', 'multiple_distribution'])) THEN
      v_tool_otro := CASE v_pick.beneficiary_type WHEN 'zelle' THEN 'registrar_beneficiario_zelle' WHEN 'efectivo_usd' THEN 'registrar_datos_entrega_efectivo'
                                                   WHEN 'recarga' THEN 'registrar_numeros_recarga' ELSE 'registrar_destinatario_mexico' END;
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: ese destinatario es ' || v_pick.beneficiary_type || ' y no tiene tarjeta ni celular de tarjeta: su cuenta o numero se corrige con ' || v_tool_otro || '. Aqui solo se corrige el nombre.')::text; RETURN;
    END IF;
    v_n2 := coalesce(v_n, v_pick.name); v_card2 := coalesce(v_t, v_pick.card_number); v_phone2 := coalesce(v_c, v_pick.phone);
    IF v_n2 IS NOT DISTINCT FROM v_pick.name AND v_card2 IS NOT DISTINCT FROM v_pick.card_number AND v_phone2 IS NOT DISTINCT FROM v_pick.phone THEN
      RETURN QUERY SELECT v_opx, ('sin cambios: el destinatario ' || v_pick.position || ' ya tenia esos datos. Destinatarios: ' || v_lista)::text; RETURN;
    END IF;
    IF v_card2 IS DISTINCT FROM v_pick.card_number AND EXISTS (SELECT 1 FROM remittance_beneficiaries b
                                                            WHERE b.operation_id = v_opx AND b.status = 'vigente' AND b.id <> v_pick.id AND b.card_number = v_card2) THEN
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: esa tarjeta ya es de otro destinatario de este envio (' || v_lista || ').')::text; RETURN;
    END IF;
    IF v_n2 IS DISTINCT FROM v_pick.name THEN v_cambios := v_cambios || ('nombre ' || coalesce(v_n2, '(vacio)')); END IF;
    IF v_card2 IS DISTINCT FROM v_pick.card_number THEN v_cambios := v_cambios || ('tarjeta ' || coalesce(v_card2, '(vacia)')); END IF;
    IF v_phone2 IS DISTINCT FROM v_pick.phone THEN v_cambios := v_cambios || ('celular ' || coalesce(v_phone2, '(vacio)')); END IF;
    UPDATE remittance_beneficiaries SET name = v_n2, card_number = v_card2, phone = v_phone2 WHERE id = v_pick.id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_op_row.account_id, 'remittance_beneficiaries', v_pick.id, 'recipient', 'agent_beneficiary_corrected',
            'agent:' || p_tool || ' n8n:' || coalesce(nullif(btrim(p_exec), ''), 'unknown'), 'the customer corrected a recipient',
            jsonb_build_object('name', v_pick.name, 'card_number', v_pick.card_number, 'phone', v_pick.phone, 'position', v_pick.position),
            jsonb_build_object('name', v_n2, 'card_number', v_card2, 'phone', v_phone2, 'position', v_pick.position));
    SELECT string_agg(b.position || ') ' || coalesce(b.name, '(sin nombre)')
                      || CASE WHEN b.card_number IS NOT NULL THEN ' / tarjeta ' || b.card_number ELSE '' END
                      || CASE WHEN b.zelle_account IS NOT NULL THEN ' / ' || b.zelle_account ELSE '' END
                      || CASE WHEN b.phone IS NOT NULL THEN ' / cel ' || b.phone ELSE '' END, '; ' ORDER BY b.position, b.id)
      INTO v_lista
      FROM remittance_beneficiaries b WHERE b.operation_id = v_opx AND b.status = 'vigente' AND (v_fam IS NULL OR b.beneficiary_type = ANY (v_fam));
    RETURN QUERY SELECT v_opx, ('corregido (destinatario ' || v_pick.position || ' de ' || v_nn || '): ' || array_to_string(v_cambios, ', ') || '. Destinatarios ahora: ' || v_lista)::text;
    RETURN;
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

REVOKE ALL ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_guardar_beneficiario(uuid, text, text, text, text, uuid, text, integer, text) TO service_role;
