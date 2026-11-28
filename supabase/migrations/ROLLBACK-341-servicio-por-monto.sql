-- ROLLBACK 341: restore cambiar_servicio and the recarga number tool, drop the helper.

DROP FUNCTION IF EXISTS public.cerebro_servicio_por_monto(uuid, text);

CREATE OR REPLACE FUNCTION public.cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_actor      constant text := 'automation:cerebro_cambiar_servicio';
  v_raw        text := lower(btrim(coalesce(p_servicio, '')));
  v_servicio   text;
  v_ids        uuid[];
  v_op         uuid;
  v_o          remittance_operations%ROWTYPE;
  v_status     text;
  v_actual     text;
  v_key        text;
  v_core       jsonb;
  v_result     jsonb;
  v_min        numeric;
  v_n          integer;
  v_prev       jsonb;
  v_prev_origin text;
  v_prev_actor  text;
  v_campo      text;
BEGIN
  v_servicio := CASE v_raw WHEN 'cup' THEN 'cuban_card' WHEN 'efectivo' THEN 'efectivo_usd' ELSE v_raw END;

  <<flow>>
  BEGIN
    IF v_servicio NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'servicio_desconocido');
      EXIT flow;
    END IF;

    -- (231) One writer at a time per conversation between this tool and the creation of an operation (the AFTER INSERT trigger takes the
    -- same lock): "pending written while the operation is being created" cannot be lost. Held to the end of the transaction.
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_destino_pendiente:' || p_conversation_id::text, 0));

    -- The conversation's open operation, the way the bot's other writers find it.
    SELECT coalesce(array_agg(o.id ORDER BY o.created_at), ARRAY[]::uuid[]) INTO v_ids
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'incident');
    IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
      -- (231) No OPEN operation. Only an operation that is open but in a state that forbids the change (transferring) refuses; a completed /
      -- cancelled one (a repeat customer) is "no operation": the choice is for the NEW remittance and is recorded below.
      SELECT o.id, o.status INTO v_op, v_status
        FROM remittance_operations o WHERE o.conversation_id = p_conversation_id AND o.status = 'transferring' ORDER BY o.created_at DESC LIMIT 1;
      IF v_op IS NULL THEN
        IF v_servicio IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd')
           AND EXISTS (SELECT 1 FROM conversations c WHERE c.id = p_conversation_id) THEN
          -- (231) No operation yet (the customer says "mejor zelle" before the receipt turn creates it): the agent's declared service is
          -- the conversation's pending destination; the operation that is created next takes it (cerebro_destino_agente_al_crear).
          PERFORM set_config('wacrm.pendiente_origen', 'agente', true);
          INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen, ejecucion)
          VALUES (p_conversation_id, v_servicio, now(), 'agente', nullif(btrim(coalesce(p_execution_id, '')), ''))
          ON CONFLICT (conversation_id) DO UPDATE
             SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado, origen = 'agente', ejecucion = EXCLUDED.ejecucion;
          PERFORM set_config('wacrm.pendiente_origen', '', true);
          v_result := jsonb_build_object('ok', true, 'changed', false, 'pendiente', true, 'servicio', v_servicio);
        ELSE
          -- recarga / combo / visa / saldo are not remesa rails: nothing to declare ahead of the operation.
          v_result := jsonb_build_object('ok', false, 'reason', 'sin_operacion', 'pendiente', false);
        END IF;
      ELSE
        v_result := jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_status, 'operation_id', v_op);
      END IF;
      EXIT flow;
    END IF;
    IF array_length(v_ids, 1) > 1 THEN
      -- The same hand-over as cerebro_marcar_destino_usd: several open operations need a person.
      SELECT count(*) INTO v_n FROM cerebro_registrar_derivacion(
        p_conversation_id, 'Hay varias operaciones abiertas y el caso requiere revisión humana.', 'operacion_ambigua', true);
      v_result := jsonb_build_object('ok', false, 'reason', 'operacion_ambigua', 'derivado', v_n > 0);
      EXIT flow;
    END IF;
    v_op := v_ids[1];

    -- Same row lock as the panel; the status is read again under it.
    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op FOR UPDATE;
    IF v_o.status NOT IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'estado_no_permite', 'status', v_o.status, 'operation_id', v_op);
      EXIT flow;
    END IF;
    IF v_o.service_type NOT IN ('remesa', 'recarga', 'combo', 'visa', 'saldo') THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'tipo_no_soportado', 'service_type', v_o.service_type, 'operation_id', v_op);
      EXIT flow;
    END IF;

    -- (231) The operation exists: a pending service the agent declared earlier has done its job, and must not stand in for the operation's
    -- rail (cerebro_riel_op falls back to the pending row when the operation has no rail yet).
    DELETE FROM cerebro_destino_pendiente WHERE conversation_id = p_conversation_id AND origen = 'agente';

    v_actual := cerebro_riel_op(v_op);
    v_prev := jsonb_build_object('servicio', v_actual, 'destination_amount', v_o.quoted_destination_amount,
                                 'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate);
    IF v_actual IS NOT DISTINCT FROM v_servicio THEN
      v_result := jsonb_build_object('ok', true, 'changed', false, 'operation_id', v_op, 'servicio', v_servicio,
                                     'source_amount_gyd', v_o.quoted_source_amount, 'destination_amount', v_o.quoted_destination_amount,
                                     'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate,
                                     'status', v_o.status);
      EXIT flow;
    END IF;

    -- A human fixed it: leave it to the team. A lock the automation itself left does not count.
    SELECT k INTO v_campo
      FROM unnest(ARRAY['delivery_method', 'service_type', 'quoted_destination_amount']) AS k
     WHERE coalesce(v_o.admin_locked_fields, '{}'::jsonb) ? k
       AND coalesce(v_o.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%'
     LIMIT 1;
    IF v_campo IS NOT NULL THEN
      v_result := jsonb_build_object('ok', false, 'reason', 'bloqueado_por_humano', 'campo', v_campo, 'operation_id', v_op);
      EXIT flow;
    END IF;

    -- The change, with the minimum of the NEW service checked on the changed operation; a failure rolls the sub-block back.
    v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
    v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
    BEGIN
      PERFORM set_config('wacrm.origin', 'admin', true);
      PERFORM set_config('wacrm.actor', c_actor, true);
      v_core := _cambiar_servicio_core(v_op, v_servicio, 'automation_service_change', c_actor,
                                       'n8n execution ' || coalesce(nullif(btrim(p_execution_id), ''), 'unknown'));
      PERFORM set_config('wacrm.origin', v_prev_origin, true);
      PERFORM set_config('wacrm.actor', v_prev_actor, true);
      SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
      v_min := cerebro_minimo_gyd(v_op);
      IF coalesce(v_o.quoted_source_amount, 0) > 0 AND v_min IS NOT NULL AND v_o.quoted_source_amount < v_min THEN
        RAISE EXCEPTION '%', v_min USING ERRCODE = 'WC230';
      END IF;
    EXCEPTION
      WHEN SQLSTATE 'WC230' THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        v_result := jsonb_build_object('ok', false, 'reason', 'por_debajo_del_minimo', 'servicio', v_servicio, 'operation_id', v_op,
                                       'minimo_gyd', SQLERRM::numeric, 'source_amount_gyd', v_o.quoted_source_amount);
      WHEN SQLSTATE '22023' THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        IF SQLERRM NOT LIKE 'several recipients%' THEN RAISE; END IF;
        v_result := jsonb_build_object('ok', false, 'reason', 'varios_destinatarios', 'operation_id', v_op);
      WHEN OTHERS THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        RAISE;
    END;
    IF v_result IS NOT NULL THEN
      EXIT flow;
    END IF;

    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
    v_result := jsonb_build_object('ok', true, 'changed', true, 'operation_id', v_op, 'servicio', v_servicio,
                                   'source_amount_gyd', v_o.quoted_source_amount, 'destination_amount', v_o.quoted_destination_amount,
                                   'destination_currency', v_o.destination_currency, 'rate', v_o.quoted_destination_rate,
                                   'previous', v_prev,
                                   'retired_recipients', jsonb_array_length(v_core -> 'retired'),
                                   'retyped_recipients', jsonb_array_length(v_core -> 'retyped'),
                                   'status', v_o.status);
  END;

  v_key := coalesce(nullif(btrim(p_execution_id), ''), gen_random_uuid()::text) || ':cambiar_servicio:' || md5(coalesce(v_servicio, ''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (v_key, 'cambiar_servicio', p_execution_id, p_conversation_id, v_op, jsonb_build_array(to_jsonb(p_servicio)),
          CASE WHEN (v_result ->> 'ok')::boolean THEN
                 CASE WHEN coalesce((v_result ->> 'pendiente')::boolean, false) THEN 'pendiente'
                      WHEN (v_result ->> 'changed')::boolean THEN 'changed' ELSE 'unchanged' END
               ELSE v_result ->> 'reason' END)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_result;
END $function$;

CREATE OR REPLACE FUNCTION public.crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false, p_actor text DEFAULT NULL::text, p_accion text DEFAULT 'agregar'::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- (201) The Cuban mobile numbers found in p_texto go to the conversation's open recharge, one row per number
-- (beneficiary_type 'recarga'), without repeats; the panel's beneficiary lock wins. Returns what was saved and how many
-- numbers the recharge still needs (cerebro_recarga_unidades of its deposit).
DECLARE
  v_op     record;
  v_m      text[];
  v_num    text;
  v_added  int := 0;
  v_have   int;
  v_need   int;
  v_pos    int;
  v_block  int;
  v_accion text := lower(btrim(coalesce(p_accion, 'agregar')));
  v_removed int := 0;
  v_price  numeric;
  v_res    jsonb;
  v_missing text[] := ARRAY[]::text[];
  v_nid    uuid;
  -- (268) the real actor of the write (the agent's tool passes its own name); the default is the bot's automation
  v_actor  text := coalesce(nullif(btrim(p_actor), ''), 'automation:registrar_numeros_recarga');
  v_source text := CASE WHEN coalesce(nullif(btrim(p_actor), ''), 'automation:registrar_numeros_recarga') LIKE 'automation:%'
                        THEN 'reparto_auto' ELSE 'agente' END;
BEGIN
  IF v_accion NOT IN ('agregar', 'quitar') THEN
    RETURN 'ERROR: la accion debe ser agregar o quitar. No se cambio nada.';
  END IF;

  -- (282) 'quitar': the numbers named in p_texto leave the open recharge (they are retired, not deleted: status 'reemplazado').
  IF v_accion = 'quitar' THEN
    SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields, o.status INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1
     FOR UPDATE;
    IF v_op.id IS NULL THEN
      RETURN 'sin recarga en curso: no hay ningun numero de recarga que quitar';
    END IF;
    IF v_op.status = 'transferring' THEN
      RETURN 'la recarga ya esta en transferencia: no quito numeros, una persona lo revisa';
    END IF;
    IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
      RETURN 'los numeros de esta recarga los gestiona una persona desde el panel: no se cambian';
    END IF;
    FOR v_m IN SELECT regexp_matches(coalesce(p_texto, ''),
                                     '(?<![0-9])(?:\+?53[ -]?([56])[ .-]?([0-9]{3})|([56])([0-9]{3}))[ .-]?([0-9]{4})(?![0-9])', 'g') LOOP
      v_num := coalesce(v_m[1] || v_m[2], v_m[3] || v_m[4]) || v_m[5];
      v_nid := NULL;
      UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now()
       WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga' AND phone = v_num
      RETURNING id INTO v_nid;
      IF v_nid IS NOT NULL THEN v_removed := v_removed + 1; ELSE v_missing := v_missing || v_num; END IF;
    END LOOP;
    IF v_removed > 0 THEN
      UPDATE remittance_beneficiaries b SET position = r.n
        FROM (SELECT id, row_number() OVER (ORDER BY position, id) AS n FROM remittance_beneficiaries
               WHERE operation_id = v_op.id AND status = 'vigente') r
       WHERE b.id = r.id AND b.position IS DISTINCT FROM r.n;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
      VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'recarga_numbers', 'agent_recharge_number_removed',
              v_actor, NULL, jsonb_build_object('removed', v_removed, 'texto', left(coalesce(p_texto, ''), 300)));
    END IF;
    SELECT count(*) INTO v_have FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga';
    v_need := cerebro_recarga_unidades(v_op.quoted_source_amount);
    -- (292) the LAST number left an empty recarga: the recarga has nothing to do, so it is cancelled in this same call (no orphan open operation).
    -- With money (deposit / receipt), in a split group or with a lock a person left, it stays open: a person handles it.
    IF v_removed > 0 AND v_have = 0 THEN
      IF _cerebro_op_tiene_dinero(v_op.id)
         OR EXISTS (SELECT 1 FROM remittance_operations x WHERE x.id = v_op.id AND x.mixed_group_id IS NOT NULL) THEN
        RETURN 'quitados ' || v_removed || ' numero(s) de recarga; ya no queda ninguno, pero la recarga tiene un deposito o comprobante registrado: '
               || 'NO la cancelo, sigue abierta y una persona se encarga del dinero. Dile al cliente que un companero lo revisa.';
      END IF;
      IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) <> '{}'::jsonb THEN
        RETURN 'quitados ' || v_removed || ' numero(s) de recarga; ya no queda ninguno, pero una persona toco esta recarga desde el panel: '
               || 'NO la cancelo, sigue abierta y una persona se encarga. Dile al cliente que un companero lo revisa.';
      END IF;
      v_res := cerebro_modificar_operacion(p_conv, v_op.id, 'cancelar', NULL, v_actor);
      IF coalesce(v_res ->> 'ok', 'false') = 'true' THEN
        RETURN 'quitados ' || v_removed || ' numero(s) de recarga; era el ultimo, asi que la recarga quedo CANCELADA (no tenia dinero). '
               || 'Avisale al cliente que la recarga se cancelo.'
               || CASE WHEN coalesce((v_res ->> 'operaciones_abiertas')::int, 0) = 0 THEN ' No queda ninguna operacion abierta.'
                       ELSE ' Quedan ' || (v_res ->> 'operaciones_abiertas') || ' operacion(es) abierta(s).' END;
      END IF;
      RETURN 'quitados ' || v_removed || ' numero(s) de recarga; ya no queda ninguno y no pude cancelar la recarga: sigue abierta y una persona la revisa. '
             || coalesce(v_res ->> 'mensaje', '');
    END IF;
    RETURN CASE WHEN v_removed = 0 AND cardinality(v_missing) = 0 THEN 'no vi ningun numero cubano en el texto: no se quito nada; la recarga tiene ' || v_have || '.'
                ELSE 'quitados ' || v_removed || ' numero(s) de recarga; la recarga tiene ' || v_have || '.' END
           || CASE WHEN cardinality(v_missing) > 0 THEN ' No estaban en la recarga: ' || array_to_string(v_missing, ', ') || '.' ELSE '' END
           || CASE WHEN coalesce(v_need, 0) = 0 THEN ''
                   WHEN v_have >= v_need THEN ' Numeros completos (' || v_have || ' de ' || v_need || ').'
                   ELSE ' FALTA ' || (v_need - v_have) || ' numero(s) de recarga (son ' || v_need || ' recargas, un numero por recarga). Pideselo al cliente.' END;
  END IF;

  SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
   ORDER BY o.created_at DESC LIMIT 1
   FOR UPDATE;
  IF v_op.id IS NULL THEN
    -- (202) The customer asked for a recharge: it opens now (collecting its numbers), so the panel shows it before
    -- the deposit; the deposit lands on it (cerebro_registrar_deposito).
    -- (204) p_abrir: the agent understood a recharge (e.g. asked for by AUDIO, which the typed-text rule cannot see).
    -- (268) or the agent declared a recharge (cerebro_servicio_declarado). Words never open it.
    IF NOT (p_abrir OR EXISTS (SELECT 1 FROM cerebro_servicio_declarado d
                                WHERE d.conversation_id = p_conv AND d.servicio = 'recarga')) THEN
      RETURN 'sin recarga en curso: no se guarda ningun numero de recarga';
    END IF;
    -- (207) A new recharge opens only with a promo running or a confirmed one ahead (booked for its start date): with
    -- neither, the bot was asking for a number for a recharge nobody could do. Nothing is saved then.
    IF NOT EXISTS (SELECT 1 FROM cerebro_promo_vigente()) AND NOT EXISTS (SELECT 1 FROM cerebro_promo_proxima()) THEN
      RETURN 'NO HAY PROMOCION DE ETECSA, ni vigente ni anunciada: no se abre ninguna recarga y no se guarda ningun numero. '
             || 'PROHIBIDO pedir el numero de Cuba. Ofrece pasar con un operador.';
    END IF;
    -- (268) The resolver decides the service under the conversation lock (the one cerebro_aplicar_servicio takes). A
    -- remesa holder that the deposit covers becomes the recharge; the operation is then read again (no second one).
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
    -- (283) only when money is registered: a service change is allowed without money since 283, but opening a recharge must not turn an empty
    -- operation of another service into it (a mixed send before the deposit keeps its parts separate, 276).
    IF EXISTS (SELECT 1 FROM remittance_operations x
                WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled')
                  AND (EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = x.id)
                       OR EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = x.id AND d.anulado_en IS NULL AND d.descartado_en IS NULL))
                  -- (339) A funded operation that already carries a recipient of
                  -- another service must not become the recharge: the change would
                  -- retire that recipient. The recarga opens as its own part.
                  AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                                   WHERE b.operation_id = x.id AND b.status = 'vigente'
                                     AND b.beneficiary_type <> 'recarga')) THEN
      PERFORM cerebro_aplicar_servicio(p_conv, 'recarga', 'cambiar', v_actor, NULL);
    END IF;
    SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at DESC LIMIT 1
     FOR UPDATE;
    IF v_op.id IS NULL THEN
      -- (268) Another open operation exists and the resolver did not convert it: no second operation is created.
      -- (276) ... unless every open operation is still EMPTY (collecting, no deposit, no receipt, no money, not in a mixed group): the
      -- recharge is then one more part of a send planned before the deposit and opens as its own empty operation (the split reuses it).
      IF EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
                    AND (o.mixed_group_id IS NOT NULL OR (coalesce(o.quoted_source_amount, 0) > 0 AND NOT _cerebro_op_monto_acordado(o.id))
                         OR o.status NOT IN ('collecting_information', 'awaiting_deposit')
                         OR EXISTS (SELECT 1 FROM remittance_operation_receipts x WHERE x.operation_id = o.id)
                         OR EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.operation_id = o.id AND x.anulado_en IS NULL AND x.descartado_en IS NULL))) THEN
        RETURN coalesce(cerebro_resolver_servicio(p_conv, 'recarga', 'cambiar') ->> 'mensaje',
                        'no se abre otra recarga: la conversacion ya tiene una operacion abierta.');
      END IF;
      INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
      SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'recarga', 'GYD', 0
        FROM conversations v WHERE v.id = p_conv
      RETURNING id, account_id, quoted_source_amount, admin_locked_fields INTO v_op;
    END IF;
  END IF;
  -- (289) opening / adding recharge numbers on the agent's word IS the declaration of the recharge (latest declaration wins; cleared when the operation closes)
  IF p_abrir THEN
    PERFORM cerebro_declarar_servicio(p_conv, 'recarga', v_actor);
  END IF;
  IF coalesce(v_op.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries' THEN
    RETURN 'los numeros de esta recarga los gestiona una persona desde el panel: no se cambian';
  END IF;

  -- (268) Cuban mobiles: 8 digits written 55599180, 5559 9180, 5559-9180, or after the prefix 53 with the separators
  -- of the WhatsApp format (+53 5 5599180, +53 5 559 9180). m[1..2] = after the prefix, m[3..4] = without prefix,
  -- m[5] = the last four digits. The separator after the leading 5/6 exists only after the prefix.
  FOR v_m IN SELECT regexp_matches(coalesce(p_texto, ''),
                                   '(?<![0-9])(?:\+?53[ -]?([56])[ .-]?([0-9]{3})|([56])([0-9]{3}))[ .-]?([0-9]{4})(?![0-9])', 'g') LOOP
    v_num := coalesce(v_m[1] || v_m[2], v_m[3] || v_m[4]) || v_m[5];
    CONTINUE WHEN EXISTS (SELECT 1 FROM remittance_beneficiaries b
                           WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND b.phone = v_num);
    SELECT coalesce(max(position), 0) + 1 INTO v_pos FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente';
    SELECT coalesce(max(block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries WHERE operation_id = v_op.id;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
    VALUES (v_op.id, 'recarga', v_num, v_pos, v_block, v_source, 'vigente');
    v_added := v_added + 1;
  END LOOP;

  IF v_added > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_op.account_id, 'remittance_operations', v_op.id, 'recarga_numbers', 'automation_recharge_numbers_registered',
            v_actor, NULL, jsonb_build_object('added', v_added, 'texto', left(coalesce(p_texto, ''), 300)));
  END IF;

  SELECT count(*) INTO v_have FROM remittance_beneficiaries WHERE operation_id = v_op.id AND status = 'vigente' AND beneficiary_type = 'recarga';
  -- (293) a recarga with no agreed amount gets the live promo price (the booked one before it starts) per number it carries; never over an amount already there
  IF coalesce(v_op.quoted_source_amount, 0) = 0 THEN
    v_price := coalesce((SELECT v.precio_gyd FROM cerebro_promo_vigente() v), (SELECT p.precio_gyd FROM cerebro_promo_proxima() p));
    IF v_price > 0 THEN
      PERFORM _cerebro_fijar_monto_acordado(v_op.id, v_price * greatest(1, v_have), v_actor, true);
      SELECT o.id, o.account_id, o.quoted_source_amount, o.admin_locked_fields INTO v_op FROM remittance_operations o WHERE o.id = v_op.id;
    END IF;
  END IF;
  v_need := cerebro_recarga_unidades(v_op.quoted_source_amount);
  RETURN 'guardados ' || v_added || ' numero(s) de recarga nuevos; la recarga tiene ' || v_have || '.'
         || CASE WHEN coalesce(v_need, 0) = 0 THEN ''
                 WHEN v_have >= v_need THEN ' Numeros completos (' || v_have || ' de ' || v_need || ').'
                 ELSE ' FALTA ' || (v_need - v_have) || ' numero(s) de recarga (son ' || v_need || ' recargas, un numero por recarga). Pideselo al cliente.' END
         -- (207) Booked ahead of a confirmed promo: what to tell the customer about when it is done and paid.
         || CASE WHEN EXISTS (SELECT 1 FROM cerebro_promo_vigente()) THEN ''
                 ELSE COALESCE((SELECT format(' LA PROMOCION AUN NO EMPIEZA: la recarga queda ANOTADA PARA EL %s y se hace ese dia. '
                                              || 'Si el cliente quiere pagar ya, puede; si no, paga ese dia: no le exijas el pago ahora. '
                                              || 'PROHIBIDO decir que se hace hoy o en minutos.', to_char(p.vigente_desde, 'DD/MM'))
                                  FROM cerebro_promo_proxima() p), '') END;
END $function$;
