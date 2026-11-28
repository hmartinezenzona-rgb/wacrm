-- ROLLBACK for 360: restores the pre-360 bodies of cerebro_escribir_bloque_beneficiario, cerebro_guardar_zelle,
-- cerebro_guardar_beneficiario and cerebro_guardar_reparto (their ACLs are preserved), then drops the five 360 helpers.

CREATE OR REPLACE FUNCTION public.cerebro_escribir_bloque_beneficiario(p_conv uuid, p_op uuid, p_bloque text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op      uuid := p_op;
  v_bi      integer;
  v_reparto boolean;
  v_zelle   integer;
  v_locked  boolean;
  v_account uuid;
BEGIN
  -- (210) A combo's recipients are written only by crm_registrar_destinatario_combo: this remesa writer (typed numbers,
  -- the remesa tools) neither writes on a combo nor opens a remesa next to an open combo. Owner test 2026-10-04: typed
  -- phones became 'cuban_card' generations on the combo and its recipients turned 'reemplazado'.
  -- (223) Nor ON a mobile balance (its one phone recipient is written from the panel only): a typed card is a remesa.
  -- (213) Never ON a visa (it has no recipients at all) nor on a combo past collecting its recipients (its deposit
  -- arrived): the typed data is a new remesa, opened next to it. Only a combo still collecting keeps the numbers (210).
  IF v_op IS NOT NULL AND EXISTS (SELECT 1 FROM remittance_operations o WHERE o.id = v_op
                                   AND (o.service_type IN ('visa', 'saldo')
                                        OR (o.service_type = 'combo' AND o.status <> 'collecting_information'))) THEN
    v_op := cerebro_crear_operacion(p_conv);
  ELSIF v_op IS NULL THEN
    SELECT o.id INTO v_op FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'combo' AND o.status = 'collecting_information'
     ORDER BY o.created_at DESC LIMIT 1;
    IF v_op IS NOT NULL THEN RETURN v_op; END IF;
    v_op := cerebro_crear_operacion(p_conv);
  END IF;
  IF (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_op) = 'combo' THEN
    RETURN v_op;
  END IF;

  SELECT admin_locked_fields ? 'beneficiaries', account_id INTO v_locked, v_account
    FROM remittance_operations WHERE id = v_op;
  IF v_locked THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason)
    VALUES (v_account, 'remittance_beneficiaries', v_op, 'beneficiaries', 'automation_write_suppressed',
            wacrm_current_actor(), 'beneficiaries locked by operator correction');
    RETURN v_op;
  END IF;

  SELECT coalesce(max(b.block_index), 0) + 1 INTO v_bi FROM remittance_beneficiaries b WHERE b.operation_id = v_op;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone,
                                        zelle_account, amount, currency, position, block_index, source, status)
  SELECT v_op, p.tipo, p.nombre, p.tarjeta, p.celular, p.cuenta_zelle, p.monto, p.moneda, p.posicion, v_bi,
         'notes_parse', 'vigente'
    FROM cerebro_parsear_beneficiarios(p_bloque) p;

  -- (175) The newest generation is a reparto between cards: the latest Zelle stays vigente next to it.
  v_reparto := EXISTS (SELECT 1 FROM remittance_beneficiaries
                        WHERE operation_id = v_op AND block_index = v_bi
                          AND beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical'));
  IF v_reparto THEN
    SELECT max(block_index) INTO v_zelle FROM remittance_beneficiaries
     WHERE operation_id = v_op AND beneficiary_type = 'zelle' AND block_index < v_bi;
  END IF;

  UPDATE remittance_beneficiaries
     SET status = 'reemplazado', replaced_at = coalesce(replaced_at, now())
   WHERE operation_id = v_op AND block_index < v_bi AND status <> 'reemplazado'
     AND block_index IS DISTINCT FROM v_zelle;

  UPDATE remittance_beneficiaries
     SET status = 'vigente', replaced_at = NULL
   WHERE operation_id = v_op AND block_index = v_zelle AND beneficiary_type = 'zelle' AND status <> 'vigente';

  RETURN v_op;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'registrar_beneficiario_zelle'::text, p_posicion integer DEFAULT NULL::integer, p_agregar boolean DEFAULT false, p_monto numeric DEFAULT NULL::numeric)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_a text := cerebro_norm_cuenta_zelle(p_cuenta);
  v_n text := NULLIF(btrim(coalesce(p_nombre, '')), '');
  v_r record; v_tiene boolean;
  v_names text[] := ARRAY[]::text[]; v_accts text[] := ARRAY[]::text[]; v_amts numeric[] := ARRAY[]::numeric[];
  v_cnt int := 0; v_i int; v_k int; v_hit int := NULL;
  v_cn text; v_ca text; v_cm numeric;
  v_name text; v_acc text; v_amt numeric;
  v_legacy_replace boolean := false;
  v_block text; v_lineas text := ''; v_lista text := ''; v_falta text := ''; v_deal uuid; v_b record;
  v_cambio boolean;
  v_sum numeric; v_hueco boolean; v_dep numeric; v_need numeric; v_aviso text := '';
