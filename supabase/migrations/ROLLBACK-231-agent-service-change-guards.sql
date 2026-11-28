-- ROLLBACK of 231_agent_service_change_guards.sql: restores the pre-231 definitions exactly as staging had them on 2026-10-08
-- (pg_get_functiondef md5): cerebro_detectar_destino 31f6d02d599b491c586284251b0502f9 (= 174), cerebro_marcar_destino_usd
-- f239d898e9533b82a9822f4eb98ee6e7 (= 221), cerebro_cambiar_servicio f47c288efed9aa967a90c5487b08c166 (= 230, which stays). 231 did not touch
-- cerebro_registrar_destino (c87c36beafde0cd256a601ee7290d045). Drops the coherence check, its alert table, the via recorder, the helpers,
-- the creation trigger and the pending-origin trigger; deletes the pending rows the old check would refuse (zelle, efectivo_usd) and the
-- coherencia_servicio notifications (the restored type list would refuse them); drops the origen / ejecucion columns; restores both
-- CHECK constraints. Operations already switched by the agent keep their data and audit rows.
-- Run it only after the n8n bot no longer calls cerebro_verificar_coherencia_servicio nor cerebro_registrar_via_cotizada.

DROP TRIGGER IF EXISTS trg_zz_destino_agente_al_crear ON public.remittance_operations;
DROP FUNCTION IF EXISTS public.cerebro_destino_agente_al_crear();

DROP FUNCTION IF EXISTS public.cerebro_verificar_coherencia_servicio(uuid, text);
DROP FUNCTION IF EXISTS public.cerebro_coherencia_resolver(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.cerebro_registrar_via_cotizada(uuid, text, text, text, numeric);
DROP TABLE IF EXISTS public.cerebro_alertas_coherencia;
DELETE FROM public.notifications WHERE type = 'coherencia_servicio';
ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type IN (
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado', 'ingesta_caida', 'deposito_sin_cruzar',
  'mensaje_perdido', 'envio_incompleto', 'pide_mlc', 'envio_sin_beneficiario', 'remesa_abierta_vieja', 'entrega_efectivo_lista'));

CREATE OR REPLACE FUNCTION public.cerebro_marcar_destino_usd(p_conversation_id uuid, p_tipo text, p_execution_id text)
 RETURNS TABLE(id uuid, accion text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- Procedural, not a single CTE chain, for one concrete reason: the
-- `ins` branch must set delivery_method on the operation it has JUST
-- created, and every statement in one WITH chain shares one snapshot, so
-- an UPDATE cannot see the row inserted by cerebro_crear_operacion() in
-- the same statement. Two statements are needed, so the branches are
-- sequenced explicitly. The branch order and the emitted rows are exactly
-- the node's union order: falta, upd, ins, sin_cambio, ambiguo — with the
-- one multi-row case the node has (an invalid tipo AND two open
-- operations emits falta + ambiguo) preserved.
DECLARE
  v_resultado text;
  v_op        uuid;
  v_k         text;
  v_reg       integer;
  v_t         text;
  v_marker    text;
  v_actual    text;
  v_ben       text;
  v_nuevo     uuid;
BEGIN
  -- Inlined cerebro_resolver_operacion(uuid, text[]): see the header.
  SELECT CASE WHEN count(*) = 0 THEN 'ninguna'
              WHEN count(*) = 1 THEN 'unica'
              ELSE 'ambigua' END,
         CASE WHEN count(*) = 1
              THEN (SELECT o.id FROM remittance_operations o
                     WHERE o.conversation_id = p_conversation_id
                       AND o.status NOT IN ('completed','cancelled')
                       AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'])
                     LIMIT 1)
         END
    INTO v_resultado, v_op
    FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status NOT IN ('completed','cancelled')
     AND o.status = ANY(ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident']);

  v_k := p_execution_id || ':marcar_destino_usd:' || md5(coalesce(p_tipo,''));
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id,
                                  conversation_id, operation_id, arguments)
  SELECT v_k, 'marcar_destino_usd', p_execution_id, p_conversation_id, v_op,
         jsonb_build_array(to_jsonb(p_tipo::text))
  ON CONFLICT (idempotency_key) DO NOTHING
  RETURNING 1 INTO v_reg;

  v_t := CASE WHEN lower(p_tipo) LIKE 'trop%' THEN 'Tropical'
              WHEN lower(p_tipo) LIKE 'cl%'   THEN 'Clasica'
              WHEN lower(p_tipo) LIKE 'efec%' THEN 'Efectivo' END;
  -- 151 line 77: the notes marker the trigger turns into delivery_method is
  -- lower(t) for Clasica/Tropical and the literal 'efectivo_usd' for
  -- Efectivo. Same expression the old trigger's UPDATE used.
  v_marker := CASE WHEN v_t = 'Efectivo'      THEN 'efectivo_usd'
                   WHEN v_t IS NOT NULL       THEN lower(v_t) END;

  -- falta
  IF v_t IS NULL THEN
    RETURN QUERY SELECT NULL::uuid AS id,
      'ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.'::text AS accion;
  END IF;

  -- abierto: upd / sin_cambio (both need an operation, and a rail)
  IF v_op IS NOT NULL THEN
    IF v_t IS NOT NULL THEN
      SELECT o.delivery_method,
             (SELECT b.beneficiary_type FROM remittance_beneficiaries b
               WHERE b.operation_id = o.id AND b.status = 'vigente'
               LIMIT 1)
        INTO v_actual, v_ben
        FROM remittance_operations o WHERE o.id = v_op;

      -- 'ENTREGA EN USD: <t>' in deals.notes becomes delivery_method = marker(t).
      IF coalesce(v_actual = v_marker, false) THEN
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        RETURN QUERY SELECT v_op AS id,
          'sin cambios: ese destino ya estaba marcado'::text AS accion;
      ELSE
        UPDATE remittance_operations o
           SET delivery_method = coalesce(v_marker, v_ben, o.delivery_method)
         WHERE o.id = v_op
           AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, v_ben, o.delivery_method);
        -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
        IF v_t IN ('Clasica', 'Tropical') THEN
          PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
        END IF;
        RETURN QUERY SELECT v_op AS id,
          ('destino marcado: entrega en USD por ' || v_t)::text AS accion;
      END IF;
    END IF;
    RETURN;
  END IF;

  -- no operation: ambiguo, or the node's `ins`
  IF v_resultado = 'ambigua' THEN
    RETURN QUERY
    SELECT NULL::uuid AS id,
           'NO SE REGISTRO NADA. Hay varios envios abiertos y la conversacion ya paso a una persona del equipo. Dile al cliente que un companero le atiende enseguida. No confirmes ningun dato.'::text AS accion
      FROM cerebro_registrar_derivacion(
             p_conversation_id,
             'Hay varias operaciones abiertas y el caso requiere revisión humana.',
             'operacion_ambigua',
             true) d;
  ELSIF v_t IS NOT NULL THEN
    v_nuevo := cerebro_crear_operacion(p_conversation_id);
    UPDATE remittance_operations o
       SET delivery_method = coalesce(v_marker, o.delivery_method)
     WHERE o.id = v_nuevo
       AND o.delivery_method IS DISTINCT FROM coalesce(v_marker, o.delivery_method);
    -- (221) the rail is also the pending destination: re-types a card already registered (157's rules).
    IF v_t IN ('Clasica', 'Tropical') THEN
      PERFORM cerebro_registrar_destino(p_conversation_id, lower(v_t));
    END IF;
    RETURN QUERY SELECT v_nuevo AS id,
      ('envio nuevo creado, entrega en USD por ' || v_t)::text AS accion;
  END IF;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL)
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

    -- The conversation's open operation, the way the bot's other writers find it.
    SELECT coalesce(array_agg(o.id ORDER BY o.created_at), ARRAY[]::uuid[]) INTO v_ids
      FROM remittance_operations o
     WHERE o.conversation_id = p_conversation_id
       AND o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'incident');
    IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
      SELECT o.id, o.status INTO v_op, v_status
        FROM remittance_operations o WHERE o.conversation_id = p_conversation_id ORDER BY o.created_at DESC LIMIT 1;
      IF v_op IS NULL THEN
        v_result := jsonb_build_object('ok', false, 'reason', 'sin_operacion');
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
          CASE WHEN (v_result ->> 'ok')::boolean THEN CASE WHEN (v_result ->> 'changed')::boolean THEN 'changed' ELSE 'unchanged' END
               ELSE v_result ->> 'reason' END)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_result;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_detectar_destino(p_texto text)
 RETURNS text
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
  v_txt      text := coalesce(p_texto, '');
  v_clasica  boolean;
  v_tropical boolean;
  v_cup      boolean;
