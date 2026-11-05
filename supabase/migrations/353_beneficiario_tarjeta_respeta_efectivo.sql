-- 353: the card beneficiary tool (n8n gestionar_beneficiario -> cerebro_guardar_beneficiario) must not open a card
-- operation on a cash send. Production 2026-11-05: with an open efectivo_usd operation, a call with name + phone and no
-- card created a NEW operation with a cuban_card beneficiary and answered "FALTA: la tarjeta", so the bot asked the
-- customer for a card.
--
-- RULE (new branch at the start of the function). The call carries no card (empty / null), carries a name or a phone,
-- is not a correction by position / type, and the conversation has an open cash operation (service_type 'remesa',
-- delivery_method 'efectivo_usd', status not completed / cancelled: the same filter crm_registrar_datos_entrega_efectivo
-- uses; the newest one) that is the named p_op when one is named. Then: no operation and no cuban_card beneficiary is
-- created; the name and the phone are stored on that operation's live first cash recipient ONLY where they are empty
-- (never overwriting what a person or the carnet flow set) by calling crm_registrar_datos_entrega_efectivo, which writes
-- the same storage and the same audit (automation_cash_delivery_data_registered) as the cash data flow, and creates the
-- cash recipient if none exists. The answer keeps the tool's output shape (deal_id = the cash operation, accion = text)
-- and says it is a cash send, what was saved, what is still missing and "NO pidas tarjeta: es entrega en efectivo.".
-- Every other case (a card given, no cash operation, corrections by position / type, recharges) runs the old body.
-- Same signature, owner, SECURITY DEFINER, search_path and ACL (CREATE OR REPLACE): idempotent.
CREATE OR REPLACE FUNCTION public.cerebro_guardar_beneficiario(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'gestionar_beneficiario'::text, p_posicion integer DEFAULT NULL::integer, p_tipo text DEFAULT NULL::text)
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
  v_cash_op uuid; v_cash_acc uuid; v_cb remittance_beneficiaries%ROWTYPE; v_cash_r jsonb; v_cash_n text; v_cash_p text; v_cash_saved text[]; v_cash_falta text[];
  v_opx uuid; v_cands uuid[]; v_lista text; v_cambios text[] := ARRAY[]::text[]; v_n2 text; v_card2 text; v_phone2 text; v_tool_otro text; v_nn int;
BEGIN
  -- (353) A cash send never becomes a card send: no card in the call + an open cash operation = cash data.
  IF NULLIF(btrim(coalesce(p_tarjeta, '')), '') IS NULL
     AND (NULLIF(btrim(coalesce(p_nombre, '')), '') IS NOT NULL OR NULLIF(btrim(coalesce(p_celular, '')), '') IS NOT NULL)
     AND p_posicion IS NULL AND v_tipo = '' THEN
    SELECT o.id, o.account_id INTO v_cash_op, v_cash_acc
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'remesa' AND o.delivery_method = 'efectivo_usd'
       AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_cash_op IS NOT NULL AND (p_op IS NULL OR p_op = v_cash_op) THEN
      SELECT * INTO v_cb FROM remittance_beneficiaries
       WHERE operation_id = v_cash_op AND beneficiary_type = 'efectivo_usd' AND status = 'vigente' AND position = 1 LIMIT 1;
      v_cash_n := CASE WHEN NULLIF(btrim(coalesce(v_cb.name, '')), '') IS NULL THEN v_n END;
      v_cash_p := CASE WHEN NULLIF(btrim(coalesce(v_cb.phone, '')), '') IS NULL THEN NULLIF(btrim(coalesce(p_celular, '')), '') END;
      v_cash_r := crm_registrar_datos_entrega_efectivo(p_conv, v_cash_p, NULL, NULL, v_cash_n, NULL, NULL);
      v_cash_saved := ARRAY[]::text[]; v_cash_falta := ARRAY[]::text[];
      IF v_cash_n IS NOT NULL THEN v_cash_saved := v_cash_saved || ('nombre ' || v_cash_n); END IF;
      IF v_cash_p IS NOT NULL THEN v_cash_saved := v_cash_saved || ('celular ' || v_cash_p); END IF;
      IF NULLIF(v_cash_r->>'name', '') IS NULL THEN v_cash_falta := v_cash_falta || 'nombre'::text; END IF;
      IF NULLIF(v_cash_r->>'phone', '') IS NULL THEN v_cash_falta := v_cash_falta || 'telefono'::text; END IF;
      IF NULLIF(v_cash_r->>'address', '') IS NULL THEN v_cash_falta := v_cash_falta || 'direccion'::text; END IF;
      IF NULLIF(v_cash_r->>'id_photo_wamid', '') IS NULL THEN v_cash_falta := v_cash_falta || 'foto del carnet'::text; END IF;
      RETURN QUERY SELECT v_cash_op, ('ES UN ENVIO EN EFECTIVO (entrega en USD), no por tarjeta. '
        || CASE WHEN cardinality(v_cash_saved) > 0 THEN 'Guardado: ' || array_to_string(v_cash_saved, ', ') || '. '
                ELSE 'No hubo nada nuevo que guardar: esos datos ya estaban. ' END
        || 'FALTA para el efectivo: ' || CASE WHEN cardinality(v_cash_falta) > 0 THEN array_to_string(v_cash_falta, ', ') ELSE 'nada, ya esta completo' END
        || '. NO pidas tarjeta: es entrega en efectivo.')::text;
      RETURN;
    END IF;
  END IF;
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
