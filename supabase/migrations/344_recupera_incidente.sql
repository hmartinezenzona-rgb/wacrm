-- =====================================================================
-- 344 -- The bot recovers an incident that applied nothing.
--
-- PRODUCTION TEST 2026-10-28 02:12: the operation had gone to incident
-- (no_aplica) because of an amount alert on a 1,000 GYD receipt. The agent
-- understood the send (saldo movil, 360 CUP for 1,000 GYD) and called
-- cambiar_servicio('saldo'); the function refused with estado_no_permite
-- because incident was not in its allowed states, so the bot could not fix
-- what it had diagnosed. The customer's deposit stayed unused and the
-- conversation paused.
--
-- An incident that applied nothing (incident_reason 'no_aplica') and holds no
-- money (no consumed deposit, no funding allocation) is correctable: the
-- service change is allowed and the operation returns to
-- collecting_information. Anything with money attached, or any other incident
-- reason, keeps refusing for a human.
--
-- Touches cerebro_op_recuperable (new), _cambiar_servicio_core,
-- cerebro_cambiar_servicio and cerebro_resolver_servicio (the same rule in the
-- wrapper, the core and the resolver).
--
-- ROLLBACK: ROLLBACK-344-recupera-incidente.sql
-- Assertion: supabase/staging/assertions/recupera-incidente.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_op_recuperable(p_op uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT coalesce((
    SELECT o.status = 'incident'
       AND coalesce(o.incident_reason, '') = 'no_aplica'
       AND NOT EXISTS (SELECT 1 FROM depositos_mmg d
                        WHERE d.operation_id = o.id
                          AND d.anulado_en IS NULL AND d.descartado_en IS NULL)
       AND NOT EXISTS (SELECT 1 FROM funding_allocations fa WHERE fa.operation_id = o.id)
      FROM remittance_operations o WHERE o.id = p_op), false);
$function$;
REVOKE ALL ON FUNCTION public.cerebro_op_recuperable(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_op_recuperable(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public._cambiar_servicio_core(p_operation_id uuid, p_servicio text, p_audit_action text, p_actor text, p_reason text)
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
  v_single     remittance_beneficiaries%ROWTYPE;
  v_phones uuid[] := ARRAY[]::uuid[];
  v_created uuid[] := ARRAY[]::uuid[];
  v_src remittance_beneficiaries%ROWTYPE;
  v_new_id uuid;
  v_recuperable boolean := false;
BEGIN
  -- The callers have validated the service and the operation; they hold its row lock (taken again here, same transaction).
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  -- (344) An incident that applied nothing (no_aplica) and holds no money is correctable.
  v_recuperable := cerebro_op_recuperable(p_operation_id);

  v_actual := cerebro_riel_op(p_operation_id);
  IF v_actual IS NOT DISTINCT FROM v_servicio THEN
    RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', false);
  END IF;

  v_new_type := CASE WHEN v_servicio IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN v_servicio ELSE 'remesa' END;
  v_new_dm   := CASE WHEN v_new_type = 'remesa' THEN v_servicio END;

  -- Which current recipients fit the new service (a card rail also takes multiple_distribution on CUP).
  SELECT count(*) INTO v_fit
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
     AND CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
              WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
              WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
              WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
              WHEN v_servicio = 'mexico' THEN b.beneficiary_type IN ('mexico_cuenta', 'mexico_retiro')
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

  -- (266) Every phone-only recipient (a Cuban mobile, no card, no Zelle account, no cash address) is a number of the
  -- recarga / saldo (a recarga may go to several numbers): they are kept and re-typed below instead of being retired.
  -- Recipients with card / Zelle / cash data retire as before.
  IF v_servicio IN ('recarga', 'saldo') THEN
    SELECT coalesce(array_agg(b.id), ARRAY[]::uuid[]) INTO v_phones
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND nullif(btrim(coalesce(b.phone, '')), '') IS NOT NULL
       AND nullif(btrim(coalesce(b.card_number, '')), '') IS NULL
       AND nullif(btrim(coalesce(b.zelle_account, '')), '') IS NULL
       AND nullif(btrim(coalesce(b.address, '')), '') IS NULL
       AND b.beneficiary_type NOT IN ('zelle', 'efectivo_usd', 'combo', 'mexico_cuenta', 'mexico_retiro');
  END IF;

  v_before := jsonb_build_object(
    'service', v_actual, 'service_type', v_op.service_type, 'delivery_method', v_op.delivery_method,
    'destination_currency', v_op.destination_currency, 'quoted_destination_amount', v_op.quoted_destination_amount,
    'combo_costo_gyd', v_op.combo_costo_gyd,
    'recipients', (SELECT coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'type', b.beneficiary_type) ORDER BY b.position), '[]'::jsonb)
                     FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente'));

  -- (286) To cash: no recipient of the operation can receive cash (a card, a Zelle account). The customer's data stays consistent: the first
  -- recipient that carries a name or a phone gives them to a new cash recipient (the card / account itself is retired below, the cash rail cannot use it).
  -- What the cash delivery still needs (phone, address) is asked from the answer of the caller.
  -- Only for the bot (agent / automation callers): the panel's human flow adds the cash recipient itself (crm_agregar_beneficiario).
  IF v_servicio = 'efectivo_usd' AND v_fit = 0 AND p_audit_action IN ('agent_service_change', 'automation_service_change') THEN
    SELECT * INTO v_src FROM remittance_beneficiaries b
     WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
       AND (nullif(btrim(coalesce(b.name, '')), '') IS NOT NULL OR nullif(btrim(coalesce(b.phone, '')), '') IS NOT NULL)
     ORDER BY b.position, b.id LIMIT 1;
    IF v_src.id IS NOT NULL THEN
      INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, position, block_index, source, status)
      VALUES (p_operation_id, 'efectivo_usd', nullif(btrim(coalesce(v_src.name, '')), ''), nullif(btrim(coalesce(v_src.phone, '')), ''), 1,
              (SELECT coalesce(max(x.block_index), 0) + 1 FROM remittance_beneficiaries x WHERE x.operation_id = p_operation_id), 'agente', 'vigente')
      RETURNING id INTO v_new_id;
      v_created := v_created || v_new_id;
      v_fit := 1;
    END IF;
  END IF;

  -- 1. The operation: new service, quote cleared, rail locked against the bot. The 096 guard locks the changed
  --    destination fields for a human writer; they are released right after (2).
  UPDATE remittance_operations
     SET service_type = v_new_type,
         delivery_method = v_new_dm,
         -- (344) The corrected incident stops being an incident.
         status = CASE WHEN v_recuperable THEN 'collecting_information' ELSE status END,
         incident_reason = CASE WHEN v_recuperable THEN NULL ELSE incident_reason END,
         -- (273) a Mexico send is paid out in MXN (the amount is the operator's daily rate, never stored)
         destination_currency = CASE WHEN v_new_type = 'mexico' THEN 'MXN' END,
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
       AND NOT (b.id = ANY (v_phones))
       AND NOT CASE WHEN v_servicio IN ('cuban_card', 'clasica', 'tropical') THEN b.beneficiary_type = ANY (v_card_types)
                    WHEN v_servicio = 'zelle' THEN b.beneficiary_type = 'zelle'
                    WHEN v_servicio = 'efectivo_usd' THEN b.beneficiary_type = 'efectivo_usd'
                    WHEN v_servicio = 'combo' THEN b.beneficiary_type = 'combo'
                    WHEN v_servicio = 'mexico' THEN b.beneficiary_type IN ('mexico_cuenta', 'mexico_retiro')
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
  ELSIF cardinality(v_phones) > 0 THEN
    -- (266) recarga and saldo recipients are both stored as beneficiary_type 'recarga' (223): the mobile becomes the number.
    WITH k AS (
      UPDATE remittance_beneficiaries b
         SET beneficiary_type = 'recarga', amount = NULL, currency = NULL, amount_origin = NULL, delivery_method = NULL
       WHERE b.id = ANY (v_phones)
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
    'retired_recipients', to_jsonb(v_retired), 'retyped_recipients', to_jsonb(v_retyped), 'created_recipients', to_jsonb(v_created));

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_op.account_id, 'remittance_operations', p_operation_id, 'service', p_audit_action,
          p_actor, p_reason, v_before, v_after);

  RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', true,
                            'retired', to_jsonb(v_retired), 'retyped', to_jsonb(v_retyped), 'created', to_jsonb(v_created));