BEGIN
  -- (174) Plurals too: "a unas tarjetas clasicas", "a las tropicales".
  v_clasica  := v_txt ~* '(^|[^[:alnum:]])cl[aáAÁ]sicas?([^[:alnum:]]|$)';
  v_tropical := v_txt ~* '(^|[^[:alnum:]])tropical(es)?([^[:alnum:]]|$)';
  v_cup      := v_txt ~* '(^|[^[:alnum:]])cup([^[:alnum:]]|$)'
             OR v_txt ~* '(^|[^[:alnum:]])pesos[[:space:]]+cubanos([^[:alnum:]]|$)';

  IF v_clasica AND NOT v_tropical THEN
    RETURN 'clasica';
  ELSIF v_tropical AND NOT v_clasica THEN
    RETURN 'tropical';
  ELSIF v_cup AND NOT v_clasica AND NOT v_tropical THEN
    RETURN 'cuban_card';
  END IF;

  -- Both rails named, or nothing this function recognises.
  RETURN NULL;
END $function$;

DROP FUNCTION IF EXISTS public.cerebro_destino_riel_afirmado(text, text, text);
DROP FUNCTION IF EXISTS public.cerebro_destino_riel_negado(text, text);
DROP FUNCTION IF EXISTS public.cerebro_servicio_normalizar(text);

DROP TRIGGER IF EXISTS trg_destino_pendiente_origen ON public.cerebro_destino_pendiente;
DROP FUNCTION IF EXISTS public.cerebro_destino_pendiente_origen();
DELETE FROM public.cerebro_destino_pendiente WHERE tipo IN ('zelle', 'efectivo_usd');
ALTER TABLE public.cerebro_destino_pendiente DROP COLUMN IF EXISTS origen;
ALTER TABLE public.cerebro_destino_pendiente DROP COLUMN IF EXISTS ejecucion;
ALTER TABLE public.cerebro_destino_pendiente DROP CONSTRAINT cerebro_destino_pendiente_tipo_check;
ALTER TABLE public.cerebro_destino_pendiente ADD CONSTRAINT cerebro_destino_pendiente_tipo_check
  CHECK (tipo = ANY (ARRAY['clasica'::text, 'tropical'::text, 'cuban_card'::text]));

NOTIFY pgrst, 'reload schema';