BEGIN
  IF p_monto IS NOT NULL AND p_monto <= 0 THEN
    RETURN QUERY SELECT NULL::uuid, 'ERROR: el monto de ese destinatario tiene que ser mayor que 0. No se guardo nada.'::text; RETURN;
  END IF;
  IF v_a IS NULL AND v_n IS NULL AND p_monto IS NULL THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_nombre, p_cuenta), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  -- The recipients in force on the operation, in slot order.
  IF v_r.o_op IS NOT NULL THEN
    FOR v_b IN SELECT b.name, b.zelle_account, b.amount FROM remittance_beneficiaries b
                WHERE b.operation_id = v_r.o_op AND b.status = 'vigente' AND b.beneficiary_type = 'zelle'
                ORDER BY b.position, b.block_index, b.created_at LOOP
      v_cnt := v_cnt + 1;
      v_names := v_names || v_b.name; v_accts := v_accts || v_b.zelle_account; v_amts := v_amts || v_b.amount;
    END LOOP;
  END IF;

  -- Which slot this call is about.
  IF v_a IS NOT NULL THEN
    FOR v_i IN 1 .. v_cnt LOOP
      IF lower(v_accts[v_i]) = lower(v_a) THEN v_hit := v_i; EXIT; END IF;
    END LOOP;
  END IF;
  IF p_agregar THEN
    v_k := coalesce(v_hit, v_cnt + 1);
  ELSIF p_posicion IS NOT NULL THEN
    IF p_posicion < 1 OR p_posicion > v_cnt + 1 THEN
      RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: la posicion ' || p_posicion || ' no existe. Hay ' || v_cnt
        || ' destinatario(s) Zelle: usa una posicion de 1 a ' || (v_cnt + 1) || ' (' || (v_cnt + 1) || ' es para sumar uno nuevo).')::text;
      RETURN;
    END IF;
    v_k := p_posicion;
  ELSIF v_cnt = 0 THEN
    v_k := 1;
  ELSIF v_hit IS NOT NULL THEN
    v_k := v_hit;
  ELSIF v_cnt = 1 AND (v_a IS NULL OR v_accts[1] IS NULL OR p_tool = 'Registrar zelle auto') THEN
    v_k := 1;   -- the lone recipient is completed (a missing account) or its holder corrected; the automatic reader keeps replacing (it still runs in production)
  ELSIF v_cnt = 1 THEN
    -- (285) A DIFFERENT account with one recipient in force and no agregar / posicion is ambiguous (another person or a correction of the
    -- account): it used to replace the first recipient and lose it. Nothing is written; the bot asks the customer.
    RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: este envio ya tiene un destinatario Zelle (1) ' || coalesce(v_names[1], '(falta nombre)') || ' / '
      || coalesce(v_accts[1], '(falta cuenta)') || ' y esa cuenta (' || v_a || ') es otra. Preguntale al cliente si es OTRA persona (llama con agregar=true) '
      || 'o si corrige la cuenta de ese destinatario (llama con posicion=1). No se cambio nada.')::text;
    RETURN;
  ELSE
    FOR v_i IN 1 .. v_cnt LOOP
      v_lista := v_lista || CASE WHEN v_lista = '' THEN '' ELSE '; ' END
                 || v_i || ') ' || coalesce(v_names[v_i], '(falta nombre)') || ' / ' || coalesce(v_accts[v_i], '(falta cuenta)');
    END LOOP;
    RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: este envio ya tiene ' || v_cnt || ' destinatarios Zelle (' || v_lista
      || ') y esa cuenta no es ninguna de ellas. Si es OTRO destinatario llama con agregar=true; si corriges uno, indica su posicion (1 a '
      || v_cnt || '). Si no esta claro, preguntaselo al cliente.')::text;
    RETURN;
  END IF;

  v_cn := CASE WHEN v_k <= v_cnt THEN v_names[v_k] END;
  v_ca := CASE WHEN v_k <= v_cnt THEN v_accts[v_k] END;
  v_cm := CASE WHEN v_k <= v_cnt THEN v_amts[v_k] END;
  -- A different account starts without a holder (the name belongs to the account it came with).
  IF v_a IS NOT NULL AND v_ca IS NOT NULL AND lower(v_a) <> lower(v_ca) THEN
    -- (285) the amount belongs to the slot (what that person receives), not to the account: a corrected account keeps it.
    v_acc := v_a; v_name := v_n; v_amt := coalesce(p_monto, v_cm);
    v_legacy_replace := NOT p_agregar AND p_posicion IS NULL AND v_cnt = 1;
  ELSE
    v_acc := coalesce(v_a, v_ca); v_name := coalesce(v_n, v_cn); v_amt := coalesce(p_monto, v_cm);
  END IF;

  v_cambio := v_k > v_cnt OR v_acc IS DISTINCT FROM v_ca OR v_name IS DISTINCT FROM v_cn OR v_amt IS DISTINCT FROM v_cm;
  IF v_k > v_cnt THEN
    v_names := v_names || v_name; v_accts := v_accts || v_acc; v_amts := v_amts || v_amt;
    v_cnt := v_cnt + 1;
  ELSE
    v_names[v_k] := v_name; v_accts[v_k] := v_acc; v_amts[v_k] := v_amt;
  END IF;

  FOR v_i IN 1 .. v_cnt LOOP
    v_falta := v_falta || concat_ws(' y ', CASE WHEN v_names[v_i] IS NULL THEN 'el nombre del titular' END,
                                          CASE WHEN v_accts[v_i] IS NULL THEN 'la cuenta (correo o celular de EEUU)' END)
               || CASE WHEN v_names[v_i] IS NULL OR v_accts[v_i] IS NULL
                       THEN CASE WHEN v_cnt > 1 THEN ' del destinatario ' || v_i ELSE '' END || '; ' ELSE '' END;
    v_lista := CASE WHEN v_i = 1 THEN '' ELSE v_lista END
               || CASE WHEN v_i = 1 THEN '' ELSE '; ' END || v_i || ') ' || coalesce(v_names[v_i], '(falta nombre)') || ' / '
               || coalesce(v_accts[v_i], '(falta cuenta)') || CASE WHEN v_amts[v_i] IS NOT NULL THEN ' / ' || trim_scale(v_amts[v_i])::text || ' USD' ELSE '' END;
  END LOOP;
  v_falta := rtrim(v_falta, '; ');

  IF NOT v_cambio THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: esos datos ya estaban guardados'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END)::text;
    RETURN;
  END IF;

  -- (336) Register everything; never block. When every recipient in force has
  -- an amount, the destination total is their sum and the objective is
  -- re-targeted to what that sum needs in GYD, so the panel shows the gap.
  IF v_r.o_op IS NOT NULL AND v_cnt > 0 THEN
    v_sum := 0; v_hueco := false;
    FOR v_i IN 1 .. v_cnt LOOP
      IF v_amts[v_i] IS NULL THEN v_hueco := true; ELSE v_sum := v_sum + v_amts[v_i]; END IF;
    END LOOP;
    IF NOT v_hueco AND v_sum > 0 THEN
      UPDATE remittance_operations
         SET quoted_destination_amount = v_sum,
             destination_currency = 'USD'
       WHERE id = v_r.o_op
         AND quoted_destination_amount IS DISTINCT FROM v_sum;
      PERFORM cerebro_fijar_objetivo(p_conv, v_sum, 'USD');
      SELECT f.depositado INTO v_dep FROM cerebro_fondos_operacion(v_r.o_op) f;
      v_need := round(v_sum * coalesce(cerebro_tasa_zelle(floor(v_sum)), 0));
      IF v_need > coalesce(v_dep, 0) THEN
        v_aviso := ' AVISO: los destinatarios suman ' || trim_scale(v_sum)::text || ' USD y el deposito cubre '
                   || trim_scale(coalesce(v_dep, 0))::text || ' GYD; faltan '
                   || trim_scale(v_need - coalesce(v_dep, 0))::text || ' GYD para completarlo.';
      END IF;
    END IF;
  END IF;
  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  IF v_cnt = 1 AND v_amts[1] IS NULL THEN
    v_block := CASE WHEN v_tiene THEN 'BENEFICIARIO ZELLE ACTUALIZADO - reemplaza al anterior' ELSE 'BENEFICIARIO ZELLE' END
               || E'\nNombre: ' || coalesce(v_names[1], '-') || E'\nCuenta Zelle: ' || coalesce(v_accts[1], '-');
  ELSE
    FOR v_i IN 1 .. v_cnt LOOP
      v_lineas := v_lineas || E'\n' || v_i || ') Nombre: ' || coalesce(replace(replace(v_names[v_i], E'\n', ' '), E'\r', ' '), '-')
                  || ' | Cuenta Zelle: ' || coalesce(replace(replace(v_accts[v_i], E'\n', ' '), E'\r', ' '), '-')
                  || ' | Recibe: ' || CASE WHEN v_amts[v_i] IS NOT NULL THEN trim_scale(v_amts[v_i])::text || ' USD' ELSE '-' END;
    END LOOP;
    v_block := 'ZELLE VARIOS DESTINATARIOS' || v_lineas;
  END IF;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op, v_block);

  RETURN QUERY SELECT v_deal, (
    CASE WHEN v_cnt = 1 AND v_amts[1] IS NULL THEN 'guardado: titular ' || coalesce(v_name, '(falta)') || ', cuenta ' || coalesce(v_acc, '(falta)')
         ELSE 'guardado (destinatario ' || v_k || ' de ' || v_cnt || '): titular ' || coalesce(v_name, '(falta)') || ', cuenta ' || coalesce(v_acc, '(falta)')
              || CASE WHEN v_amt IS NOT NULL THEN ', monto ' || trim_scale(v_amt)::text || ' USD' ELSE '' END END
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente.' ELSE '. Completo.' END
    || CASE WHEN v_cnt > 1 THEN ' Destinatarios Zelle ahora: ' || v_lista || '.' ELSE '' END
    || CASE WHEN v_legacy_replace THEN ' (Reemplazo al destinatario anterior; si es OTRA persona, no una correccion, vuelve a llamar con agregar=true.)' ELSE '' END || v_aviso)::text;