END $function$;

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
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_resolver_servicio(p_conv uuid, p_declarado text DEFAULT NULL::text, p_intencion text DEFAULT NULL::text, p_monto numeric DEFAULT NULL::numeric, p_ahora timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- services a declaration can name as a target (remesa is the default rail, never a target)
  c_destinos constant text[] := ARRAY['cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico'];
  c_rieles   constant text[] := ARRAY['cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd'];
  v_hoy      date;
  v_min_cup numeric; v_min_usd numeric; v_min_clasica numeric; v_min_tropical numeric; v_min_rec numeric; v_min_efe numeric; v_saldo numeric; v_min_mex numeric;
  v_pv numeric; v_pp numeric; v_promo boolean;
  v_row      text;
  v_decl     text;
  v_y        text;
  v_int      text;
  -- operations
  r          record;
  v_ops      jsonb := '[]'::jsonb;
  v_n_open   integer := 0;
  v_n_dep    integer := 0;
  v_grupo    uuid;
  v_holder   uuid;
  v_lone     uuid;
  v_subj     uuid;
  v_s        jsonb;
  v_tipo     text; v_riel text; v_status text; v_bloq text; v_x text; v_x_key text;
  v_dep_subj numeric := 0;
  -- evidence (data only)
  v_parcial  record;
  v_tarjeta boolean := false; v_zelle boolean := false; v_efec boolean := false;
  v_cel boolean := false; v_solo_cel boolean := false; v_data_rail text;
  v_d        numeric := 0; v_fuente text; v_es_precio boolean := false;
  -- decision
  v_min_x numeric; v_min_y numeric;
  v_accion   text := 'ninguna';
  v_motivo   text := 'sin_cambio';
  v_servicio text; v_en_curso text;
  v_dest     uuid; v_conv_a text;
  v_minimo   numeric; v_falta numeric;
  v_cancelar uuid[] := ARRAY[]::uuid[];
  v_adic     jsonb := '[]'::jsonb;
  v_permitido boolean; v_mensaje text; v_lbl_x text; v_lbl_y text;
  v_plan jsonb; v_dep_tot numeric;
  v_rp jsonb; v_h jsonb; v_o jsonb; v_obj numeric; v_resto numeric;
  v_sin_dinero jsonb;
  v_dep_grupo numeric;
  v_alt boolean := false;
BEGIN
  -- (283) the customer's words (cup, pesos, efectivo...) are understood here, not in the agent.
  p_declarado := _cerebro_servicio_clave(p_declarado);
  -- Initialised here, not in DECLARE: an error in a declaration is not caught by the EXCEPTION clause below.
  v_hoy := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_min_cup := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_min_usd := COALESCE(COALESCE(NULLIF(cerebro_config_get('minimo_usd_zelle'), '')::numeric, 50)
                          * crm_tasa_vigente('usd'),
                        NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                        NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  -- (306) Clasica y Tropical bajan a 20 USD; Zelle conserva el minimo de siempre.
  -- (307) The USD services carry their minimum in USD: the GYD amount is the live rate.
  v_min_clasica := COALESCE(COALESCE(NULLIF(cerebro_config_get('minimo_usd_clasica'), '')::numeric, 20)
                              * crm_tasa_vigente('usd'),
                            NULLIF(cerebro_config_get('minimo_gyd_clasica'), '')::numeric, v_min_usd);
  v_min_tropical := COALESCE(COALESCE(NULLIF(cerebro_config_get('minimo_usd_tropical'), '')::numeric, 20)
                               * crm_tasa_vigente('usd'),
                             NULLIF(cerebro_config_get('minimo_gyd_tropical'), '')::numeric, v_min_usd);
  v_min_rec := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_recarga'), '')::numeric, 5200);
  v_min_efe := cerebro_minimo_efectivo_gyd();
  -- (273) Mexico: same config key and default as cerebro_minimo_gyd (272): 13,000 GYD = 50 USD at 260.
  v_min_mex := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_mexico'), '')::numeric, 13000);
  v_saldo   := cerebro_saldo_precio();
  SELECT v.precio_gyd INTO v_pv FROM cerebro_promo_vigente(v_hoy) v;
  SELECT p.precio_gyd INTO v_pp FROM cerebro_promo_proxima(v_hoy) p;
  v_promo := v_pv IS NOT NULL OR v_pp IS NOT NULL;

  -- The declaration: the one named now, else the stored row (the latest declaration).
  SELECT d.servicio INTO v_row FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv;
  v_decl := lower(btrim(coalesce(nullif(btrim(p_declarado), ''), v_row, '')));
  v_y    := nullif(v_decl, '');
  v_int  := coalesce(nullif(lower(btrim(p_intencion)), ''), 'cambiar');

  -- ---- open operations ---------------------------------------------------------------------------------------------
  FOR r IN
    SELECT o.id, o.status, o.service_type, o.quoted_source_amount, o.mixed_group_id, o.created_at,
           cerebro_riel_op(o.id) AS riel,
           EXISTS (SELECT 1 FROM remittance_operation_receipts x WHERE x.operation_id = o.id) AS recibo,
           EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.anulado_en IS NULL AND d.descartado_en IS NULL) AS dep,
           (SELECT k FROM unnest(ARRAY['delivery_method', 'service_type', 'quoted_destination_amount']) AS k
             WHERE coalesce(o.admin_locked_fields, '{}'::jsonb) ? k
               AND coalesce(o.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%' LIMIT 1) AS bloqueo,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND (nullif(b.card_number, '') IS NOT NULL OR b.beneficiary_type IN ('clasica', 'tropical', 'multiple_distribution'))) AS b_tarjeta,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND (nullif(b.zelle_account, '') IS NOT NULL OR b.beneficiary_type = 'zelle')) AS b_zelle,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND b.beneficiary_type = 'efectivo_usd') AS b_efec,
           EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'
                    AND nullif(b.phone, '') IS NOT NULL
                    AND b.beneficiary_type NOT IN ('mexico_cuenta', 'mexico_retiro')) AS b_cel
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
     ORDER BY o.created_at, o.id
  LOOP
    v_n_open := v_n_open + 1;
    v_ops := v_ops || jsonb_build_object(
      'id', r.id,
      'servicio', CASE WHEN r.service_type = 'remesa' THEN coalesce(r.riel, 'remesa') ELSE r.service_type END,
      'tipo', r.service_type, 'status', r.status, 'rail', r.riel,
      'deposito', CASE WHEN r.recibo OR r.dep THEN coalesce(r.quoted_source_amount, 0) ELSE 0 END,
      'tiene_deposito', r.recibo OR r.dep,
      -- (293) the money the operation holds, and the amount agreed for it while it holds none (the bot decides, the database validates the money)
      'dinero_gyd', CASE WHEN r.recibo OR r.dep THEN coalesce(r.quoted_source_amount, 0) ELSE 0 END,
      'monto_acordado_gyd', CASE WHEN NOT (r.recibo OR r.dep) THEN nullif(r.quoted_source_amount, 0) ELSE _cerebro_monto_acordado_previo(r.id) END,
      'vacia', NOT (r.recibo OR r.dep) AND (coalesce(r.quoted_source_amount, 0) = 0 OR _cerebro_op_monto_acordado(r.id))
               AND r.bloqueo IS NULL AND r.status IN ('collecting_information', 'awaiting_deposit'),
      'grupo', r.mixed_group_id, 'bloqueo_humano', r.bloqueo,
      'tarjeta', r.b_tarjeta, 'zelle', r.b_zelle, 'efectivo', r.b_efec, 'celular', r.b_cel,
      'creado', r.created_at);
    IF r.mixed_group_id IS NOT NULL THEN v_grupo := coalesce(v_grupo, r.mixed_group_id); END IF;
    IF r.recibo OR r.dep THEN
      v_n_dep := v_n_dep + 1; v_holder := coalesce(v_holder, r.id);
    END IF;
    v_lone := r.id;
  END LOOP;

  -- REPARTO PENDIENTE (325): a verified deposit sits in one open, ungrouped operation and another open
  -- operation of a different service already has a recipient but no money. The holder's open objective is one
  -- part; the rest of the deposit is the other. Facts only: the Decisor turns this into the mandatory tool.
  v_rp := NULL;
  IF v_n_dep = 1 AND v_grupo IS NULL AND v_n_open = 2 THEN
    SELECT e INTO v_h FROM jsonb_array_elements(v_ops) e
     WHERE (e ->> 'tiene_deposito')::boolean LIMIT 1;
    SELECT e INTO v_o FROM jsonb_array_elements(v_ops) e
     WHERE NOT (e ->> 'tiene_deposito')::boolean LIMIT 1;
    IF v_h IS NOT NULL AND v_o IS NOT NULL
       AND ((v_o ->> 'tarjeta')::boolean OR (v_o ->> 'zelle')::boolean
            OR (v_o ->> 'efectivo')::boolean OR (v_o ->> 'celular')::boolean)
       AND (v_o ->> 'servicio') IS DISTINCT FROM (v_h ->> 'servicio') THEN
      SELECT oj.monto INTO v_obj
        FROM cerebro_objetivo_envio oj
       WHERE oj.conversation_id = p_conv
         AND oj.cerrado_en IS NULL
         AND (oj.operation_id = (v_h ->> 'id')::uuid OR oj.operation_id IS NULL)
       ORDER BY (oj.operation_id IS NOT NULL) DESC, oj.fijado_en DESC LIMIT 1;
      v_resto := coalesce((v_h ->> 'dinero_gyd')::numeric, 0) - coalesce(v_obj, 0);
      IF coalesce(v_obj, 0) > 0 AND v_resto > 0
         AND v_resto >= coalesce(cerebro_minimo_gyd((v_o ->> 'id')::uuid), 0) THEN
        v_rp := jsonb_build_object(
          'deposito_gyd', (v_h ->> 'dinero_gyd')::numeric,
          'objetivo_gyd', v_obj,
          'resto_gyd', v_resto,
          'partes', jsonb_build_array(
            jsonb_build_object('servicio', v_h ->> 'servicio', 'monto_gyd', v_obj,
                               'operation_id', v_h ->> 'id'),
            jsonb_build_object('servicio', v_o ->> 'servicio', 'monto_gyd', v_resto,
                               'operation_id', v_o ->> 'id')));
      END IF;
    END IF;
  END IF;

  -- OPERACIONES ABIERTAS SIN SU PARTE DEL DEPOSITO (326): the send has a verified deposit and another open,
  -- ungrouped operation has no money and no own objective. The Decisor forbids "complete" until it is named.
  SELECT jsonb_agg(jsonb_build_object(
           'servicio', e ->> 'servicio',
           'operation_id', e ->> 'id',
           'tiene_destinatario', ((e ->> 'tarjeta')::boolean OR (e ->> 'zelle')::boolean
                                  OR (e ->> 'efectivo')::boolean OR (e ->> 'celular')::boolean))
         ORDER BY e ->> 'creado')
    INTO v_sin_dinero
    FROM jsonb_array_elements(v_ops) e
   WHERE v_n_dep > 0
     AND NOT (e ->> 'tiene_deposito')::boolean
     AND coalesce((e ->> 'dinero_gyd')::numeric, 0) = 0
     AND (e ->> 'grupo') IS NULL
     AND NOT EXISTS (SELECT 1 FROM cerebro_objetivo_envio oj
                      WHERE oj.conversation_id = p_conv AND oj.cerrado_en IS NULL
                        AND oj.operation_id = (e ->> 'id')::uuid);

  -- (327) The money the group actually holds. PARTES ACORDADAS summed the holder's own part and
  -- claimed the rest was missing (Yoandrys 2026-10-26: 275,000 of 285,000).
  IF v_grupo IS NOT NULL THEN
    SELECT s.depositado INTO v_dep_grupo FROM cerebro_saldo_operacion(v_grupo) s;
  END IF;

  -- The holder is the subject; with no deposit at all, the lone open operation is the subject.
  v_subj := CASE WHEN v_n_dep = 1 THEN v_holder WHEN v_n_dep = 0 AND v_n_open = 1 THEN v_lone END;
  -- (283) Several open operations and no deposit: the request names a RAIL service, so the target is the operation of its SERVICE. An operation that is
  -- already of the requested service means there is nothing to change; otherwise the single plain remesa is the one that changes (a Mexico, recharge,
  -- combo, visa or balance operation is never re-typed by another service's request). Two remesas stay ambiguous.
  IF v_subj IS NULL AND v_n_dep = 0 AND v_n_open > 1 AND v_grupo IS NULL
     AND lower(btrim(coalesce(nullif(btrim(p_declarado), ''), v_row, ''))) = ANY (c_rieles) THEN
    SELECT (e ->> 'id')::uuid INTO v_subj FROM jsonb_array_elements(v_ops) e
     WHERE e ->> 'servicio' = lower(btrim(coalesce(nullif(btrim(p_declarado), ''), v_row))) ORDER BY e ->> 'creado', e ->> 'id' LIMIT 1;
    IF v_subj IS NULL AND (SELECT count(*) FROM jsonb_array_elements(v_ops) e WHERE e ->> 'tipo' = 'remesa') = 1 THEN
      SELECT (e ->> 'id')::uuid INTO v_subj FROM jsonb_array_elements(v_ops) e WHERE e ->> 'tipo' = 'remesa';
      v_alt := true;
    END IF;
  END IF;
  IF v_subj IS NOT NULL THEN
    SELECT e INTO v_s FROM jsonb_array_elements(v_ops) e WHERE e ->> 'id' = v_subj::text;
    v_tipo := v_s ->> 'tipo'; v_status := v_s ->> 'status'; v_bloq := v_s ->> 'bloqueo_humano';
    v_x := v_s ->> 'servicio'; v_dep_subj := coalesce((v_s ->> 'deposito')::numeric, 0);
    v_riel := CASE WHEN v_tipo = 'remesa' THEN v_s ->> 'rail' END;
  END IF;

  -- ---- data evidence (never message text) ---------------------------------------------------------------------------
  SELECT * INTO v_parcial FROM cerebro_beneficiario_parcial bp WHERE bp.conversation_id = p_conv;
  v_tarjeta := coalesce(nullif(v_parcial.tarjeta, ''), '') <> ''
               OR coalesce((v_s ->> 'tarjeta')::boolean, false);
  -- (parent review) a card RAIL or a card-typed recipient without a card number is not card data: the system saves a
  -- lone Cuban mobile as a cuban_card recipient (notes_parse, the real 1232671b shape). Only a card number counts.
  v_zelle := coalesce(coalesce(nullif(v_parcial.zelle_cuenta, ''), nullif(v_parcial.zelle_nombre, ''),
                               nullif(v_parcial.zelle_nombre_cuenta, '')) IS NOT NULL, false)
             OR coalesce((v_s ->> 'zelle')::boolean, false) OR coalesce(v_riel = 'zelle', false);
  v_efec := coalesce((v_s ->> 'efectivo')::boolean, false) OR coalesce(v_riel = 'efectivo_usd', false);
  v_cel  := coalesce(nullif(v_parcial.celular, ''), '') <> '' OR coalesce((v_s ->> 'celular')::boolean, false);
  v_solo_cel := v_cel AND NOT (v_tarjeta OR v_zelle OR v_efec);
  v_data_rail := CASE WHEN v_zelle THEN 'zelle' WHEN v_efec THEN 'efectivo_usd' ELSE 'cuban_card' END;
  v_x_key := CASE WHEN v_tipo = 'remesa' THEN coalesce(CASE WHEN v_riel = ANY (c_rieles) THEN v_riel END, v_data_rail)
                  ELSE v_tipo END;

  -- The deposit the decision is about: the holder's, else the amount registered now.
  v_d := CASE WHEN v_dep_subj > 0 THEN v_dep_subj WHEN coalesce(p_monto, 0) > 0 THEN p_monto ELSE 0 END;
  v_fuente := CASE WHEN v_dep_subj > 0 THEN 'operacion' WHEN coalesce(p_monto, 0) > 0 THEN 'parametro' END;
  v_es_precio := v_d > 0 AND v_pv IS NOT NULL AND mod(v_d, v_pv) = 0;

  v_en_curso := v_x;
  v_servicio := v_x;

  <<flow>>
  BEGIN
    -- R0 validation (facts about the request, not about the customer's words)
    IF v_y IS NOT NULL AND NOT (v_y = ANY (c_destinos)) THEN v_motivo := 'servicio_invalido'; EXIT flow; END IF;
    IF v_int NOT IN ('cambiar', 'agregar') THEN v_motivo := 'intencion_invalida'; EXIT flow; END IF;

    -- R1 a mixed group changes only through repartir_envio.
    IF v_grupo IS NOT NULL THEN v_motivo := 'grupo_mixto'; EXIT flow; END IF;

    -- R2 one deposit per operation is never a mixed send; without a holder the subject is unknown.
    IF v_n_dep > 1 THEN v_motivo := 'depositos_separados'; v_servicio := NULL; v_en_curso := NULL; EXIT flow; END IF;
    IF v_subj IS NULL AND v_n_open > 1 THEN v_motivo := 'varias_operaciones'; v_servicio := NULL; v_en_curso := NULL; EXIT flow; END IF;

    -- R3 a person fixed it, or the money is moving.
    IF v_subj IS NOT NULL THEN
      IF v_bloq IS NOT NULL THEN v_motivo := 'bloqueada'; EXIT flow; END IF;
      -- (344) An incident that applied nothing (no_aplica) and holds no money is correctable.
      IF v_status IN ('transferring', 'incident')
         AND NOT (v_status = 'incident' AND cerebro_op_recuperable((v_s ->> 'id')::uuid)) THEN
        v_motivo := 'estado_no_permite'; EXIT flow;
      END IF;
    END IF;

    -- R4 a recarga needs a live or announced promo (207/211).
    IF v_y = 'recarga' AND NOT v_promo THEN v_motivo := 'recarga_sin_promo'; EXIT flow; END IF;

    -- R5-R7 a declared target Y.
    IF v_y IS NOT NULL THEN
      v_min_y := CASE v_y
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_clasica WHEN 'tropical' THEN v_min_tropical
                   WHEN 'efectivo_usd' THEN v_min_efe
                   WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec)
                   WHEN 'saldo' THEN v_saldo WHEN 'visa' THEN 5000 WHEN 'combo' THEN 25000
                   WHEN 'mexico' THEN v_min_mex
                   ELSE v_min_cup END;

      IF v_subj IS NULL THEN
        -- R7 no holder: Y is the service of a new operation.
        v_servicio := v_y;
        IF v_d > 0 AND v_d < v_min_y THEN
          v_motivo := 'deposito_bajo_minimo'; v_minimo := v_min_y; v_falta := v_min_y - v_d;
        ELSE
          v_motivo := 'nueva_operacion';
        END IF;
        EXIT flow;
      END IF;

      -- R6 the holder is already of service Y.
      IF v_x = v_y THEN v_motivo := 'sin_cambio'; EXIT flow; END IF;

      -- R5 the holder is of another service.
      v_min_x := CASE v_x_key
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_clasica WHEN 'tropical' THEN v_min_tropical
                   WHEN 'efectivo_usd' THEN v_min_efe
                   WHEN 'recarga' THEN coalesce(v_pv, v_pp, v_min_rec)
                   WHEN 'saldo' THEN v_saldo WHEN 'visa' THEN 5000 WHEN 'combo' THEN 25000
                   WHEN 'mexico' THEN v_min_mex
                   ELSE v_min_cup END;
      IF v_int = 'agregar' THEN
        IF v_d >= v_min_x + v_min_y THEN
          v_accion := 'mixto'; v_motivo := 'deposito_cubre_ambos'; v_dest := v_subj; v_servicio := v_y;
          v_adic := jsonb_build_array(jsonb_build_object('servicio', v_y, 'monto', v_min_y));
        ELSE
          v_accion := 'aparte'; v_motivo := 'adicional_aparte'; v_servicio := v_y; v_minimo := v_min_y;
        END IF;
        EXIT flow;
      END IF;

      -- cambiar
      -- (283) a RAIL target (zelle / clasica / tropical / cuban_card / efectivo_usd) with no money registered at all: nothing to cover yet, the
      -- minimum is checked when the deposit arrives. recarga / saldo / combo / visa / mexico keep needing the money first (265, 276).
      IF (v_d = 0 AND v_y = ANY (c_rieles)) OR v_d >= v_min_y THEN
        v_accion := 'convertir'; v_motivo := 'declarado'; v_dest := v_subj; v_conv_a := v_y; v_servicio := v_y;
        v_cancelar := coalesce(ARRAY(SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(v_ops) e
                                      WHERE (e ->> 'vacia')::boolean
                                        AND (e ->> 'id')::uuid IS DISTINCT FROM v_subj
                                        AND e ->> 'servicio' IS DISTINCT FROM v_x), ARRAY[]::uuid[]);
        IF v_alt THEN v_cancelar := ARRAY[]::uuid[]; END IF;
      ELSE
        v_motivo := 'deposito_bajo_minimo'; v_minimo := v_min_y; v_falta := v_min_y - v_d;
      END IF;
      EXIT flow;
    END IF;

    -- R8 no declaration: the recipient is phone-only and the deposit is whole promo prices (Q1).
    IF v_solo_cel AND v_pv IS NOT NULL AND v_es_precio AND (v_subj IS NULL OR v_tipo = 'remesa') THEN
      v_motivo := 'monto_precio_y_celular'; v_servicio := 'recarga';
      IF v_subj IS NOT NULL THEN
        v_accion := 'convertir'; v_dest := v_subj; v_conv_a := 'recarga';
        v_cancelar := coalesce(ARRAY(SELECT (e ->> 'id')::uuid FROM jsonb_array_elements(v_ops) e
                                      WHERE (e ->> 'vacia')::boolean
                                        AND (e ->> 'id')::uuid IS DISTINCT FROM v_subj
                                        AND e ->> 'servicio' IS DISTINCT FROM v_x), ARRAY[]::uuid[]);
      END IF;
      EXIT flow;
    END IF;

    -- R9 default: nothing to change.
  END;

  -- (277) The split the agent planned before the deposit (facts for the Decisor): parts with their USD, the planned total, the money
  -- registered so far and the difference.
  SELECT coalesce(sum((e ->> 'deposito')::numeric), 0) INTO v_dep_tot FROM jsonb_array_elements(v_ops) e WHERE (e ->> 'tiene_deposito')::boolean;
  SELECT jsonb_build_object(
           'partes', (SELECT jsonb_agg(jsonb_build_object('servicio', x ->> 'servicio', 'monto_gyd', (x ->> 'monto_gyd')::numeric,
                                                        'usd', _cerebro_usd_parte(x ->> 'servicio', (x ->> 'monto_gyd')::numeric)) ORDER BY ord)
                        FROM jsonb_array_elements(pl.partes) WITH ORDINALITY t(x, ord)),
           'total_gyd', pl.total_gyd, 'deposito_gyd', v_dep_tot, 'diferencia_gyd', v_dep_tot - pl.total_gyd,
           'coincide', v_dep_tot = pl.total_gyd)
    INTO v_plan FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv;

  -- Plain-Spanish sentence for the bot (labels only; the numbers come from the rules above).
  v_lbl_y := (SELECT t.l FROM (VALUES ('cuban_card', 'la tarjeta CUP'), ('clasica', 'la tarjeta clásica'),
                                      ('tropical', 'la tarjeta tropical'), ('zelle', 'Zelle'),
                                      ('efectivo_usd', 'efectivo en USD'), ('recarga', 'la recarga'),
                                      ('saldo', 'el saldo móvil'), ('combo', 'el combo'),
                                      ('visa', 'la extensión de visa'), ('mexico', 'el envío a México'), ('remesa', 'la remesa')) AS t(k, l)
               WHERE t.k = coalesce(v_y, v_conv_a));
  v_lbl_x := (SELECT t.l FROM (VALUES ('cuban_card', 'la tarjeta CUP'), ('clasica', 'la tarjeta clásica'),
                                      ('tropical', 'la tarjeta tropical'), ('zelle', 'Zelle'),
                                      ('efectivo_usd', 'efectivo en USD'), ('recarga', 'la recarga'),
                                      ('saldo', 'el saldo móvil'), ('combo', 'el combo'),
                                      ('visa', 'la extensión de visa'), ('mexico', 'el envío a México'), ('remesa', 'la remesa')) AS t(k, l)
               WHERE t.k = v_x);
  v_mensaje := CASE v_motivo
    WHEN 'grupo_mixto' THEN 'Esta operación está en un envío mixto: los cambios se hacen con repartir_envio.'
    WHEN 'depositos_separados' THEN 'Hay varias operaciones con depósito propio y no se cambian juntas.'
    WHEN 'varias_operaciones' THEN 'Hay varias operaciones abiertas sin depósito: no se sabe a cuál aplicar el cambio.'
    WHEN 'bloqueada' THEN 'Un dato de esta operación lo fijó una persona: el bot no lo cambia.'
    WHEN 'estado_no_permite' THEN 'La operación está en un estado que no permite cambiar el servicio.'
    WHEN 'recarga_sin_promo' THEN 'No hay promoción de recarga vigente ni anunciada.'
    WHEN 'deposito_bajo_minimo' THEN 'No alcanza para ' || v_lbl_y || ': el mínimo es '
                                     || to_char(v_minimo, 'FM999,999,999') || ' GYD y faltan '
                                     || to_char(v_falta, 'FM999,999,999') || ' GYD.'
    WHEN 'servicio_invalido' THEN 'El servicio indicado no es válido.'
    WHEN 'intencion_invalida' THEN 'La intención indicada no es válida.'
    ELSE CASE v_accion
           WHEN 'convertir' THEN 'Se pasa la operación a ' || v_lbl_y || '.'
           WHEN 'mixto' THEN 'El depósito cubre ' || v_lbl_x || ' y ' || v_lbl_y || '.'
           WHEN 'aparte' THEN 'Se abre una operación aparte para ' || v_lbl_y || ': necesita su propio depósito de al menos '
                              || to_char(v_minimo, 'FM999,999,999') || ' GYD.'
           ELSE CASE v_motivo
                  WHEN 'nueva_operacion' THEN
                    CASE WHEN v_int = 'agregar'
                         THEN 'Anotado: se agrega ' || coalesce(v_lbl_y, 'ese servicio') || ' como operación nueva; todavía no hay otra operación abierta y se abre con sus datos o al repartir el depósito.'
                         ELSE 'Anotado: ' || coalesce(v_lbl_y, 'ese servicio') || ' será la operación; todavía no hay ninguna abierta y se abre con sus datos o con su depósito.' END
                  WHEN 'sin_cambio' THEN
                    CASE WHEN v_lbl_x IS NOT NULL THEN 'La operación ya es ' || v_lbl_x || ': no hay nada que cambiar.'
                         ELSE 'No hay ningún cambio de servicio que aplicar.' END
                  ELSE NULL
                END
         END
  END;
  -- (279) The agent always gets a sentence it can use.
  v_mensaje := coalesce(v_mensaje, 'No hay ningún cambio de servicio que aplicar.');
  v_permitido := v_accion <> 'ninguna' OR v_motivo IN ('sin_cambio', 'nueva_operacion');

  RETURN jsonb_build_object(
    'version', 2,
    'servicio', v_servicio,
    'en_curso', v_en_curso,
    'accion', v_accion,
    'permitido', v_permitido,
    'motivo', v_motivo,
    'mensaje', v_mensaje,
    'minimo_gyd', v_minimo,
    'faltante_gyd', v_falta,
    'destino_operacion', v_dest,
    'convertir_a', v_conv_a,
    'cancelar', to_jsonb(v_cancelar),
    'grupo_mixto', v_grupo,
    'adicionales', v_adic,
    'operaciones', v_ops,
    'evidencia', jsonb_build_object(
      'deposito', v_d,
      'fuente', v_fuente,
      'monto_igual_precio', v_es_precio,
      'solo_celular', v_solo_cel,
      'tarjeta', v_tarjeta,
      'zelle', v_zelle,
      'promo', jsonb_build_object('vigente', v_pv IS NOT NULL, 'proxima', v_pp IS NOT NULL),
      'declarado', nullif(v_decl, ''),
      'intencion', CASE WHEN v_y IS NOT NULL THEN v_int END),
    'reparto_pendiente', v_rp,
    'sin_dinero', v_sin_dinero,
    'deposito_grupo_gyd', v_dep_grupo,
    'reparto_planeado', v_plan,
    -- (333) The funding case of the conversation, so the bot can ask when the money is blocked by a
    -- conflict. The active case only; a closed one is history and does not block anything.
    'expediente', (
      SELECT jsonb_build_object(
               'estado', fc.status,
               'nota', fc.note,
               'depositado', s.depositado,
               'asignado', s.asignado,
               'disponible', s.disponible)
        FROM funding_case fc
        CROSS JOIN LATERAL funding_case_saldo(fc.id) s
       WHERE fc.conversation_id = p_conv
         AND fc.status <> 'closed'
       ORDER BY fc.opened_at DESC
       LIMIT 1));
EXCEPTION WHEN OTHERS THEN
  -- Fail open: the bot keeps working without the resolver's answer.
  RETURN jsonb_build_object(
    'version', 2, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'permitido', false, 'motivo', 'error',
    'mensaje', 'No se pudo comprobar el servicio en este momento: no se cambió nada.', 'minimo_gyd', NULL, 'faltante_gyd', NULL, 'destino_operacion', NULL, 'convertir_a', NULL,
    'cancelar', '[]'::jsonb, 'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'operaciones', '[]'::jsonb,
    'reparto_pendiente', NULL, 'sin_dinero', NULL, 'deposito_grupo_gyd', NULL,
    'expediente', NULL,
    'evidencia', '{}'::jsonb, 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200));
END $function$;

