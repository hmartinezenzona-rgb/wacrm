-- ROLLBACK for 385: restores the live public.cerebro_cambiar_servicio(uuid,text,text) body verbatim (md5 8f14eff534d36b450724f25d0f7e124d); no other object changed.

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
  -- (341) The amount separates a recarga from a saldo movil, whatever the word.
  v_servicio := cerebro_servicio_por_monto(p_conversation_id, v_servicio);

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
    -- (344) An incident that applied nothing (no_aplica) and holds no money is correctable.
    IF v_o.status NOT IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer')
       AND NOT cerebro_op_recuperable(v_op) THEN
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
END $function$

;