END $function$;

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

CREATE OR REPLACE FUNCTION public.cerebro_guardar_reparto(p_conv uuid, p_t1 text, p_c1 text, p_m1 text, p_t2 text, p_c2 text, p_m2 text, p_t3 text, p_c3 text, p_m3 text, p_exec text, p_op uuid DEFAULT NULL::uuid, p_tool text DEFAULT 'registrar_reparto_multiple'::text)
 RETURNS TABLE(deal_id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_t text[] := ARRAY[cerebro_norm_tarjeta(p_t1), cerebro_norm_tarjeta(p_t2), cerebro_norm_tarjeta(p_t3)];
  v_c text[] := ARRAY[cerebro_norm_celular_cu(p_c1), cerebro_norm_celular_cu(p_c2), cerebro_norm_celular_cu(p_c3)];
  v_m text[] := ARRAY[NULLIF(btrim(coalesce(p_m1, '')), ''), NULLIF(btrim(coalesce(p_m2, '')), ''), NULLIF(btrim(coalesce(p_m3, '')), '')];
  v_pend text;
  v_r record; v_tiene boolean; v_deal uuid;
  v_ct text[] := ARRAY[NULL, NULL, NULL]; v_cc text[] := ARRAY[NULL, NULL, NULL];
  v_ca text[] := ARRAY[NULL, NULL, NULL];   -- saved share, as written in the block ("15000 CUP", "30 USD Clasica", "- USD Clasica")
  v_nt text[]; v_nc text[]; v_na text[];
  v_k int; v_num text; v_riel text; v_err text := '';
  v_lineas text := ''; v_resumen text := ''; v_falta text := ''; v_cambio boolean := false;
  v_b record;
  -- (358) guard against the verified deposit
  v_dsp record; v_nuevo boolean; v_slots int := 0; v_con int := 0; v_ncup int := 0; v_nusd int := 0;
  v_amt numeric; v_sum_gyd numeric := 0; v_sum_cup numeric := 0; v_sum_usd numeric := 0; v_tol numeric; v_rem numeric;
  v_suman text; v_aviso text := ''; v_s record;
BEGIN
  FOR v_k IN 1..3 LOOP
    IF v_t[v_k] = '!' THEN v_err := v_err || 'La tarjeta ' || v_k || ' tiene que tener 16 digitos. '; END IF;
    IF v_c[v_k] = '!' THEN v_err := v_err || 'El celular ' || v_k || ' no es un celular cubano (8 digitos, empieza por 5 o 63). '; END IF;
  END LOOP;
  -- Shares: "45000 CUP" (CUP card), "30 USD clasica|tropical"; a bare USD amount takes the rail
  -- the customer named (cerebro_destino_pendiente) or is refused; a bare number is CUP. (174)
  SELECT CASE dp.tipo WHEN 'clasica' THEN 'Clasica' WHEN 'tropical' THEN 'Tropical' END INTO v_pend
    FROM cerebro_destino_pendiente dp WHERE dp.conversation_id = p_conv AND dp.actualizado > now() - interval '24 hours';
  v_na := ARRAY[NULL, NULL, NULL];
  FOR v_k IN 1..3 LOOP
    CONTINUE WHEN v_m[v_k] IS NULL;
    v_num := NULLIF(regexp_replace(v_m[v_k], '[^0-9]', '', 'g'), '');
    v_riel := CASE WHEN v_m[v_k] ~* 'tropical' THEN 'Tropical' WHEN v_m[v_k] ~* 'cl[aá]sica' THEN 'Clasica'
                   WHEN v_m[v_k] ~* '(usd|d[oó]lar)' THEN coalesce(v_pend, '?') END;
    IF v_riel = '?' THEN
      v_err := v_err || 'El monto ' || v_k || ' esta en dolares pero no dice si es tarjeta Clasica o Tropical: preguntaselo al cliente. ';
    ELSIF v_riel IS NOT NULL THEN
      v_na[v_k] := coalesce(v_num, '-') || ' USD ' || v_riel;
    ELSIF v_num IS NOT NULL THEN
      v_na[v_k] := v_num || ' CUP';
    END IF;
  END LOOP;
  IF v_err <> '' THEN
    RETURN QUERY SELECT NULL::uuid, ('ERROR: no se guardo nada. ' || v_err || 'Pide el dato que falta con naturalidad.')::text;
    RETURN;
  END IF;
  IF (SELECT bool_and(x IS NULL) FROM unnest(v_t || v_c || v_na) x) THEN
    RETURN QUERY SELECT NULL::uuid, 'sin cambios: no llego ningun dato'::text; RETURN;
  END IF;

  -- (184) cerebro_guardar_beneficiario patches a slot of the reparto of the operation it resolved.
  SELECT * INTO v_r FROM cerebro_resolver_para_guardar(p_conv, p_tool, p_exec,
                                                        jsonb_build_array(p_t1, p_c1, p_m1, p_t2, p_c2, p_m2, p_t3, p_c3, p_m3), p_op);
  IF v_r.o_ambigua THEN
    RETURN QUERY SELECT NULL::uuid, 'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text;
    RETURN;
  END IF;

  -- The reparto saved now, slot by slot.
  FOR v_b IN
    SELECT b.position, b.card_number, b.phone, b.amount, b.currency, b.beneficiary_type
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_r.o_op AND b.status = 'vigente'
       AND b.beneficiary_type IN ('multiple_distribution', 'clasica', 'tropical') AND b.position BETWEEN 1 AND 3
  LOOP
    v_ct[v_b.position] := v_b.card_number; v_cc[v_b.position] := v_b.phone;
    v_ca[v_b.position] := CASE WHEN v_b.beneficiary_type IN ('clasica', 'tropical')
                               THEN coalesce(trim(to_char(v_b.amount, 'FM999999999')), '-') || ' USD ' || initcap(v_b.beneficiary_type)
                               WHEN v_b.amount IS NOT NULL THEN trim(to_char(v_b.amount, 'FM999999999')) || ' CUP' END;
  END LOOP;

  -- (358) Is this call setting at least one amount? (decided before the merge with the saved slots)
  v_nuevo := EXISTS (SELECT 1 FROM unnest(v_na) x WHERE x ~ '^[0-9]');

  -- D1 per slot: a different card in a slot starts without phone and share; otherwise patch.
  v_nt := v_ct; v_nc := v_cc;
  FOR v_k IN 1..3 LOOP
    IF v_t[v_k] IS NOT NULL AND v_ct[v_k] IS NOT NULL AND v_t[v_k] <> v_ct[v_k] THEN
      v_nt[v_k] := v_t[v_k]; v_nc[v_k] := v_c[v_k]; v_na[v_k] := v_na[v_k];
    ELSE
      v_nt[v_k] := coalesce(v_t[v_k], v_ct[v_k]); v_nc[v_k] := coalesce(v_c[v_k], v_cc[v_k]);
      v_na[v_k] := coalesce(v_na[v_k], v_ca[v_k]);
    END IF;
    IF v_nt[v_k] IS DISTINCT FROM v_ct[v_k] OR v_nc[v_k] IS DISTINCT FROM v_cc[v_k] OR v_na[v_k] IS DISTINCT FROM v_ca[v_k] THEN
      v_cambio := true;
    END IF;
    CONTINUE WHEN v_nt[v_k] IS NULL AND v_nc[v_k] IS NULL AND v_na[v_k] IS NULL;
    v_lineas := v_lineas || E'\n' || v_k || ') Tarjeta: ' || coalesce(v_nt[v_k], '-') || ' | Celular: ' || coalesce(v_nc[v_k], '-')
                || ' | Recibe: ' || coalesce(v_na[v_k], '-');
    v_resumen := v_resumen || CASE WHEN v_resumen = '' THEN '' ELSE ' | ' END
                 || v_k || ') tarjeta ' || coalesce(v_nt[v_k], '(falta)') || ', celular ' || coalesce(v_nc[v_k], '(falta)')
                 || ', recibe ' || coalesce(replace(v_na[v_k], '- ', '(falta monto) '), '(falta)');
    v_falta := v_falta || concat_ws(', ',
                 CASE WHEN v_nt[v_k] IS NULL THEN 'la tarjeta ' || v_k END,
                 CASE WHEN v_nc[v_k] IS NULL THEN 'el celular de la tarjeta ' || v_k END,
                 CASE WHEN v_na[v_k] IS NULL OR v_na[v_k] LIKE '- %' THEN 'cuanto recibe la tarjeta ' || v_k END)
               || CASE WHEN v_nt[v_k] IS NULL OR v_nc[v_k] IS NULL OR v_na[v_k] IS NULL OR v_na[v_k] LIKE '- %' THEN '; ' ELSE '' END;
  END LOOP;
  v_falta := rtrim(v_falta, '; ');

  -- (358) The merged amounts (saved + new) cannot contradict a VERIFIED deposit. Compared in GYD with the rate the bot quotes
  -- with (CUP / gyd rate, USD * usd rate); tolerance: 1 CUP per CUP card and 1 USD per USD card (per-card rounding).
  -- Over the deposit: nothing is written. Some cards without amount: saved, the reply says what is left. Every card with
  -- amount but under the deposit: saved, but never "Completo" (the leftover is a FALTA). Unverified deposit or a call
  -- without amounts (card / phone patches): exactly the previous behavior.
  IF v_nuevo AND v_r.o_op IS NOT NULL THEN
    SELECT * INTO v_dsp FROM cerebro_reparto_disponible(v_r.o_op);
    IF v_dsp.base_gyd IS NOT NULL AND coalesce(v_dsp.tasa_cup, 0) > 0 AND coalesce(v_dsp.tasa_usd, 0) > 0 THEN
      FOR v_k IN 1..3 LOOP
        IF NOT (v_nt[v_k] IS NULL AND v_nc[v_k] IS NULL AND v_na[v_k] IS NULL) THEN v_slots := v_slots + 1; END IF;
      END LOOP;
      -- (359) the arithmetic is shared with cerebro_reparto_cuadre (the conversation context): one function, one verdict
      SELECT * INTO v_s FROM cerebro_reparto_sumas(v_na, v_slots, v_dsp.base_gyd, v_dsp.tasa_cup, v_dsp.tasa_usd);
      v_con := v_s.con; v_ncup := v_s.ncup; v_nusd := v_s.nusd; v_sum_cup := v_s.sum_cup; v_sum_usd := v_s.sum_usd;
      v_sum_gyd := v_s.sum_gyd; v_tol := v_s.tol; v_rem := v_s.rem;
      v_suman := concat_ws(' + ', CASE WHEN v_ncup > 0 THEN trim_scale(v_sum_cup)::text || ' CUP' END,
                                  CASE WHEN v_nusd > 0 THEN trim_scale(v_sum_usd)::text || ' USD' END)
                 || CASE WHEN v_nusd > 0 THEN ', que equivalen a ' || trim_scale(round(v_sum_gyd))::text || ' GYD' ELSE '' END;
      IF v_s.estado = 'excede' THEN
        RETURN QUERY SELECT NULL::uuid, ('NO SE GUARDO NADA: el deposito verificado de este envio es ' || trim_scale(v_dsp.base_gyd)::text
          || ' GYD = ' || trim_scale(v_dsp.total_cup)::text || ' CUP (o ' || trim_scale(v_dsp.total_usd)::text
          || ' USD en tarjeta Clasica/Tropical) y los montos de las tarjetas suman ' || v_suman
          || '. Eso es mas de lo que deposito el cliente: preguntale como quiere repartir ese total entre las tarjetas. No se cambio nada.')::text;
        RETURN;
      ELSIF v_s.estado = 'faltan_montos' THEN
        v_aviso := CASE WHEN v_rem > v_tol
          THEN ' Del deposito verificado (' || trim_scale(v_dsp.base_gyd)::text || ' GYD = ' || trim_scale(v_dsp.total_cup)::text
               || ' CUP) ya asignaste ' || v_suman || ': quedan ' || trim_scale(round(v_rem * v_dsp.tasa_cup))::text
               || ' CUP para las demas tarjetas (o unos ' || trim_scale(floor(v_rem / v_dsp.tasa_usd))::text || ' USD si alguna es Clasica/Tropical).'
          ELSE ' Los montos que ya asignaste (' || v_suman || ') cubren todo el deposito verificado (' || trim_scale(v_dsp.base_gyd)::text
               || ' GYD): no queda nada para las tarjetas sin monto; preguntale al cliente como ajusta el reparto.' END;
      ELSIF v_s.estado = 'sobra' THEN
        v_falta := concat_ws('; ', NULLIF(v_falta, ''), 'sobran ' || trim_scale(round(v_rem * v_dsp.tasa_cup))::text
          || ' CUP del deposito verificado (' || trim_scale(v_dsp.base_gyd)::text || ' GYD = ' || trim_scale(v_dsp.total_cup)::text
          || ' CUP): pide al cliente que reparta todo el deposito o que diga que hacer con ese monto');
      END IF;
    END IF;
  END IF;

  IF NOT v_cambio THEN
    RETURN QUERY SELECT NULL::uuid, ('sin cambios: ese reparto ya estaba guardado'
      || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta ELSE '' END || v_aviso)::text;
    RETURN;
  END IF;

  SELECT EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = v_r.o_op) INTO v_tiene;
  v_deal := cerebro_escribir_bloque_beneficiario(p_conv, v_r.o_op,
      CASE WHEN v_tiene THEN 'REPARTO ACTUALIZADO ENTRE VARIOS BENEFICIARIOS - reemplaza lo anterior'
           ELSE 'REPARTO ENTRE VARIOS BENEFICIARIOS' END || v_lineas);
  RETURN QUERY SELECT v_deal, ('reparto guardado: ' || v_resumen
    || CASE WHEN v_falta <> '' THEN '. FALTA: ' || v_falta || '. Pideselo al cliente, una pregunta por mensaje.' ELSE '. Completo.' END
    || v_aviso)::text;
END $function$;

DROP FUNCTION IF EXISTS public.cerebro_guardia_envio_nuevo(uuid, text[], text[], text[]);
DROP FUNCTION IF EXISTS public._cerebro_envio_abierto_ahora(uuid);
DROP FUNCTION IF EXISTS public._cerebro_auditar_envio_abierto(uuid, text);
DROP FUNCTION IF EXISTS public._cerebro_senal_envio_nuevo(uuid, timestamp with time zone, boolean);
DROP FUNCTION IF EXISTS public._cerebro_completada_reciente(uuid);
