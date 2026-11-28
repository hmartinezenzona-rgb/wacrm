-- ROLLBACK 293: back to the 291/292 bodies; the 293 helpers and the new overloads are dropped.
DROP FUNCTION IF EXISTS public.cerebro_aplicar_servicio(uuid, text, text, text, text, numeric);
DROP FUNCTION IF EXISTS public.cerebro_declarar_servicio(uuid, text, text, numeric);
DROP FUNCTION IF EXISTS public._cerebro_declarar_implicito(uuid, text, text, numeric);
CREATE OR REPLACE FUNCTION public._cerebro_declarar_implicito(p_conv uuid, p_servicio text, p_origen text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_s text := nullif(_cerebro_servicio_clave(p_servicio), '');
BEGIN
  -- Only a concrete service; 'remesa' is the default rail and 'usdt' / unknown words name nothing.
  IF p_conv IS NULL OR v_s IS NULL
     OR v_s NOT IN ('cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico') THEN
    RETURN false;
  END IF;
  -- Never over a declaration the bot made: only an implicit one (or none) is replaced.
  IF EXISTS (SELECT 1 FROM cerebro_servicio_declarado d WHERE d.conversation_id = p_conv AND coalesce(d.actor, '') NOT LIKE 'implicit:%') THEN
    RETURN false;
  END IF;
  -- Never when money of another service is already in the conversation (a quote about a price is not a change of service).
  IF EXISTS (SELECT 1 FROM remittance_operations o
              WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
                AND coalesce(CASE WHEN o.service_type = 'remesa' THEN cerebro_riel_op(o.id) ELSE o.service_type END, '') <> v_s
                AND _cerebro_op_tiene_dinero(o.id)) THEN
    RETURN false;
  END IF;
  PERFORM cerebro_declarar_servicio(p_conv, v_s, 'implicit:' || coalesce(nullif(btrim(p_origen), ''), 'tool'));
  RETURN true;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_declarar_servicio(p_conv uuid, p_servicio text, p_actor text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_servicio text := _cerebro_servicio_clave(p_servicio);
  v_q        numeric;
  v_obj      numeric;
BEGIN
  IF v_servicio NOT IN ('remesa', 'cuban_card', 'clasica', 'tropical', 'zelle', 'efectivo_usd', 'recarga', 'saldo', 'combo', 'visa', 'mexico') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'servicio_invalido');
  END IF;
  INSERT INTO public.cerebro_servicio_declarado (conversation_id, servicio, declarado_at, actor)
  VALUES (p_conv, v_servicio, now(), p_actor)
  ON CONFLICT (conversation_id) DO UPDATE
    SET servicio = EXCLUDED.servicio, declarado_at = EXCLUDED.declarado_at, actor = EXCLUDED.actor;
  -- (278) The agent usually quotes BEFORE it declares: declaring is the commitment, so the standing quote (this conversation, inside the
  -- quote window, newer than the last closed operation) becomes the send objective when there is none. Never breaks the declaration.
  BEGIN
    IF NOT EXISTS (SELECT 1 FROM cerebro_objetivo_envio o WHERE o.conversation_id = p_conv AND o.cerrado_en IS NULL) THEN
      SELECT q.origen_gyd INTO v_q
        FROM cerebro_ultima_cotizacion q
       WHERE q.conversation_id = p_conv
         AND q.cotizado_en > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('cotizacion_ventana_horas'), '')::int, 6))
         AND q.cotizado_en > COALESCE((SELECT max(COALESCE(o.completed_at, o.cancelled_at)) FROM remittance_operations o
                                        WHERE o.conversation_id = p_conv AND o.status IN ('completed', 'cancelled')), '-infinity'::timestamptz)
       ORDER BY q.cotizado_en DESC LIMIT 1;
      IF v_q IS NOT NULL AND v_q > 0 THEN
        SELECT f.objetivo_gyd INTO v_obj FROM cerebro_fijar_objetivo(p_conv, v_q, 'GYD') f;
      END IF;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] cerebro_declarar_servicio could not promote the quote for %: %', p_conv, SQLERRM;
  END;
  RETURN jsonb_build_object('ok', true, 'servicio', v_servicio) || CASE WHEN v_obj IS NOT NULL THEN jsonb_build_object('objetivo_gyd', v_obj) ELSE '{}'::jsonb END;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_aplicar_servicio(p_conv uuid, p_declarado text DEFAULT NULL::text, p_intencion text DEFAULT NULL::text, p_actor text DEFAULT 'automation:resolver'::text, p_exec text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_actor       text := coalesce(nullif(btrim(p_actor), ''), 'automation:resolver');
  v_action      text;
  v_lock_actor  text;
  v_prev_origin text := coalesce(current_setting('wacrm.origin', true), '');
  v_prev_actor  text := coalesce(current_setting('wacrm.actor', true), '');
  v_safe        jsonb := jsonb_build_object(
    'version', 2, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'permitido', false, 'motivo', 'error',
    'mensaje', 'No se pudo comprobar el servicio en este momento: no se cambió nada.', 'minimo_gyd', NULL, 'faltante_gyd', NULL, 'destino_operacion', NULL, 'convertir_a', NULL,
    'cancelar', '[]'::jsonb, 'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'operaciones', '[]'::jsonb,
    'evidencia', '{}'::jsonb, 'aplicado', false, 'cambios', '{}'::jsonb);
  v_r           jsonb;
  v_account     uuid;
  v_contact     uuid;
  v_accion      text;
  v_servicio    text;
  v_dest        uuid;
  v_to          text;
  v_reason      text;
  v_core        jsonb;
  v_fit         text[];
  v_cancel_ids  uuid[];
  v_cancelled   jsonb := '[]'::jsonb;
  v_moved       jsonb := '[]'::jsonb;
  v_dups        jsonb := '[]'::jsonb;
  v_skipped     jsonb := '[]'::jsonb;
  v_parcial     jsonb;
  v_holder_lock boolean;
  v_changed     boolean := false;
  v_skip        text;
  v_detalle     text;
  v_cambios     jsonb := '{}'::jsonb;
  v_nueva       uuid;
  v_vacia       uuid;
  v_deposito    numeric;
  v_monto       numeric;
  v_x_srv       text;
  v_lbl_x       text;
  v_lbl_y       text;
  v_partes      text;
  v_grupo       uuid;
  v_reparto     text;
  d_id          uuid;
  d_op          remittance_operations%ROWTYPE;
  d_moved       jsonb;
  d_dups        jsonb;
  b             remittance_beneficiaries%ROWTYPE;
  v_twin        uuid;
  v_block       integer;
  v_pos         integer;
BEGIN
  -- (283) the agent may pass the customer's words (cup, pesos, efectivo...): the database knows the keys.
  p_declarado := nullif(_cerebro_servicio_clave(p_declarado), '');
  IF p_conv IS NULL THEN
    RETURN v_safe || jsonb_build_object('motivo', 'sin_conversacion', 'mensaje', 'No hay una conversación a la que aplicar el cambio de servicio.');
  END IF;

  SELECT c.account_id, c.contact_id INTO v_account, v_contact FROM conversations c WHERE c.id = p_conv;
  IF auth.uid() IS NOT NULL AND (v_account IS NULL OR NOT is_account_member(v_account, 'agent'::account_role_enum)) THEN
    RETURN v_safe || jsonb_build_object('motivo', 'no_autorizado', 'mensaje', 'No tienes permiso para cambiar el servicio de esta conversación.');
  END IF;

  v_action := CASE WHEN v_actor LIKE 'agent:%' THEN 'agent_service_change'
                   WHEN v_actor LIKE 'automation:%' THEN 'automation_service_change'
                   ELSE 'human_correction' END;
  -- The lock the core leaves names this actor; only 'automation:%' locks are ignored as "not a human" by the resolver and the bot tools.
  v_lock_actor := CASE WHEN v_actor LIKE 'agent:%' THEN 'automation:agent_' || substr(v_actor, 7) ELSE v_actor END;

  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));

  -- The agent's declaration is stored first, so the resolver reads it (the latest declaration wins).
  -- 'remesa' is the default rail, never a target: it is not stored as an intent (the resolver refuses it, R0).
  IF v_actor LIKE 'agent:%' AND nullif(btrim(coalesce(p_declarado, '')), '') IS NOT NULL
     AND lower(btrim(p_declarado)) <> 'remesa' THEN
    PERFORM cerebro_declarar_servicio(p_conv, p_declarado, v_actor);
  END IF;

  v_r := cerebro_resolver_servicio(p_conv, p_declarado, p_intencion);
  v_accion := v_r ->> 'accion';
  v_servicio := v_r ->> 'servicio';
  v_dest := nullif(v_r ->> 'destino_operacion', '')::uuid;
  v_to := nullif(v_r ->> 'convertir_a', '');

  IF v_accion NOT IN ('convertir', 'mixto', 'aparte')
     OR (v_accion <> 'aparte' AND v_dest IS NULL)
     OR (v_accion = 'convertir' AND v_to IS NULL) THEN
    RETURN v_r || jsonb_build_object('aplicado', false, 'cambios', '{}'::jsonb);
  END IF;

  v_reason := 'service resolver: ' || coalesce(v_r ->> 'motivo', '?')
              || CASE WHEN nullif(btrim(coalesce(p_exec, '')), '') IS NOT NULL THEN '; n8n execution ' || btrim(p_exec) ELSE '' END;

  -- One sub-transaction: a failure anywhere undoes the whole call (conversion, cancellations, moves, new operation, split).
  BEGIN
    PERFORM set_config('wacrm.origin', 'admin', true);
    PERFORM set_config('wacrm.actor', v_lock_actor, true);

    IF v_accion = 'convertir' THEN
      -- The holder changes service (Q1, Q7, Q8); the core keeps every phone-only recipient of a recarga / saldo.
      v_core := _cambiar_servicio_core(v_dest, v_to, v_action, v_actor, v_reason);
      v_changed := (v_core ->> 'changed')::boolean;
      -- (283) a split plan waiting for its deposit follows the converted operation's new service
      IF v_changed AND v_to IS DISTINCT FROM (v_r ->> 'en_curso') THEN
        UPDATE cerebro_reparto_planeado pl
           SET partes = (SELECT jsonb_agg(CASE WHEN e ->> 'servicio' = (v_r ->> 'en_curso') THEN jsonb_set(e, '{servicio}', to_jsonb(v_to)) ELSE e END ORDER BY ord)
                           FROM jsonb_array_elements(pl.partes) WITH ORDINALITY t(e, ord))
         WHERE pl.conversation_id = p_conv
           AND EXISTS (SELECT 1 FROM jsonb_array_elements(pl.partes) e WHERE e ->> 'servicio' = (v_r ->> 'en_curso'))
           AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(pl.partes) e WHERE e ->> 'servicio' = v_to);
      END IF;

      IF v_changed THEN
        v_fit := CASE WHEN v_to IN ('cuban_card', 'clasica', 'tropical') THEN ARRAY['cuban_card', 'clasica', 'tropical']
                      WHEN v_to = 'zelle' THEN ARRAY['zelle']
                      WHEN v_to = 'efectivo_usd' THEN ARRAY['efectivo_usd']
                      WHEN v_to = 'combo' THEN ARRAY['combo']
                      WHEN v_to = 'mexico' THEN ARRAY['mexico_cuenta', 'mexico_retiro']
                      WHEN v_to IN ('recarga', 'saldo') THEN ARRAY['recarga']
                      ELSE ARRAY[]::text[] END;
        SELECT coalesce(array_agg(x::uuid), ARRAY[]::uuid[]) INTO v_cancel_ids
          FROM jsonb_array_elements_text(coalesce(v_r -> 'cancelar', '[]'::jsonb)) AS x;

        -- Q3: the empty duplicates the resolver listed are cancelled after their numbers move to the holder (deduped).
        IF cardinality(v_cancel_ids) > 0 THEN
          SELECT to_jsonb(p) INTO v_parcial FROM cerebro_beneficiario_parcial p WHERE p.conversation_id = p_conv;
          SELECT EXISTS (SELECT 1 FROM remittance_operations h
                          WHERE h.id = v_dest AND coalesce(h.admin_locked_fields, '{}'::jsonb) ? 'beneficiaries'
                            AND coalesce(h.admin_locked_fields -> 'beneficiaries' ->> 'by', '') NOT LIKE 'automation:%')
            INTO v_holder_lock;

          FOREACH d_id IN ARRAY v_cancel_ids LOOP
            SELECT * INTO d_op FROM remittance_operations WHERE id = d_id AND conversation_id = p_conv FOR UPDATE;
            IF NOT FOUND OR d_op.id = v_dest THEN CONTINUE; END IF;
            IF d_op.status NOT IN ('collecting_information', 'awaiting_deposit') OR coalesce(d_op.quoted_source_amount, 0) <> 0
               OR d_op.mixed_group_id IS NOT NULL
               OR EXISTS (SELECT 1 FROM remittance_operation_receipts x WHERE x.operation_id = d_id)
               OR EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.operation_id = d_id AND x.anulado_en IS NULL AND x.descartado_en IS NULL) THEN
              v_skipped := v_skipped || jsonb_build_object('id', d_id, 'motivo', 'ya_no_esta_vacia');
              CONTINUE;
            END IF;
            IF v_holder_lock AND EXISTS (SELECT 1 FROM remittance_beneficiaries x
                                          WHERE x.operation_id = d_id AND x.status = 'vigente' AND x.beneficiary_type = ANY (v_fit)) THEN
              v_skipped := v_skipped || jsonb_build_object('id', d_id, 'motivo', 'beneficiarios_bloqueados');
              CONTINUE;
            END IF;

            d_moved := '[]'::jsonb; d_dups := '[]'::jsonb;
            FOR b IN SELECT * FROM remittance_beneficiaries x
                      WHERE x.operation_id = d_id AND x.status = 'vigente' AND x.beneficiary_type = ANY (v_fit)
                      ORDER BY x.position, x.id LOOP
              SELECT t.id INTO v_twin FROM remittance_beneficiaries t
               WHERE t.operation_id = v_dest AND t.status = 'vigente' AND t.beneficiary_type = ANY (v_fit)
                 AND ((nullif(btrim(coalesce(b.phone, '')), '') IS NOT NULL AND t.phone = b.phone)
                   OR (nullif(btrim(coalesce(b.card_number, '')), '') IS NOT NULL AND t.card_number = b.card_number)
                   OR (nullif(btrim(coalesce(b.zelle_account, '')), '') IS NOT NULL AND t.zelle_account = b.zelle_account))
               LIMIT 1;
              IF v_twin IS NOT NULL THEN
                UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now() WHERE id = b.id;
                INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
                VALUES (d_op.account_id, 'remittance_beneficiaries', b.id, 'status', v_action, v_actor, v_reason,
                        jsonb_build_object('status', 'vigente', 'operation_id', d_id),
                        jsonb_build_object('status', 'reemplazado', 'duplicate_of', v_twin, 'holder', v_dest));
                d_dups := d_dups || to_jsonb(b.id);
              ELSE
                SELECT coalesce(max(x.block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries x WHERE x.operation_id = v_dest;
                SELECT coalesce(max(x.position), 0) + 1 INTO v_pos
                  FROM remittance_beneficiaries x WHERE x.operation_id = v_dest AND x.status = 'vigente';
                UPDATE remittance_beneficiaries SET operation_id = v_dest, block_index = v_block, position = v_pos WHERE id = b.id;
                INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
                VALUES (d_op.account_id, 'remittance_beneficiaries', b.id, 'operation_id', v_action, v_actor, v_reason,
                        jsonb_build_object('operation_id', d_id, 'block_index', b.block_index, 'position', b.position),
                        jsonb_build_object('operation_id', v_dest, 'block_index', v_block, 'position', v_pos));
                d_moved := d_moved || to_jsonb(b.id);
              END IF;
            END LOOP;

            UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = d_id;
            INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
            VALUES (d_op.account_id, 'remittance_operations', d_id, 'status', v_action, v_actor,
                    'empty duplicate of ' || v_dest || ' cancelled; ' || v_reason,
                    jsonb_build_object('status', d_op.status, 'service_type', d_op.service_type),
                    jsonb_build_object('status', 'cancelled', 'holder', v_dest, 'moved_recipients', d_moved, 'retired_duplicates', d_dups));
            v_cancelled := v_cancelled || to_jsonb(d_id);
            v_moved := v_moved || d_moved;
            v_dups := v_dups || d_dups;
          END LOOP;

          -- Closing an operation wipes the conversation's partial recipient (trg_reset_beneficiario_parcial_al_cerrar): the
          -- conversation is still going, put it back.
          IF v_parcial IS NOT NULL AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial p WHERE p.conversation_id = p_conv) THEN
            INSERT INTO cerebro_beneficiario_parcial SELECT * FROM jsonb_populate_record(NULL::cerebro_beneficiario_parcial, v_parcial);
          END IF;
        END IF;

        v_cambios := jsonb_build_object(
          'operacion', v_dest, 'servicio', v_to, 'accion_auditoria', v_action, 'actor', v_actor,
          'retirados', coalesce(v_core -> 'retired', '[]'::jsonb), 'reetiquetados', coalesce(v_core -> 'retyped', '[]'::jsonb),
          'canceladas', v_cancelled, 'numeros_movidos', v_moved, 'duplicados_retirados', v_dups, 'omitidas', v_skipped);
      END IF;

    ELSIF v_accion = 'aparte' THEN
      -- A second operation of the same service is never opened while an empty one is already waiting (Q3).
      SELECT o.id INTO v_vacia FROM remittance_operations o
       WHERE o.conversation_id = p_conv AND o.status IN ('collecting_information', 'awaiting_deposit')
         AND coalesce(o.quoted_source_amount, 0) = 0 AND o.mixed_group_id IS NULL
         AND NOT EXISTS (SELECT 1 FROM remittance_operation_receipts x WHERE x.operation_id = o.id)
         AND NOT EXISTS (SELECT 1 FROM depositos_mmg x WHERE x.operation_id = o.id AND x.anulado_en IS NULL AND x.descartado_en IS NULL)
         AND (CASE WHEN o.service_type = 'remesa' THEN o.delivery_method ELSE o.service_type END) = v_servicio
       ORDER BY o.created_at, o.id LIMIT 1;

      IF v_vacia IS NOT NULL THEN
        v_skip := 'ya_existe_vacia';
        v_cambios := jsonb_build_object('operacion', v_vacia);
      ELSE
        -- The new operation copies the customer's deposit data from the newest open operation; it owns no money yet.
        INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                           deposit_method, source_country, source_currency, quoted_source_amount, destination_currency)
        SELECT v_account, p_conv, coalesce(h.contact_id, v_contact), 'collecting_information',
               CASE WHEN v_servicio IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN v_servicio ELSE 'remesa' END,
               CASE WHEN v_servicio IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN NULL ELSE v_servicio END,
               h.deposit_method, h.source_country, coalesce(h.source_currency, 'GYD'), 0,
               CASE WHEN v_servicio = 'mexico' THEN 'MXN' END
          FROM (SELECT x.* FROM remittance_operations x
                 WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled')
                 ORDER BY x.created_at DESC, x.id LIMIT 1) h
        RETURNING id INTO v_nueva;

        IF v_nueva IS NULL THEN
          v_skip := 'sin_operacion';
        ELSE
          INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
          VALUES (v_account, 'remittance_operations', v_nueva, 'service_type', v_action, v_actor, v_reason,
                  '{}'::jsonb, jsonb_build_object('service', v_servicio, 'status', 'collecting_information', 'quoted_source_amount', 0));
          v_changed := true;
          v_cambios := jsonb_build_object('operacion', v_nueva, 'servicio', v_servicio, 'accion_auditoria', v_action, 'actor', v_actor);
        END IF;
      END IF;

    ELSE
      -- mixto: the deposit covers the holder's service and the new one. The 255 bot split does the work (not reimplemented here):
      -- the holder keeps deposit - minimum of the new service, the new service gets its minimum, one group.
      v_to := v_r -> 'adicionales' -> 0 ->> 'servicio';
      v_monto := (v_r -> 'adicionales' -> 0 ->> 'monto')::numeric;
      v_deposito := (v_r -> 'evidencia' ->> 'deposito')::numeric;
      v_x_srv := (SELECT e ->> 'servicio' FROM jsonb_array_elements(v_r -> 'operaciones') e WHERE e ->> 'id' = v_dest::text LIMIT 1);
      v_lbl_x := (SELECT t.l FROM (VALUES ('cuban_card', 'tarjeta cup'), ('clasica', 'clasica'), ('tropical', 'tropical'),
                                          ('zelle', 'zelle'), ('efectivo_usd', 'efectivo usd'), ('recarga', 'recarga'),
                                          ('saldo', 'saldo'), ('combo', 'combo'), ('visa', 'visa'), ('mexico', 'mexico')) AS t(k, l)
                   WHERE t.k = v_x_srv);
      v_lbl_y := (SELECT t.l FROM (VALUES ('cuban_card', 'tarjeta cup'), ('clasica', 'clasica'), ('tropical', 'tropical'),
                                          ('zelle', 'zelle'), ('efectivo_usd', 'efectivo usd'), ('recarga', 'recarga'),
                                          ('saldo', 'saldo'), ('combo', 'combo'), ('visa', 'visa'), ('mexico', 'mexico')) AS t(k, l)
                   WHERE t.k = v_to);

      IF v_lbl_x IS NULL OR v_lbl_y IS NULL OR v_deposito IS NULL OR v_deposito <= v_monto THEN
        v_skip := 'reparto_rechazado';
        v_detalle := 'no hay partes validas para repartir';
      ELSE
        v_partes := v_lbl_x || ' ' || (v_deposito - v_monto)::bigint || ', ' || v_lbl_y || ' ' || v_monto::bigint;
        v_reparto := cerebro_repartir_envio(p_conv, v_partes, p_exec);
        SELECT o.mixed_group_id INTO v_grupo FROM remittance_operations o WHERE o.id = v_dest;
        IF v_grupo IS NULL THEN
          -- The split refused (its own reply says why): nothing was written.
          v_skip := 'reparto_rechazado';
          v_detalle := v_reparto;
        ELSE
          v_changed := true;
          v_cambios := jsonb_build_object('operacion', v_dest, 'grupo', v_grupo, 'servicio', v_to, 'partes', v_partes,
                                          'reparto', v_reparto, 'accion_auditoria', 'automation_mixed_split',
                                          'actor', 'automation:cerebro_repartir_envio');
        END IF;
      END IF;
    END IF;

    PERFORM set_config('wacrm.origin', v_prev_origin, true);
    PERFORM set_config('wacrm.actor', v_prev_actor, true);
  EXCEPTION WHEN OTHERS THEN
    -- The sub-transaction (and its set_config calls) is already rolled back; fail open with the resolver's answer.
    RETURN coalesce(v_r, v_safe) || jsonb_build_object('aplicado', false, 'cambios', '{}'::jsonb,
                                                       'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200),
                                                       'mensaje', 'No se pudo aplicar el cambio de servicio por un error interno: no se cambió nada.');
  END;

  IF NOT v_changed THEN
    RETURN v_r || jsonb_build_object('aplicado', false, 'motivo', coalesce(v_skip, v_r ->> 'motivo'), 'cambios', v_cambios)
           || CASE WHEN v_detalle IS NOT NULL THEN jsonb_build_object('detalle', left(v_detalle, 200)) ELSE '{}'::jsonb END
           -- (279) what the skip means, in plain Spanish (the resolver's sentence described a change that did not happen)
           || CASE v_skip
                WHEN 'ya_existe_vacia' THEN jsonb_build_object('mensaje', 'Ya hay una operación vacía de ese servicio esperando su depósito: no se abre otra.')
                WHEN 'reparto_rechazado' THEN jsonb_build_object('mensaje', 'No se pudo repartir el depósito entre los dos servicios: ' || coalesce(left(v_detalle, 200), 'el reparto no es válido') || ' No se cambió nada.')
                WHEN 'sin_operacion' THEN jsonb_build_object('mensaje', 'No hay ninguna operación abierta de la que abrir la adicional: no se cambió nada.')
                ELSE '{}'::jsonb END;
  END IF;
  RETURN v_r || jsonb_build_object('aplicado', true, 'cambios', v_cambios)
         -- (286) to cash: say what the cash delivery still needs, from what is saved
         || CASE WHEN v_accion = 'convertir' AND v_to = 'efectivo_usd' AND v_dest IS NOT NULL THEN jsonb_build_object('mensaje',
              coalesce(v_r ->> 'mensaje', '') || (
                SELECT CASE WHEN cb.id IS NULL
                            THEN ' La tarjeta o cuenta guardada no sirve para efectivo y no tengo datos de quien recibe: falta el nombre, el celular y la dirección en Cuba.'
                            ELSE ' Ya tengo' || concat_ws(' y', CASE WHEN cb.name IS NOT NULL THEN ' el nombre ' || cb.name END,
                                                              CASE WHEN cb.phone IS NOT NULL THEN ' el celular ' || cb.phone END)
                                 || '; falta' || concat_ws(' y', CASE WHEN cb.phone IS NULL THEN ' el celular' END,
                                                               CASE WHEN nullif(btrim(coalesce(cb.address, '')), '') IS NULL THEN ' la dirección en Cuba' END) || '.' END
                  FROM (SELECT 1) one LEFT JOIN LATERAL (SELECT x.* FROM remittance_beneficiaries x
                         WHERE x.operation_id = v_dest AND x.status = 'vigente' AND x.beneficiary_type = 'efectivo_usd' ORDER BY x.position LIMIT 1) cb ON true)) ELSE '{}'::jsonb END;
EXCEPTION WHEN OTHERS THEN
  -- Never raise into the bot (the lock or the resolver call itself failed).
  RETURN coalesce(v_r, v_safe) || jsonb_build_object('aplicado', false, 'cambios', '{}'::jsonb,
                                                     'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200),
                                                       'mensaje', 'No se pudo aplicar el cambio de servicio por un error interno: no se cambió nada.');
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_cotizar(p_conv uuid, p_monto numeric, p_direccion text, p_moneda_destino text, p_via text DEFAULT NULL::text, p_execution_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- El cliente SIEMPRE deposita guyaneses: ver la divergencia 2 de la cabecera.
  c_origen  constant text := 'gyd';
  v_dir     text := lower(btrim(coalesce(p_direccion, '')));
  v_dest    text := lower(btrim(coalesce(p_moneda_destino, '')));
  v_via     text := lower(btrim(coalesce(p_via, '')));
  v_unica   boolean;
  v_tasa_u  numeric;   -- la tasa unica de usd (Clasica, Tropical, Mexico, USDT)
  v_tasa    numeric;   -- la tasa que se aplica de verdad a esta cotizacion
  v_gyd     numeric;   -- lo que deposita el cliente
  v_destino numeric;   -- lo que recibe el beneficiario
  v_usd     numeric;
  v_exacto  numeric;   -- solo gyd->usd: los GYD exactos de esos dolares enteros
  v_aplica  text;
  v_herr    text;      -- la etiqueta por direccion, preservada para la auditoria
BEGIN
  IF p_conv IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'sin_conversacion');
  END IF;
  IF p_monto IS NULL OR p_monto <= 0 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'monto_invalido');
  END IF;

  -- Direccion. 'desde_deposito' = el cliente dice lo que DEPOSITA y quiere saber que llega;
  -- 'hacia_destino' = dice lo que quiere que LLEGUE y quiere saber cuanto depositar.
  IF v_dir IN ('desde_deposito', 'deposito', 'desde') THEN
    v_dir := 'desde_deposito';
  ELSIF v_dir IN ('hacia_destino', 'destino', 'hacia') THEN
    v_dir := 'hacia_destino';
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'direccion_desconocida',
                              'direccion', p_direccion,
                              'validas', jsonb_build_array('desde_deposito', 'hacia_destino'));
  END IF;

  IF v_dest IN ('cup', 'pesos', 'pesos_cubanos') THEN
    v_dest := 'cup';
  ELSIF v_dest IN ('usd', 'dolares', 'dolar') THEN
    v_dest := 'usd';
  ELSE
    RETURN jsonb_build_object('ok', false, 'reason', 'moneda_destino_desconocida',
                              'moneda_destino', p_moneda_destino,
                              'validas', jsonb_build_array('cup', 'usd'));
  END IF;

  -- Divergencia 1: el efectivo tiene su propia tasa y su propia tool. Antes se colaba como Zelle.
  IF v_via ~ '^efectivo' THEN
    -- (289) the customer named the cash service: it is declared (implicitly: a later explicit declaration of the bot wins)
    PERFORM _cerebro_declarar_implicito(p_conv, 'efectivo_usd', 'cotizar');
    RETURN jsonb_build_object('ok', false, 'reason', 'efectivo_tiene_tasa_propia',
                              'usa', 'consultar_servicio(''efectivo_usd'')');
  END IF;

  IF v_dest = 'cup' THEN
    -- ---------------------------------------------------------------- CUP
    SELECT t.tasa_cup INTO v_tasa
      FROM tasas t
     WHERE t.moneda = c_origen
     ORDER BY t.fecha DESC, t.actualizada_at DESC
     LIMIT 1;
    IF v_tasa IS NULL OR v_tasa <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', c_origen);
    END IF;

    IF v_dir = 'desde_deposito' THEN           -- era calcular_envio
      v_herr    := 'calcular_envio';
      v_gyd     := p_monto;
      v_destino := round(p_monto * v_tasa);
    ELSE                                        -- era calcular_inverso
      v_herr    := 'calcular_inverso';
      v_destino := p_monto;
      -- ceil al multiplo de 20 superior, igual que calcular_inverso con moneda='gyd'
      v_gyd     := ceil((p_monto / v_tasa) / 20) * 20;
    END IF;
    v_aplica := 'Tarjeta en CUP';

    PERFORM cerebro_registrar_cotizacion(p_conv, v_gyd, v_destino, 'CUP', v_herr);
    PERFORM cerebro_registrar_via_cotizada(p_conv, v_herr, 'cuban_card', p_execution_id, NULL);
    -- (289) a CUP quote names the card rail
    PERFORM _cerebro_declarar_implicito(p_conv, 'cuban_card', 'cotizar');

    RETURN jsonb_build_object(
      'ok', true, 'herramienta', v_herr, 'direccion', v_dir,
      'deposita_gyd', v_gyd, 'recibe_monto', v_destino, 'recibe_moneda', 'CUP',
      'tasa', v_tasa, 'aplica_a', v_aplica);
  END IF;

  -- ------------------------------------------------------------------ USD
  -- Zelle va por TRAMOS de USD; Clasica, Tropical, Mexico y USDT tienen tasa unica. Vacio = Zelle,
  -- igual que hoy.
  v_unica := (coalesce(nullif(v_via, ''), 'zelle') ~ '^(cl[aá]sica|tropical|m[eé]xico|usdt)');
  SELECT t.tasa_cup INTO v_tasa_u
    FROM tasas t
   WHERE t.moneda = 'usd'
   ORDER BY t.fecha DESC, t.actualizada_at DESC
   LIMIT 1;
  v_aplica := CASE WHEN v_unica THEN 'Clasica/Tropical/Mexico (tasa unica)'
                   ELSE 'Zelle (por tramos)' END;

  IF v_dir = 'hacia_destino' THEN               -- era calcular_usd
    v_herr := 'calcular_usd';
    -- floor y no round: los dolares SIEMPRE se entregan enteros, y redondear hacia arriba
    -- prometeria un dolar mas de lo que cubre el deposito.
    v_usd  := floor(p_monto);
    IF v_usd <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'monto_invalido');
    END IF;
    v_tasa := CASE WHEN v_unica THEN v_tasa_u
                   ELSE coalesce(cerebro_tasa_zelle(v_usd), v_tasa_u) END;
    IF v_tasa IS NULL OR v_tasa <= 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
    END IF;
    v_gyd     := round(v_usd * v_tasa);
    v_destino := v_usd;
    -- Apunta el objetivo del envio (072/075) para que un deposito que no lo cubra no se de por
    -- bueno. Va aqui y no en una tool aparte porque el modelo no llama a la tool aparte: se monto
    -- `fijar_objetivo`, se le ordeno en dos sitios del prompt, y fue 0 de 2 con mensajes reales.
    PERFORM * FROM cerebro_fijar_objetivo(p_conv, v_usd, 'USD');
  ELSE                                           -- era calcular_usd_desde_gyd
    v_herr := 'calcular_usd_desde_gyd';
    v_gyd  := p_monto;
    IF v_unica THEN
      IF v_tasa_u IS NULL OR v_tasa_u <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
      END IF;
      v_tasa := v_tasa_u;
      v_usd  := floor(p_monto / v_tasa_u);
    ELSE
      SELECT z.usd, z.tasa INTO v_usd, v_tasa
        FROM cerebro_zelle_cotizar_gyd(p_monto) z;
      -- el COALESCE a la tasa unica es el de calcular_usd_desde_gyd, no una invencion
      IF v_tasa IS NULL OR v_tasa <= 0 THEN
        IF v_tasa_u IS NULL OR v_tasa_u <= 0 THEN
          RETURN jsonb_build_object('ok', false, 'reason', 'sin_tasa', 'moneda', 'usd');
        END IF;
        v_tasa := v_tasa_u;
      END IF;
      v_usd := coalesce(v_usd, floor(p_monto / v_tasa_u));
    END IF;
    v_destino := v_usd;
    v_exacto  := round(v_usd * v_tasa);
  END IF;

  PERFORM cerebro_registrar_cotizacion(p_conv, v_gyd, v_destino, 'USD', v_herr);
  PERFORM cerebro_registrar_via_cotizada(p_conv, v_herr, nullif(v_via, ''), p_execution_id, v_gyd);
  -- (289) a quote that names its via (zelle / clasica / tropical / mexico...) is the customer naming the service; an empty via names none
  IF nullif(v_via, '') IS NOT NULL THEN PERFORM _cerebro_declarar_implicito(p_conv, v_via, 'cotizar'); END IF;

  RETURN jsonb_strip_nulls(jsonb_build_object(
    'ok', true, 'herramienta', v_herr, 'direccion', v_dir,
    'deposita_gyd', v_gyd, 'recibe_monto', v_destino, 'recibe_moneda', 'USD',
    'tasa', v_tasa, 'aplica_a', v_aplica,
    'via', nullif(v_via, ''),
    'deposita_gyd_exacto', v_exacto));
END;
$function$;

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
                       OR EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = x.id AND d.anulado_en IS NULL AND d.descartado_en IS NULL))) THEN
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
                    AND (o.mixed_group_id IS NOT NULL OR coalesce(o.quoted_source_amount, 0) > 0
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
  v_min_cup numeric; v_min_usd numeric; v_min_rec numeric; v_min_efe numeric; v_saldo numeric; v_min_mex numeric;
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
  v_alt boolean := false;
BEGIN
  -- (283) the customer's words (cup, pesos, efectivo...) are understood here, not in the agent.
  p_declarado := _cerebro_servicio_clave(p_declarado);
  -- Initialised here, not in DECLARE: an error in a declaration is not caught by the EXCEPTION clause below.
  v_hoy := (p_ahora AT TIME ZONE 'America/Guyana')::date;
  v_min_cup := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_min_usd := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric,
                        NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
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
      'vacia', NOT (r.recibo OR r.dep) AND coalesce(r.quoted_source_amount, 0) = 0
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
      IF v_status IN ('transferring', 'incident') THEN v_motivo := 'estado_no_permite'; EXIT flow; END IF;
    END IF;

    -- R4 a recarga needs a live or announced promo (207/211).
    IF v_y = 'recarga' AND NOT v_promo THEN v_motivo := 'recarga_sin_promo'; EXIT flow; END IF;

    -- R5-R7 a declared target Y.
    IF v_y IS NOT NULL THEN
      v_min_y := CASE v_y
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_usd WHEN 'tropical' THEN v_min_usd
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
                   WHEN 'zelle' THEN v_min_usd WHEN 'clasica' THEN v_min_usd WHEN 'tropical' THEN v_min_usd
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
    'reparto_planeado', v_plan);
EXCEPTION WHEN OTHERS THEN
  -- Fail open: the bot keeps working without the resolver's answer.
  RETURN jsonb_build_object(
    'version', 2, 'servicio', NULL, 'en_curso', NULL, 'accion', 'ninguna', 'permitido', false, 'motivo', 'error',
    'mensaje', 'No se pudo comprobar el servicio en este momento: no se cambió nada.', 'minimo_gyd', NULL, 'faltante_gyd', NULL, 'destino_operacion', NULL, 'convertir_a', NULL,
    'cancelar', '[]'::jsonb, 'grupo_mixto', NULL, 'adicionales', '[]'::jsonb, 'operaciones', '[]'::jsonb,
    'evidencia', '{}'::jsonb, 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200));
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_registrar_deposito(p_conv uuid, p_monto numeric, p_moneda text, p_stage uuid, p_nota text, p_comp_id text)
 RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  v_rev     boolean;
  v_recarga boolean := false;
  v_combo   boolean := false;
  v_visa    boolean := false;
  v_mexico  boolean := false;
  v_open_m  boolean := false;
  v_open_r  boolean := false;
  v_open_c  boolean := false;
  v_open_v  boolean := false;
  v_ya      uuid;
  v_ex      uuid;
  v_suma    uuid;
  v_id      uuid;
  v_phone   text;
  v_ref     text;
  v_nota    text;
  v_motivo  text;
  v_contact uuid;
  v_total   numeric;
  v_ventana integer := COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6);
  v_min_cup numeric := COALESCE(NULLIF(cerebro_config_get('minimo_gyd_cup'), '')::numeric, 5000);
  v_res     jsonb;
  v_dest    uuid;
  v_accion  text;
  v_anchor  uuid;
BEGIN
  -- (267) One writer at a time per conversation: the same lock cerebro_aplicar_servicio (266) takes (re-entrant).
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_servicio:' || p_conv::text, 0));
  v_rev := cerebro_es_revendedor(p_conv);
  -- (202, 209, 213, 267) Which kind of operation this deposit belongs to (at most one flag is true; none = a remesa).
  -- (267) The service comes from facts, never from the customer's words: cerebro_resolver_servicio (265) gives the service
  -- of the operation this deposit joins or creates (the open operation that holds the money, else the declared intent,
  -- else Q1, else remesa). A reseller's deposit is always a remesa. A resolver error keeps the remesa fallback.
  IF NOT v_rev THEN
    v_res    := cerebro_resolver_servicio(p_conv, NULL::text, NULL::text, p_monto);
    v_dest   := nullif(v_res ->> 'destino_operacion', '')::uuid;
    v_accion := v_res ->> 'accion';
    IF COALESCE(v_res ->> 'motivo', '') = 'error' THEN
      NULL;  -- fail open: remesa, all three flags stay false
    ELSIF v_res ->> 'servicio' IS NOT NULL THEN
      v_recarga := (v_res ->> 'servicio') = 'recarga';
      v_combo   := (v_res ->> 'servicio') = 'combo';
      v_visa    := (v_res ->> 'servicio') = 'visa';
      v_mexico  := (v_res ->> 'servicio') = 'mexico';
    ELSE
      -- No service decided (several open operations and no deposit): the open operation keeps winning, in the live order
      -- recarga > combo > visa. No words are read; with nothing open the deposit is a remesa.
      v_open_r := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'recarga' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_c := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_v := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'visa' AND o.status NOT IN ('completed', 'cancelled'));
      v_open_m := EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv
                            AND o.service_type = 'mexico' AND o.status NOT IN ('completed', 'cancelled'));
      v_recarga := v_open_r;
      v_combo   := v_open_c AND NOT v_open_r;
      v_visa    := v_open_v AND NOT v_open_r AND NOT v_open_c;
      v_mexico  := v_open_m AND NOT v_open_r AND NOT v_open_c AND NOT v_open_v;
    END IF;
  END IF;

  -- (291) Several open operations of the same send, created before any money (and no split plan waiting): the deposit belongs to the send's
  -- ANCHOR, which never depends on the latest implicit declaration. An implicit declaration (actor implicit:%, or the one the recarga numbers leave)
  -- never decides which operation holds money. Order: the operation of the service the bot declared deliberately (declarar_servicio, cambiar_servicio...);
  -- else the oldest open operation the deposit reaches the minimum of; else the oldest open operation. The rest of this function is unchanged:
  -- the anchor is only put first among the operations the movido branch may take.
  IF NOT v_rev
     AND NOT EXISTS (SELECT 1 FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv)
     AND (SELECT count(*) FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')) >= 2
     AND NOT EXISTS (SELECT 1 FROM remittance_operations o
                      WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
                        AND (o.mixed_group_id IS NOT NULL OR o.status IN ('transferring', 'incident', 'ready_to_transfer', 'deposit_verification')
                             OR _cerebro_op_tiene_dinero(o.id) OR coalesce(o.quoted_source_amount, 0) > 0
                             OR coalesce(o.admin_locked_fields, '{}'::jsonb) ? 'quoted_source_amount')) THEN
    SELECT x.id INTO v_anchor
      FROM remittance_operations x
     WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled')
     ORDER BY (cerebro_riel_op(x.id) = (SELECT d.servicio FROM cerebro_servicio_declarado d
                                         WHERE d.conversation_id = p_conv AND coalesce(d.actor, '') NOT LIKE 'implicit:%'
                                           AND coalesce(d.actor, '') NOT LIKE '%registrar_numeros_recarga%')) DESC NULLS LAST,
              (coalesce(cerebro_minimo_gyd(x.id), 0) <= p_monto) DESC,
              x.created_at, x.id
     LIMIT 1;
  END IF;

  v_nota := COALESCE(p_nota,'');
  IF NULLIF(p_comp_id,'') IS NOT NULL AND v_nota NOT LIKE '%'||p_comp_id||'%' THEN
    v_nota := v_nota || chr(10) || p_comp_id;
  END IF;

  IF NOT cerebro_transid_plausible(NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '')) THEN
    p_stage := 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid;
    v_motivo := 'REFERENCIA IMPOSIBLE: ese numero no puede ser un TransID de MMG. El contador '
      || 'solo crece y este queda por debajo de todos los recibidos, asi que casi seguro '
      || 'lo leyo la vision de una CAPTURA o de una foto de otra pantalla, no de un '
      || 'comprobante directo. NO se ha registrado como deposito normal: mire la imagen y '
      || 'pidale al cliente el comprobante original antes de dar nada por recibido.';
    -- v_nota keeps the caller's note plus the appended reason, byte for byte:
    -- cerebro_parsear_comprobantes still consumes it. The reason column is a
    -- separate variable (never v_nota) so the receipt code never leaks into it.
    v_nota := v_nota || chr(10) || v_motivo;
  END IF;

  -- (160) Idempotency: check remittance_operation_receipts.comp_id instead
  -- of deals.notes LIKE %comp_id%. The substring form is load-bearing:
  -- 156 matched `deals.notes LIKE '%'||p_comp_id||'%'`, and the note
  -- carries the receipt code as 'COMP-'||comp, while the caller passes
  -- the bare comp. An equality test alone therefore never matches on the
  -- real flow and silently returns 'creado', creating a second
  -- operation for a deposit that was already registered.
  IF NULLIF(p_comp_id,'') IS NOT NULL THEN
    SELECT ro.id INTO v_ya
      FROM remittance_operations ro
      JOIN remittance_operation_receipts r ON r.operation_id = ro.id
     WHERE ro.conversation_id = p_conv
       AND (r.comp_id = p_comp_id OR r.comp_id LIKE '%'||p_comp_id||'%')
     LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (idempotente)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (182 <- 178) The same receipt sent again (another image, another COMP id): its Ref is already
  -- a receipt of an open operation of this chat. It is that deposit, not a new one: never summed,
  -- never a second operation.
  v_ref := NULLIF(substring(v_nota from 'Ref: ([0-9]+)'), '');
  IF v_ref IS NOT NULL THEN
    SELECT ro.id INTO v_ya
      FROM remittance_operations ro
      JOIN remittance_operation_receipts r ON r.operation_id = ro.id
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed', 'cancelled')
       AND r.reference ~ ('(^|[^0-9])' || v_ref || '([^0-9]|$)')
     ORDER BY ro.created_at DESC LIMIT 1;
    IF v_ya IS NOT NULL THEN
      RETURN QUERY SELECT v_ya, 'ya registrado (misma referencia)'::text, v_rev, false; RETURN;
    END IF;
  END IF;

  -- (160, 232) movido branch: find the latest open remesa operation for this conversation that has no receipt yet,
  -- and is NOT (has a vigente recipient AND still owes saldo AND already holds money).
  -- 156's guard was `NOT (d.value > 0 AND notes LIKE '%BENEFICIARIO%')`: value is money ALREADY deposited, so a deal with
  -- money and a recipient was a complete remittance and a new deposit was a different one. 160 translated "money
  -- already there" into `saldo > 0` (money still OWED), which for a recipient-first operation (nothing deposited, the
  -- whole quote owed) excluded exactly the operation the deposit belongs to (Edel, 2026-10-08).
  -- (232) The guard now needs the operation to hold money. It holds money when quoted_source_amount > 0, or any receipt
  -- row hangs from it, or something was consumed against it (the `depositado` of cerebro_saldo_operacion). An operation
  -- in incident or with a locked quoted_source_amount keeps the 160 behaviour: the deposit amount would be overwritten
  -- over a decision someone made, or suppressed by the lock.
  IF NOT v_rev THEN
    SELECT ro.id INTO v_ex
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.status NOT IN ('completed','cancelled')
       -- (202) or the recharge the customer's numbers opened
       -- (209) or the combo the customer is ordering
       AND (ro.id = v_anchor OR ro.service_type = 'remesa' OR (v_recarga AND ro.service_type = 'recarga')
            OR (v_combo AND ro.service_type = 'combo')
            -- (213) or the visa the customer is paying for
            OR (v_visa AND ro.service_type = 'visa')
            -- (273) or the Mexico send the customer is paying for
            OR (v_mexico AND ro.service_type = 'mexico'))
       AND NOT EXISTS (
         SELECT 1 FROM remittance_operation_receipts r
          WHERE r.operation_id = ro.id AND r.comp_id IS NOT NULL)
       AND NOT (
         (EXISTS (
           SELECT 1 FROM remittance_beneficiaries b
            WHERE b.operation_id = ro.id AND b.status = 'vigente'))
         -- COALESCE is load-bearing: cerebro_saldo_operacion returns NULL
         -- when the operation has no open objetivo, and `TRUE AND NULL`
         -- evaluates to NULL, which excludes the row and pushes a
         -- beneficiary-first operation into 'creado' (a phantom second
         -- remesa). 156's equivalent could never be NULL (deals.value is
         -- NOT NULL, notes is COALESCEd), so the guard must stay
         -- two-valued here too.
         AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0)
         -- (232) ... and only when the operation already holds money (or is not safe to overwrite).
         AND (COALESCE(ro.quoted_source_amount, 0) > 0
              OR EXISTS (SELECT 1 FROM remittance_operation_receipts r2 WHERE r2.operation_id = ro.id)
              OR COALESCE((SELECT s.depositado FROM cerebro_saldo_operacion(ro.id) s), 0) > 0
              OR ro.status = 'incident'
              OR COALESCE(ro.admin_locked_fields, '{}'::jsonb) ? 'quoted_source_amount'))
     -- (267) the operation the resolver names (destino_operacion) first, when it is still open and eligible above
     -- (280) an operation outside a group comes before a group member (after a partial application the next deposit belongs to the pending
     -- part, never to a member of a group that is already covered and locked); with a plan waiting, the part the customer listed first
     -- takes the deposit; ties are broken by id so the choice is deterministic.
     -- (291) the send's anchor comes first (see above)
     ORDER BY (ro.id = v_anchor) DESC NULLS LAST, (ro.id = v_dest) DESC NULLS LAST, (ro.mixed_group_id IS NULL) DESC,
              coalesce((SELECT pl.partes -> 0 ->> 'servicio' = cerebro_riel_op(ro.id) FROM cerebro_reparto_planeado pl
                         WHERE pl.conversation_id = ro.conversation_id), false) DESC,
              ro.created_at DESC, ro.id LIMIT 1;
  END IF;

  -- (182 <- 170) The open WAITING remesa this deposit completes: a remesa of this chat still
  -- being verified or in incident, opened in the window, with a receipt already, that is below
  -- its service minimum, still owes saldo, or this deposit alone is below the smallest minimum.
  -- A remesa that is ready to transfer is never touched. (160's version only took
  -- deposit_verification with saldo > 0 and then OVERWROTE the amount with this deposit.)
  IF NOT v_rev AND v_ex IS NULL THEN
    SELECT ro.id INTO v_suma
      FROM remittance_operations ro
     WHERE ro.conversation_id = p_conv
       AND ro.service_type = 'remesa'
       AND ro.status IN ('deposit_verification', 'incident')
       AND ro.created_at > now() - make_interval(hours => v_ventana)
       AND EXISTS (SELECT 1 FROM remittance_operation_receipts r WHERE r.operation_id = ro.id)  -- it has a deposit (170: notes LIKE '%DEPOSITO%')
       AND COALESCE(ro.incident_reason, '') NOT LIKE 'REFERENCIA IMPOSIBLE%'
       AND (COALESCE((SELECT s.saldo FROM cerebro_saldo_operacion(ro.id) s), 0) > 0
            OR ro.quoted_source_amount < cerebro_minimo_gyd(ro.id)
            OR p_monto < v_min_cup)
     ORDER BY ro.created_at DESC LIMIT 1;
  END IF;

  -- (160) Recarga 24 h window: now decided up front by the resolver (267).

  SELECT c.phone, v.contact_id INTO v_phone, v_contact
    FROM conversations v JOIN contacts c ON c.id = v.contact_id WHERE v.id = p_conv;

  -- (160) movido branch: update the found op directly.
  IF v_ex IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_ex;
    -- (156) dual-write: insert parsed receipts for this operation (before the conversion: the resolver reads them).
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_ex
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_ex);
    -- (182 <- 170) Below the minimum of its service: wait for the rest.
    PERFORM cerebro_objetivo_minimo(p_conv, v_ex);
    -- (202) a recharge takes any number typed since (no repeats)
    IF (SELECT service_type FROM remittance_operations WHERE id = v_ex) = 'recarga' THEN
      PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
    END IF;
    -- (277) a split planned before the deposit is applied when this deposit is exactly its total
    PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_ex);
    RETURN QUERY SELECT v_ex, 'movido'::text, false, false; RETURN;
  END IF;

  -- (160) sumado branch: update the found op directly.
  IF v_suma IS NOT NULL THEN
    UPDATE remittance_operations ro
       SET status = cerebro_estado_desde_etapa(p_stage),
           incident_reason = CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident'
                                  THEN v_motivo ELSE NULL END,
           quoted_source_amount = ro.quoted_source_amount + p_monto,
           contact_id = coalesce(v_contact, ro.contact_id)
     WHERE ro.id = v_suma;
    -- (156) dual-write (before the conversion: the resolver reads the receipts).
    INSERT INTO public.remittance_operation_receipts (
      operation_id, conversation_id, comp_id, amount, currency, receipt_status,
      recipient, via, reference, receipt_date, correct_destination, source)
    SELECT o.id, o.conversation_id, p.comp_id, p.amount, p.currency, p.receipt_status,
           p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
      FROM remittance_operations o
     CROSS JOIN LATERAL cerebro_parsear_comprobantes(v_nota) p
     WHERE o.id = v_suma
    ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;
    -- (267) the resolver said convert: the deposit is attached, so the service is decided again and converted here
    IF v_accion = 'convertir' THEN
      PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
    END IF;
    PERFORM cerebro_objetivo_atar_op(p_conv, v_suma);
    -- (182 <- 170) The objetivo covers the whole remesa.
    PERFORM cerebro_objetivo_minimo(p_conv, v_suma, true);
    -- (182 <- 170) The earlier receipts of the remesa that were never crossed are crossed now;
    -- this one is crossed by the Cerebro's own node right after this call.
    PERFORM cerebro_cruzar_pendientes(v_suma, v_ref);
    PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_suma);
    RETURN QUERY SELECT v_suma, 'sumado al envio abierto'::text, false, true; RETURN;
  END IF;

  -- (160) creado branch: INSERT remittance_operations directly, no deal.
  INSERT INTO remittance_operations (
    account_id, conversation_id, contact_id, deal_id, status,
    service_type, quoted_source_amount, source_currency, destination_currency, created_at,
    completed_at, cancelled_at, incident_reason
  )
  VALUES (
    (SELECT account_id FROM conversations WHERE id = p_conv),
    p_conv, v_contact, NULL,   -- deal_id = NULL (the whole point)
    cerebro_estado_desde_etapa(p_stage),
    CASE WHEN v_rev THEN 'remesa' WHEN v_combo THEN 'combo' WHEN v_visa THEN 'visa' WHEN v_mexico THEN 'mexico' WHEN v_recarga THEN 'recarga' ELSE 'remesa' END,
    p_monto, coalesce(p_moneda, 'GYD'), CASE WHEN v_mexico AND NOT v_rev THEN 'MXN' END, now(),
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'completed' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'cancelled' THEN now() END,
    CASE WHEN cerebro_estado_desde_etapa(p_stage) = 'incident' THEN v_motivo ELSE NULL END
  )
  RETURNING id INTO v_id;

  -- (267) the resolver said convert: the deposit is attached to v_id, so the service is decided again and converted here
  IF v_accion = 'convertir' AND NOT v_rev THEN
    PERFORM cerebro_aplicar_servicio(p_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
  END IF;

  IF NOT v_rev THEN PERFORM cerebro_objetivo_atar_op(p_conv, v_id); END IF;

  -- (201) A new recharge takes the Cuban numbers the customer TYPED since asking for it (same window as v_recarga).
  IF v_recarga AND NOT v_rev THEN
    PERFORM crm_registrar_numeros_recarga(p_conv, cerebro_textos_cliente_recientes(p_conv));
  END IF;

  -- (156) dual-write: parse and insert receipts linked to this new op.
  INSERT INTO public.remittance_operation_receipts (
    operation_id, conversation_id, comp_id, amount, currency, receipt_status,
    recipient, via, reference, receipt_date, correct_destination, source)
  SELECT v_id, p_conv, p.comp_id, p.amount, p.currency, p.receipt_status,
         p.recipient, p.via, p.reference, p.receipt_date, p.correct_destination, 'bot'
    FROM cerebro_parsear_comprobantes(v_nota) p
  ON CONFLICT (operation_id, comp_id) WHERE comp_id IS NOT NULL DO NOTHING;

  -- (182 <- 170) Below the minimum of its service: wait for the rest.
  IF NOT v_rev THEN PERFORM cerebro_objetivo_minimo(p_conv, v_id); END IF;

  -- (160) OUT column keeps its name 'deal_id' but now carries the
  -- operation id. Callers (n8n node) pass it back to
  -- cerebro_cruzar_deposito which now calls cerebro_resolve_op_id.
  IF NOT v_rev THEN PERFORM _cerebro_aplicar_plan_reparto(p_conv, v_id); END IF;
  RETURN QUERY SELECT v_id, 'creado'::text, v_rev, false;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_actor       constant text := 'automation:cerebro_repartir_envio';
  v_parse       jsonb;
  v_op          uuid;
  v_res         jsonb;
  v_text        text;
  v_outcome     text;
  v_prev_origin text;
  v_prev_actor  text;
  v_p           jsonb;
  v_o           remittance_operations%ROWTYPE;
  v_lista       text[] := ARRAY[]::text[];
  v_dep         numeric;
  v_saldo       numeric;
  v_motivo      text;
  v_a           text;
  v_b           text;
  v_plan        jsonb;
  v_dverif      numeric;
  v_totop       numeric;
  v_sum         numeric;
  v_parcial     boolean := false;
  v_npartes     int;
  v_pl          cerebro_reparto_planeado%ROWTYPE;
  v_pend        jsonb := '[]'::jsonb;
  v_pend_txt    text;
  v_pend_tot    numeric := 0;
  v_e           jsonb;
  v_target      uuid;
  v_mv          jsonb;
  v_core_op     uuid;
BEGIN
  v_parse := _cerebro_partes_envio_parse(p_partes);

  IF NOT (v_parse ->> 'ok')::boolean THEN
    v_outcome := 'no_entendido';
    v_text := CASE WHEN v_parse ->> 'segmento' = '' THEN 'No entendi el reparto: no vi ninguna parte.'
                   ELSE 'No entendi esta parte: "' || (v_parse ->> 'segmento') || '".' END
              || ' Indica cada parte con servicio y monto en GYD, por ejemplo: "clasica 18200, recarga 6200".';
  ELSE
    -- One splitter at a time per conversation.
    PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_repartir_envio:' || p_conv::text, 0));

    -- The operation holding the deposit: grouped first, then deposit/receipt holder, newest first; else the newest with an amount.
    SELECT o.id INTO v_op
      FROM remittance_operations o
     WHERE o.conversation_id = p_conv
       AND o.status NOT IN ('completed', 'cancelled')
       AND (o.mixed_group_id IS NOT NULL
            OR EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
            OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)
            OR coalesce(o.quoted_source_amount, 0) > 0)
     ORDER BY -- (280) with a plan waiting, the operation whose amount is the plan's total holds the deposit being split
              coalesce((SELECT o.quoted_source_amount = pl.total_gyd FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = o.conversation_id), false) DESC,
              -- (280) a group already fully covered (a partial application) is not the holder of the next deposit
              (o.mixed_group_id IS NOT NULL
               AND coalesce((SELECT s.depositado > 0 AND s.saldo <= 0 FROM cerebro_saldo_operacion(o.id) s), false)) ASC,
              (o.mixed_group_id IS NOT NULL) DESC,
              (EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL)
               OR EXISTS (SELECT 1 FROM remittance_operation_receipts rr WHERE rr.operation_id = o.id)) DESC,
              o.created_at DESC
     LIMIT 1;

    IF v_op IS NULL THEN
      -- (277) No deposit yet: the split is PLANNED (parts persisted, one empty operation per part) and applied when a deposit of
      -- exactly the planned total arrives (cerebro_registrar_deposito).
      v_plan := _cerebro_reparto_planear(p_conv, v_parse -> 'partes', true, 'agent:repartir_envio');
      v_outcome := CASE WHEN (v_plan ->> 'ok')::boolean THEN 'planeado' ELSE 'rechazado' END;
      v_text := v_plan ->> 'texto';
    ELSE
      -- (280) Partial deposit: when the parts do not add up to the operation's total but fit inside the verified deposit, the bot is
      -- applying only what is covered now. The rest of the plan stays pending (own empty operation, own data) for the next deposit.
      SELECT s.depositado INTO v_dverif FROM cerebro_saldo_operacion(v_op) s;
      SELECT sum((e ->> 'monto_gyd')::numeric), count(*) INTO v_sum, v_npartes FROM jsonb_array_elements(v_parse -> 'partes') e;
      SELECT CASE WHEN o.mixed_group_id IS NOT NULL
                  THEN (SELECT sum(x.quoted_source_amount) FROM remittance_operations x WHERE x.mixed_group_id = o.mixed_group_id AND x.status <> 'cancelled')
                  ELSE o.quoted_source_amount END
        INTO v_totop FROM remittance_operations o WHERE o.id = v_op;
      v_parcial := coalesce(v_dverif, 0) > 0 AND (v_sum IS DISTINCT FROM v_totop OR v_npartes = 1) AND v_sum <= v_dverif;
      IF v_parcial AND v_npartes = 1 THEN
        -- a single part only makes sense when the plan still has other parts waiting
        SELECT * INTO v_pl FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
        IF NOT FOUND OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_pl.partes) e
                                     WHERE e ->> 'servicio' <> (v_parse -> 'partes' -> 0 ->> 'servicio')) THEN
          v_parcial := false;
        END IF;
      END IF;

      -- (291) The holder of the deposit need not be one of the parts (the customer's parts name the services he wants; the operation the money
      -- landed on may be another one of the same conversation, e.g. a recarga the customer then drops). When the holder is not grouped and its
      -- service is not a part, the verified deposit moves WHOLE to the first part that has an open, ungrouped operation without money
      -- (cerebro_modificar_operacion 'mover_deposito' validates the move: locks left by a person, states, minimum of the target) and the holder
      -- keeps 0 (no money: the bot may cancel it). The move runs inside the block below: a refused split rolls it back.
      v_target := NULL;
      IF NOT EXISTS (SELECT 1 FROM remittance_operations h WHERE h.id = v_op AND h.mixed_group_id IS NOT NULL)
         AND NOT (coalesce(cerebro_riel_op(v_op), '') = ANY (ARRAY(SELECT lower(btrim(e ->> 'servicio')) FROM jsonb_array_elements(v_parse -> 'partes') e))) THEN
        SELECT o.id INTO v_target
          FROM jsonb_array_elements(v_parse -> 'partes') WITH ORDINALITY t(e, ord)
          JOIN remittance_operations o ON o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled', 'transferring')
                                      AND o.mixed_group_id IS NULL AND o.id <> v_op AND cerebro_riel_op(o.id) = lower(btrim(t.e ->> 'servicio'))
                                      AND NOT _cerebro_op_tiene_dinero(o.id)
         ORDER BY t.ord, o.created_at, o.id LIMIT 1;
      END IF;

      v_core_op := v_op;
      v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
      v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');
      BEGIN
        IF v_target IS NOT NULL THEN
          v_mv := cerebro_modificar_operacion(p_conv, v_op, 'mover_deposito', jsonb_build_object('a', v_target), 'agent:repartir_envio');
          IF coalesce((v_mv ->> 'ok')::boolean, false) THEN
            -- the holder keeps nothing: its request amount goes with the money
            PERFORM set_config('wacrm.origin', 'admin', true);
            PERFORM set_config('wacrm.actor', c_actor, true);
            UPDATE remittance_operations SET quoted_source_amount = 0, updated_at = now() WHERE id = v_op AND NOT _cerebro_op_tiene_dinero(v_op);
            v_core_op := v_target;
          END IF;
        END IF;
        PERFORM set_config('wacrm.origin', 'admin', true);
        PERFORM set_config('wacrm.actor', c_actor, true);
        v_res := _repartir_envio_core(v_core_op, v_parse -> 'partes', 'automation_mixed_split', c_actor,
                                      'n8n execution ' || coalesce(nullif(btrim(p_execution), ''), 'unknown'), v_parcial);
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
      EXCEPTION
        WHEN SQLSTATE '22023' THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          v_outcome := 'rechazado';
          IF SQLERRM LIKE 'part % is below its minimum of %' THEN
            v_a := substring(SQLERRM from '^part ([a-z_]+) ');
            v_text := 'REPARTO NO APLICADO: la parte ' || CASE v_a WHEN 'cuban_card' THEN 'tarjeta CUP' WHEN 'efectivo_usd' THEN 'efectivo USD' ELSE v_a END
                      || ' (' || _cerebro_fmt_monto(substring(SQLERRM from '\(([0-9.]+)\)')::numeric) || ' GYD) esta por debajo de su minimo ('
                      || _cerebro_fmt_monto(substring(SQLERRM from 'minimum of ([0-9.]+)$')::numeric) || ' GYD). No se cambio nada. '
                      || 'Preguntale al cliente si sube esa parte o la deja fuera del reparto.';
          ELSIF SQLERRM LIKE 'the parts add up to % but the total to split is %' THEN
            v_a := substring(SQLERRM from 'add up to ([0-9.]+) but');
            v_b := substring(SQLERRM from 'total to split is ([0-9.]+)$');
            -- (277) Facts instead of a bare refusal: the plan is kept and the answer carries what the Decisor needs.
            -- (280) an existing plan is never overwritten by a refused attempt (the bot may have sent only some of its parts)
            IF NOT EXISTS (SELECT 1 FROM cerebro_reparto_planeado WHERE conversation_id = p_conv) THEN
              v_plan := _cerebro_reparto_planear(p_conv, v_parse -> 'partes', false, 'agent:repartir_envio');
            END IF;
            v_text := 'REPARTO NO APLICADO: las partes suman ' || _cerebro_fmt_monto(v_a::numeric) || ' GYD y el deposito a repartir es '
                      || _cerebro_fmt_monto(v_b::numeric) || ' GYD ('
                      || CASE WHEN v_a::numeric > v_b::numeric THEN 'faltan ' || _cerebro_fmt_monto(v_a::numeric - v_b::numeric) || ' GYD para cubrir las partes'
                              ELSE 'sobran ' || _cerebro_fmt_monto(v_b::numeric - v_a::numeric) || ' GYD del deposito' END
                      || '). Partes planeadas: ' || _cerebro_texto_partes(v_parse -> 'partes') || '. No se cambio nada. '
                      || 'Preguntale al cliente que parte cambia (o si deposita el resto) y vuelve a llamar con montos que sumen exactamente '
                      || _cerebro_fmt_monto(v_b::numeric) || ' GYD, o con solo las partes que el deposito verificado cubre (el resto queda pendiente). No prometas ninguna entrega hasta entonces.';
          ELSE
            v_motivo := CASE
              WHEN SQLERRM LIKE 'at least two parts%' THEN 'hacen falta al menos dos servicios'
              WHEN SQLERRM LIKE 'service % appears more than once' THEN 'hay un servicio repetido'
              WHEN SQLERRM LIKE 'the operation''s own service%' THEN 'el servicio de la operacion actual debe ser una de las partes'
              WHEN SQLERRM = 'operation is closed' THEN 'la operacion ya esta cerrada'
              WHEN SQLERRM LIKE 'there is no money to split%' THEN 'la operacion no tiene un monto registrado'
              WHEN SQLERRM LIKE 'group member % is completed%' THEN 'un servicio del grupo ya esta completado'
              ELSE 'el reparto no es valido' END;
            v_text := 'No se pudo repartir: ' || v_motivo || ' (detalle: ' || SQLERRM || '). No cambie nada.';
          END IF;
        WHEN OTHERS THEN
          PERFORM set_config('wacrm.origin', v_prev_origin, true);
          PERFORM set_config('wacrm.actor', v_prev_actor, true);
          RAISE;
      END;

      IF v_res IS NOT NULL THEN
        v_outcome := CASE WHEN v_parcial THEN 'parcial' ELSE 'repartido' END;
        IF v_parcial THEN
          -- (280) The plan keeps only the parts not applied; their operations stay open (and keep their data).
          SELECT * INTO v_pl FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
          IF FOUND THEN
            SELECT coalesce(jsonb_agg(e ORDER BY ord), '[]'::jsonb), coalesce(sum((e ->> 'monto_gyd')::numeric), 0)
              INTO v_pend, v_pend_tot
              FROM jsonb_array_elements(v_pl.partes) WITH ORDINALITY t(e, ord)
             WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_parse -> 'partes') x WHERE x ->> 'servicio' = e ->> 'servicio');
            IF jsonb_array_length(v_pend) = 0 THEN
              DELETE FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
            ELSE
              UPDATE cerebro_reparto_planeado SET partes = v_pend, total_gyd = v_pend_tot, creado_at = now() WHERE conversation_id = p_conv;
              FOR v_e IN SELECT e FROM jsonb_array_elements(v_pend) e LOOP
                PERFORM _cerebro_op_parte(p_conv, v_e ->> 'servicio', 'agent:repartir_envio', 'pending part after partial deposit');
              END LOOP;
              v_pend_txt := _cerebro_texto_partes(v_pend);
            END IF;
          END IF;
        ELSE
          DELETE FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
        END IF;
        FOR v_p IN SELECT * FROM jsonb_array_elements(v_res -> 'partes') LOOP
          SELECT * INTO v_o FROM remittance_operations WHERE id = (v_p ->> 'operation_id')::uuid;
          v_lista := v_lista || (
            CASE v_p ->> 'servicio' WHEN 'cuban_card' THEN 'tarjeta CUP' WHEN 'efectivo_usd' THEN 'efectivo USD' ELSE v_p ->> 'servicio' END
            || ' ' || _cerebro_fmt_monto((v_p ->> 'monto_gyd')::numeric) || ' GYD'
            || CASE WHEN v_o.quoted_destination_amount IS NOT NULL AND v_o.destination_currency IS NOT NULL
                    THEN ' (' || trim_scale(v_o.quoted_destination_amount)::text || ' ' || v_o.destination_currency || ')' ELSE '' END);
        END LOOP;
        v_dep   := (v_res ->> 'depositado')::numeric;
        v_saldo := (v_res ->> 'saldo')::numeric;
        IF v_parcial THEN
          v_text := 'Reparto parcial hecho: ' || array_to_string(v_lista, ', ') || '. Deposito verificado ' || _cerebro_fmt_monto(v_dep)
            || ' GYD; asignado ' || _cerebro_fmt_monto((v_res ->> 'asignado')::numeric) || ' GYD'
            || CASE WHEN (v_res ->> 'sobrante')::numeric > 0
                    THEN ' (sobran ' || _cerebro_fmt_monto((v_res ->> 'sobrante')::numeric) || ' GYD del deposito sin asignar)' ELSE '' END
            || '. ' || CASE WHEN v_pend_txt IS NOT NULL
                            THEN 'Pendiente, con su operacion y sus datos esperando deposito: ' || v_pend_txt || ' (total ' || _cerebro_fmt_monto(v_pend_tot) || ' GYD). '
                                 || 'Cuando el cliente deposite se unira a su operacion.'
                            ELSE 'No quedan partes pendientes.' END;
        ELSE
        v_text := 'Reparto hecho: ' || array_to_string(v_lista, ', ') || '. ' ||
          CASE
            WHEN v_dep > 0 AND v_saldo = 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, todo listo para transferir.'
            WHEN v_dep > 0 AND v_saldo > 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, faltan ' ||
                                                _cerebro_fmt_monto(v_saldo) || ' GYD por depositar para completar.'
            WHEN v_dep > 0 THEN 'Deposito ' || _cerebro_fmt_monto(v_dep) || ' GYD verificado, sobran ' ||
                                _cerebro_fmt_monto(-v_saldo) || ' GYD frente al reparto; un operador debe revisarlo.'
            ELSE 'Todavia no hay deposito verificado: queda pendiente el comprobante de ' || _cerebro_fmt_monto(v_dep + v_saldo) || ' GYD.'
          END;
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (coalesce(nullif(btrim(p_execution), ''), gen_random_uuid()::text) || ':repartir_envio:' || md5(coalesce(p_partes, '')),
          'repartir_envio', p_execution, p_conv, v_op, jsonb_build_array(to_jsonb(p_partes)), v_outcome)
  ON CONFLICT (idempotency_key) DO NOTHING;

  RETURN v_text;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_modificar_operacion(p_conv uuid, p_op uuid, p_accion text, p_valor jsonb DEFAULT NULL::jsonb, p_exec text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_accion     text := lower(btrim(coalesce(p_accion, '')));
  v_actor      text;
  v_prev_origin text;
  v_prev_actor  text;
  v_ids        uuid[];
  v_o          remittance_operations%ROWTYPE;
  v_x          remittance_operations%ROWTYPE;   -- the other operation of a merge
  v_t          remittance_operations%ROWTYPE;   -- survivor of a merge
  v_s          remittance_operations%ROWTYPE;   -- absorbed operation of a merge
  v_rail       text;
  v_res        jsonb;
  v_new        numeric;
  v_old        numeric;
  v_min        numeric;
  v_dep        numeric;
  v_total      numeric;
  v_con        uuid;
  v_lista      text;
  v_campo      text;
  v_after      remittance_operations%ROWTYPE;
  v_b          remittance_beneficiaries%ROWTYPE;
  v_twin       uuid;
  v_block      int;
  v_pos        int;
  v_moved      int := 0;
  v_dups       int := 0;
  v_otras      int;
  v_pl         cerebro_reparto_planeado%ROWTYPE;
  v_outcome    text;
  v_dp         depositos_mmg%ROWTYPE;
  v_dps        text;
  v_ndp        int;
  v_tdep       numeric;
  v_rest       numeric;
  v_hlock      text;
  v_tq         numeric;
  v_tstatus    text;
BEGIN
  v_actor := CASE WHEN btrim(coalesce(p_exec, '')) LIKE 'agent:%' THEN btrim(p_exec)
                  ELSE 'agent:modificar_operacion n8n:' || coalesce(nullif(btrim(p_exec), ''), 'unknown') END;

  IF p_conv IS NULL OR NOT EXISTS (SELECT 1 FROM conversations c WHERE c.id = p_conv) THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'sin_conversacion', 'mensaje', 'No encuentro esa conversacion: no se cambio nada.');
  END IF;
  IF v_accion NOT IN ('monto', 'cancelar', 'unir', 'mover_deposito') THEN
    RETURN jsonb_build_object('ok', false, 'motivo', 'accion_desconocida',
                              'mensaje', 'La accion debe ser monto, cancelar, unir o mover_deposito: no se cambio nada.');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_modificar_operacion:' || p_conv::text, 0));

  <<flow>>
  BEGIN
    -- ---- which operation ----------------------------------------------------------------------------------------------------
    IF p_op IS NOT NULL THEN
      SELECT * INTO v_o FROM remittance_operations WHERE id = p_op AND conversation_id = p_conv FOR UPDATE;
      IF NOT FOUND THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'operacion_no_encontrada',
                                    'mensaje', 'Esa operacion no es de esta conversacion: no se cambio nada.');
        EXIT flow;
      END IF;
    ELSE
      SELECT coalesce(array_agg(o.id ORDER BY o.created_at, o.id), ARRAY[]::uuid[]) INTO v_ids
        FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
      IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'sin_operacion', 'mensaje', 'No hay ninguna operacion abierta que modificar.');
        EXIT flow;
      ELSIF array_length(v_ids, 1) > 1 AND v_accion <> 'unir' THEN
        SELECT string_agg(i::text || ') ' || _cerebro_nombre_servicio(cerebro_riel_op(x.id)) || ' '
                          || coalesce(trim_scale(x.quoted_source_amount)::text, '0') || ' GYD (' || x.id::text || ')', '; ' ORDER BY x.created_at, x.id)
          INTO v_lista FROM unnest(v_ids) WITH ORDINALITY u(id, i) JOIN remittance_operations x ON x.id = u.id;
        v_res := jsonb_build_object('ok', false, 'motivo', 'varias_operaciones',
                  'operaciones', (SELECT jsonb_agg(jsonb_build_object('id', x.id, 'servicio', cerebro_riel_op(x.id), 'monto_gyd', x.quoted_source_amount) ORDER BY x.created_at, x.id)
                                    FROM remittance_operations x WHERE x.id = ANY (v_ids)),
                  'mensaje', 'Hay varias operaciones abiertas: ' || v_lista || '. Preguntale al cliente cual es y vuelve a llamar con su id. No se cambio nada.');
        EXIT flow;
      ELSIF array_length(v_ids, 1) = 1 THEN
        SELECT * INTO v_o FROM remittance_operations WHERE id = v_ids[1] FOR UPDATE;
      END IF;
    END IF;

    -- merge without a named operation: the single pair of open operations that share a rail
    IF v_accion = 'unir' AND v_o.id IS NULL THEN
      SELECT coalesce(array_agg(g.first_id), ARRAY[]::uuid[]) INTO v_ids
        FROM (SELECT (array_agg(o.id ORDER BY o.created_at, o.id))[1] AS first_id
                FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled')
               GROUP BY cerebro_riel_op(o.id) HAVING count(*) = 2) g;
      IF array_length(v_ids, 1) IS DISTINCT FROM 1 THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'no_hay_par', 'mensaje',
                  'No veo un unico par de operaciones abiertas del mismo servicio para unir: indica cual (id) se queda y con cual se une. No se cambio nada.');
        EXIT flow;
      END IF;
      SELECT * INTO v_o FROM remittance_operations WHERE id = v_ids[1] FOR UPDATE;
    END IF;

    v_rail := cerebro_riel_op(v_o.id);
    IF v_o.status IN ('completed', 'cancelled', 'transferring') THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'estado_no_permite', 'estado', v_o.status, 'operation_id', v_o.id,
                'mensaje', 'Esa operacion ya esta ' || CASE v_o.status WHEN 'completed' THEN 'completada' WHEN 'cancelled' THEN 'cancelada'
                                                                         ELSE 'en transferencia' END || ': no se puede modificar desde aqui, un companero lo revisa.');
      EXIT flow;
    END IF;

    v_prev_origin := coalesce(current_setting('wacrm.origin', true), '');
    v_prev_actor  := coalesce(current_setting('wacrm.actor', true), '');

    -- =========================================================== monto
    IF v_accion = 'monto' THEN
      v_new := CASE jsonb_typeof(p_valor)
                 WHEN 'number' THEN (p_valor #>> '{}')::numeric
                 WHEN 'object' THEN nullif(coalesce(p_valor ->> 'monto_gyd', p_valor ->> 'monto'), '')::numeric END;
      IF v_new IS NULL OR v_new <= 0 THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'monto_invalido', 'operation_id', v_o.id,
                  'mensaje', 'Necesito el nuevo monto en GYD, mayor que cero (calculalo antes con calcular_usd). No se cambio nada.');
        EXIT flow;
      END IF;
      v_new := round(v_new);
      v_old := v_o.quoted_source_amount;
      IF v_old IS NOT DISTINCT FROM v_new THEN
        v_res := jsonb_build_object('ok', true, 'cambio', false, 'operation_id', v_o.id, 'monto_gyd', v_new,
                  'mensaje', 'La operacion ya esta en ' || _cerebro_fmt_monto(v_new) || ' GYD: no hay nada que cambiar.');
        v_outcome := 'sin_cambio';
        EXIT flow;
      END IF;
      IF coalesce(v_o.admin_locked_fields, '{}'::jsonb) ? 'quoted_source_amount'
         AND coalesce(v_o.admin_locked_fields -> 'quoted_source_amount' ->> 'by', '') NOT LIKE 'automation:%'
         AND coalesce(v_o.admin_locked_fields -> 'quoted_source_amount' ->> 'by', '') NOT LIKE 'agent:%' THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'bloqueado_por_humano', 'operation_id', v_o.id, 'campo', 'quoted_source_amount',
                  'mensaje', 'Un companero fijo este monto a mano: no lo cambio yo, queda para que lo revise una persona.');
        EXIT flow;
      END IF;
      v_min := cerebro_minimo_gyd(v_o.id);
      IF v_min IS NOT NULL AND v_new < v_min THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'por_debajo_del_minimo', 'operation_id', v_o.id, 'minimo_gyd', v_min, 'monto_gyd', v_new,
                  'mensaje', 'El minimo de ' || _cerebro_nombre_servicio(v_rail) || ' es ' || _cerebro_fmt_monto(v_min) || ' GYD y ese monto ('
                             || _cerebro_fmt_monto(v_new) || ' GYD) no lo alcanza. No se cambio nada.');
        EXIT flow;
      END IF;
      -- coverage: the money verified for this operation (its split group's, when it has one)
      SELECT s.depositado INTO v_dep FROM cerebro_saldo_operacion(v_o.id) s;
      v_total := CASE WHEN v_o.mixed_group_id IS NOT NULL
                      THEN coalesce((SELECT sum(x.quoted_source_amount) FROM remittance_operations x
                                      WHERE x.mixed_group_id = v_o.mixed_group_id AND x.status <> 'cancelled' AND x.id <> v_o.id), 0) + v_new
                      ELSE v_new END;
      IF coalesce(v_dep, 0) > 0 AND v_total > v_dep THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'supera_el_deposito', 'operation_id', v_o.id, 'monto_gyd', v_new,
                  'deposito_verificado_gyd', v_dep, 'faltante_gyd', v_total - v_dep,
                  'mensaje', 'Ese monto (' || _cerebro_fmt_monto(v_total) || ' GYD) supera el deposito verificado (' || _cerebro_fmt_monto(v_dep)
                             || ' GYD): faltarian ' || _cerebro_fmt_monto(v_total - v_dep) || ' GYD. No se cambio nada; el cliente tendria que depositar la diferencia.');
        EXIT flow;
      END IF;

      BEGIN
        PERFORM set_config('wacrm.origin', 'admin', true);
        PERFORM set_config('wacrm.actor', v_actor, true);
        UPDATE remittance_operations
           SET quoted_source_amount = v_new,
               admin_locked_fields = COALESCE(admin_locked_fields, '{}'::jsonb)
                 || jsonb_build_object('quoted_source_amount', jsonb_build_object('by', v_actor, 'at', now()))
         WHERE id = v_o.id;
        -- the destination recalculation writes as a human too: release those locks unless they were there before
        UPDATE remittance_operations
           SET admin_locked_fields = admin_locked_fields
                 - CASE WHEN v_o.admin_locked_fields ? 'quoted_destination_amount' THEN '' ELSE 'quoted_destination_amount' END
                 - CASE WHEN v_o.admin_locked_fields ? 'destination_currency' THEN '' ELSE 'destination_currency' END
         WHERE id = v_o.id AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
      EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        RAISE;
      END;
      SELECT * INTO v_after FROM remittance_operations WHERE id = v_o.id;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
      VALUES (v_after.account_id, 'remittance_operations', v_o.id, 'quoted_source_amount', 'agent_amount_change', v_actor,
              'the customer changed the amount',
              jsonb_build_object('quoted_source_amount', v_old, 'quoted_destination_amount', v_o.quoted_destination_amount),
              jsonb_build_object('quoted_source_amount', v_after.quoted_source_amount, 'quoted_destination_amount', v_after.quoted_destination_amount,
                                 'destination_currency', v_after.destination_currency));
      -- the open send objective of this operation follows the new amount
      UPDATE cerebro_objetivo_envio
         SET monto = v_new, moneda = 'GYD', pedido = _cerebro_fmt_monto(v_new) || ' GYD'
       WHERE conversation_id = p_conv AND cerrado_en IS NULL AND (operation_id = v_o.id OR operation_id IS NULL);
      -- a part of a waiting split plan follows the new amount
      UPDATE cerebro_reparto_planeado pl
         SET partes = (SELECT jsonb_agg(CASE WHEN e ->> 'servicio' = v_rail THEN jsonb_set(e, '{monto_gyd}', to_jsonb(v_new)) ELSE e END ORDER BY ord)
                         FROM jsonb_array_elements(pl.partes) WITH ORDINALITY t(e, ord)),
             total_gyd = (SELECT sum(CASE WHEN e ->> 'servicio' = v_rail THEN v_new ELSE (e ->> 'monto_gyd')::numeric END) FROM jsonb_array_elements(pl.partes) e)
       WHERE pl.conversation_id = p_conv AND EXISTS (SELECT 1 FROM jsonb_array_elements(pl.partes) e WHERE e ->> 'servicio' = v_rail);
      v_outcome := 'monto';
      v_res := jsonb_build_object('ok', true, 'cambio', true, 'operation_id', v_o.id, 'servicio', v_rail,
                'monto_anterior_gyd', v_old, 'monto_gyd', v_after.quoted_source_amount,
                'destino_monto', v_after.quoted_destination_amount, 'destino_moneda', v_after.destination_currency,
                'deposito_verificado_gyd', v_dep,
                'mensaje', 'Listo: la operacion de ' || _cerebro_nombre_servicio(v_rail) || ' paso de ' || coalesce(_cerebro_fmt_monto(v_old), '0')
                           || ' a ' || _cerebro_fmt_monto(v_after.quoted_source_amount) || ' GYD'
                           || CASE WHEN v_after.quoted_destination_amount IS NOT NULL AND v_after.destination_currency IS NOT NULL
                                   THEN ' (el beneficiario recibe ' || trim_scale(v_after.quoted_destination_amount)::text || ' ' || v_after.destination_currency || ')' ELSE '' END
                           || CASE WHEN coalesce(v_dep, 0) > v_total THEN '. Del deposito verificado (' || _cerebro_fmt_monto(v_dep) || ' GYD) sobran '
                                                                           || _cerebro_fmt_monto(v_dep - v_total) || ' GYD: un operador debe revisarlo'
                                   WHEN coalesce(v_dep, 0) > 0 THEN '. El deposito verificado lo cubre'
                                   ELSE '. Todavia no hay deposito verificado' END || '.');
      EXIT flow;
    END IF;

    -- =========================================================== cancelar
    IF v_accion = 'cancelar' THEN
      IF v_o.mixed_group_id IS NOT NULL OR _cerebro_op_tiene_dinero(v_o.id) THEN
        v_res := jsonb_build_object('ok', false, 'motivo', CASE WHEN v_o.mixed_group_id IS NOT NULL THEN 'en_grupo' ELSE 'tiene_dinero' END, 'operation_id', v_o.id,
                  'mensaje', CASE WHEN v_o.mixed_group_id IS NOT NULL
                                  THEN 'Esta operacion forma parte de un reparto con deposito: no la cancelo yo, una persona se encarga.'
                                  ELSE 'Esta operacion ya tiene un deposito o comprobante registrado: no la cancelo yo, una persona la revisa y se encarga del dinero.' END
                             || ' No se cambio nada.');
        EXIT flow;
      END IF;
      UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = v_o.id;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
      VALUES (v_o.account_id, 'remittance_operations', v_o.id, 'status', 'agent_operation_cancel', v_actor,
              'the customer cancelled before any deposit',
              jsonb_build_object('status', v_o.status, 'service', v_rail, 'quoted_source_amount', v_o.quoted_source_amount),
              jsonb_build_object('status', 'cancelled'));
      SELECT count(*) INTO v_otras FROM remittance_operations x WHERE x.conversation_id = p_conv AND x.status NOT IN ('completed', 'cancelled');
      UPDATE cerebro_objetivo_envio SET cerrado_en = now()
       WHERE conversation_id = p_conv AND cerrado_en IS NULL AND (operation_id = v_o.id OR (operation_id IS NULL AND v_otras = 0));
      -- its part leaves a waiting split plan
      SELECT * INTO v_pl FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
      IF FOUND THEN
        IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_pl.partes) e WHERE e ->> 'servicio' <> v_rail) THEN
          DELETE FROM cerebro_reparto_planeado WHERE conversation_id = p_conv;
        ELSE
          UPDATE cerebro_reparto_planeado
             SET partes = (SELECT jsonb_agg(e ORDER BY ord) FROM jsonb_array_elements(v_pl.partes) WITH ORDINALITY t(e, ord) WHERE e ->> 'servicio' <> v_rail),
                 total_gyd = (SELECT sum((e ->> 'monto_gyd')::numeric) FROM jsonb_array_elements(v_pl.partes) e WHERE e ->> 'servicio' <> v_rail)
           WHERE conversation_id = p_conv;
        END IF;
      END IF;
      v_outcome := 'cancelada';
      v_res := jsonb_build_object('ok', true, 'cambio', true, 'operation_id', v_o.id, 'servicio', v_rail, 'operaciones_abiertas', v_otras,
                'mensaje', 'Listo: cancele la operacion de ' || _cerebro_nombre_servicio(v_rail) || ' (no tenia deposito). '
                           || CASE WHEN v_otras = 0 THEN 'No queda ninguna operacion abierta.'
                                   ELSE 'Quedan ' || v_otras || ' operacion(es) abierta(s).' END);
      EXIT flow;
    END IF;

    -- =========================================================== mover_deposito
    -- p_op = the operation that holds the verified deposit; p_valor = {"a": "<target operation uuid>", "deposito": "<MMG trans_id>" (only when it holds several)}.
    -- The deposit moves WHOLE (one depositos_mmg row, with the receipts of that reference): never split, never duplicated.
    IF v_accion = 'mover_deposito' THEN
      v_con := CASE WHEN jsonb_typeof(p_valor) = 'object' THEN nullif(p_valor ->> 'a', '')::uuid END;
      IF v_con IS NULL OR v_con = v_o.id THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'falta_destino', 'operation_id', v_o.id,
                  'mensaje', 'Necesito saber a que otra operacion se mueve el deposito (valor {"a": id de la operacion}). No se cambio nada.');
        EXIT flow;
      END IF;
      SELECT * INTO v_x FROM remittance_operations WHERE id = v_con AND conversation_id = p_conv FOR UPDATE;
      IF NOT FOUND THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'operacion_no_encontrada', 'mensaje', 'La operacion destino no es de esta conversacion: no se cambio nada.');
        EXIT flow;
      END IF;
      IF v_x.status IN ('completed', 'cancelled', 'transferring') THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'estado_no_permite', 'estado', v_x.status, 'operation_id', v_x.id,
                  'mensaje', 'La operacion destino ya no esta abierta para recibir un deposito: no se cambio nada.');
        EXIT flow;
      END IF;
      IF v_o.mixed_group_id IS NOT NULL OR v_x.mixed_group_id IS NOT NULL THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'en_grupo',
                  'mensaje', 'Una de las operaciones forma parte de un reparto: el deposito no se mueve desde aqui, una persona se encarga. No se cambio nada.');
        EXIT flow;
      END IF;
      SELECT k INTO v_hlock FROM (SELECT jsonb_object_keys(coalesce(v_o.admin_locked_fields, '{}'::jsonb)) AS k, v_o.admin_locked_fields AS f
                                   UNION ALL SELECT jsonb_object_keys(coalesce(v_x.admin_locked_fields, '{}'::jsonb)), v_x.admin_locked_fields) l
       WHERE coalesce(l.f -> l.k ->> 'by', '') NOT LIKE 'automation:%' AND coalesce(l.f -> l.k ->> 'by', '') NOT LIKE 'agent:%' LIMIT 1;
      IF v_hlock IS NOT NULL THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'bloqueado_por_humano', 'campo', v_hlock,
                  'mensaje', 'Un companero fijo a mano un dato de una de las dos operaciones: el deposito no se mueve desde aqui, una persona lo revisa. No se cambio nada.');
        EXIT flow;
      END IF;
      -- the deposit: a VERIFIED one of the source (consumed, not voided / discarded)
      SELECT count(*), string_agg(d.trans_id || ' (' || _cerebro_fmt_monto(d.monto) || ' GYD)', ', ' ORDER BY d.trans_id)
        INTO v_ndp, v_dps FROM depositos_mmg d
       WHERE d.operation_id = v_o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL;
      IF v_ndp = 0 THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'sin_deposito_verificado', 'operation_id', v_o.id,
                  'mensaje', 'Esa operacion no tiene un deposito verificado que mover (un comprobante sin cruzar todavia no es dinero): no se cambio nada.');
        EXIT flow;
      END IF;
      IF v_ndp > 1 AND nullif(p_valor ->> 'deposito', '') IS NULL THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'varios_depositos', 'operation_id', v_o.id,
                  'mensaje', 'Esa operacion tiene varios depositos verificados (' || v_dps || '): indica cual se mueve (valor {"a": ..., "deposito": referencia}). No se cambio nada.');
        EXIT flow;
      END IF;
      SELECT * INTO v_dp FROM depositos_mmg d
       WHERE d.operation_id = v_o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL
         AND (v_ndp = 1 OR d.trans_id = p_valor ->> 'deposito') LIMIT 1 FOR UPDATE;
      IF NOT FOUND THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'deposito_no_encontrado', 'mensaje', 'Ese deposito no es de la operacion de origen: no se cambio nada.');
        EXIT flow;
      END IF;
      -- the target after the move: its minimum and its own request
      SELECT coalesce(sum(d.monto), 0) + v_dp.monto INTO v_tdep FROM depositos_mmg d
       WHERE d.operation_id = v_x.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL;
      v_min := cerebro_minimo_gyd(v_x.id);
      v_tq := nullif(v_x.quoted_source_amount, 0);
      IF v_min IS NOT NULL AND v_tdep < v_min THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'por_debajo_del_minimo', 'operation_id', v_x.id, 'minimo_gyd', v_min,
                  'deposito_gyd', v_tdep, 'faltante_gyd', v_min - v_tdep,
                  'mensaje', 'Con ese deposito (' || _cerebro_fmt_monto(v_tdep) || ' GYD) no alcanza el minimo de ' || _cerebro_nombre_servicio(cerebro_riel_op(v_x.id)) || ' ('
                             || _cerebro_fmt_monto(v_min) || ' GYD): faltan ' || _cerebro_fmt_monto(v_min - v_tdep) || ' GYD. No se movio nada.');
        EXIT flow;
      END IF;
      IF v_tq IS NOT NULL AND v_tdep > v_tq THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'deposito_mayor_que_el_envio', 'operation_id', v_x.id, 'deposito_gyd', v_tdep, 'monto_gyd', v_tq,
                  'mensaje', 'El deposito (' || _cerebro_fmt_monto(v_tdep) || ' GYD) es mayor que lo que pide la operacion destino (' || _cerebro_fmt_monto(v_tq)
                             || ' GYD): primero cambia su monto o elige otra. No se movio nada.');
        EXIT flow;
      END IF;

      BEGIN
        PERFORM set_config('wacrm.origin', 'admin', true);
        PERFORM set_config('wacrm.actor', v_actor, true);
        UPDATE depositos_mmg SET operation_id = v_x.id WHERE trans_id = v_dp.trans_id AND operation_id = v_o.id;
        UPDATE remittance_operation_receipts r SET operation_id = v_x.id
         WHERE r.operation_id = v_o.id AND r.reference ~ ('(^|[^0-9])' || regexp_replace(v_dp.trans_id, '[^0-9]', '', 'g') || '([^0-9]|$)')
           AND regexp_replace(v_dp.trans_id, '[^0-9]', '', 'g') <> ''
           AND NOT EXISTS (SELECT 1 FROM remittance_operation_receipts t WHERE t.operation_id = v_x.id AND t.comp_id IS NOT DISTINCT FROM r.comp_id AND r.comp_id IS NOT NULL);
        -- target: takes the deposit as its money; an empty request becomes the deposit
        UPDATE remittance_operations
           SET quoted_source_amount = CASE WHEN v_tq IS NULL THEN v_tdep ELSE quoted_source_amount END,
               status = CASE WHEN v_tdep >= coalesce(v_tq, v_tdep) THEN 'ready_to_transfer' ELSE 'deposit_verification' END,
               incident_reason = NULL, updated_at = now(),
               admin_locked_fields = CASE WHEN v_tq IS NULL THEN COALESCE(admin_locked_fields, '{}'::jsonb)
                                            || jsonb_build_object('quoted_source_amount', jsonb_build_object('by', v_actor, 'at', now())) ELSE admin_locked_fields END
         WHERE id = v_x.id;
        -- source: back to awaiting a deposit when that was its only money
        SELECT coalesce(sum(d.monto), 0) INTO v_rest FROM depositos_mmg d
         WHERE d.operation_id = v_o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.descartado_en IS NULL;
        UPDATE remittance_operations
           SET status = CASE WHEN v_rest = 0 THEN 'awaiting_deposit'
                             WHEN v_rest < coalesce(quoted_source_amount, 0) AND status = 'ready_to_transfer' THEN 'deposit_verification' ELSE status END,
               incident_reason = CASE WHEN v_rest = 0 THEN NULL ELSE incident_reason END, updated_at = now()
         WHERE id = v_o.id;
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
      EXCEPTION WHEN OTHERS THEN
        PERFORM set_config('wacrm.origin', v_prev_origin, true);
        PERFORM set_config('wacrm.actor', v_prev_actor, true);
        RAISE;
      END;
      IF v_tdep >= coalesce(v_tq, v_tdep) THEN PERFORM cerebro_objetivo_cerrar_op(v_x.id); END IF;
      UPDATE cerebro_objetivo_envio SET operation_id = v_x.id WHERE conversation_id = p_conv AND cerrado_en IS NULL AND operation_id = v_o.id;
      SELECT status INTO v_tstatus FROM remittance_operations WHERE id = v_x.id;
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
      VALUES (v_o.account_id, 'remittance_operations', v_o.id, 'deposit', 'agent_deposit_move', v_actor, 'the customer confirmed moving the deposit',
              jsonb_build_object('trans_id', v_dp.trans_id, 'monto', v_dp.monto, 'operation_id', v_o.id, 'status', v_o.status),
              jsonb_build_object('operation_id', v_x.id, 'status', (SELECT status FROM remittance_operations WHERE id = v_o.id))),
             (v_x.account_id, 'remittance_operations', v_x.id, 'deposit', 'agent_deposit_move', v_actor, 'the customer confirmed moving the deposit',
              jsonb_build_object('operation_id', v_o.id, 'status', v_x.status, 'quoted_source_amount', v_x.quoted_source_amount),
              jsonb_build_object('trans_id', v_dp.trans_id, 'monto', v_dp.monto, 'status', v_tstatus, 'deposito_total', v_tdep));
      v_outcome := 'deposito_movido';
      v_res := jsonb_build_object('ok', true, 'cambio', true, 'deposito', v_dp.trans_id, 'monto_gyd', v_dp.monto, 'origen', v_o.id, 'destino', v_x.id,
                'estado_origen', (SELECT status FROM remittance_operations WHERE id = v_o.id), 'estado_destino', v_tstatus,
                'deposito_destino_gyd', v_tdep,
                'mensaje', 'Listo: movi el deposito de ' || _cerebro_fmt_monto(v_dp.monto) || ' GYD de la operacion de ' || _cerebro_nombre_servicio(v_rail)
                           || ' a la de ' || _cerebro_nombre_servicio(cerebro_riel_op(v_x.id)) || '. '
                           || CASE WHEN v_tstatus = 'ready_to_transfer' THEN 'La operacion destino queda con su deposito completo.'
                                   ELSE 'A la operacion destino todavia le faltan ' || _cerebro_fmt_monto(coalesce(v_tq, 0) - v_tdep) || ' GYD por depositar.' END
                           || CASE WHEN v_rest = 0 THEN ' La operacion de origen queda esperando su deposito.' ELSE '' END);
      EXIT flow;
    END IF;

    -- =========================================================== unir
    v_con := CASE WHEN jsonb_typeof(p_valor) = 'object' THEN nullif(p_valor ->> 'con', '')::uuid END;
    IF v_con IS NULL THEN
      SELECT coalesce(array_agg(x.id ORDER BY x.created_at, x.id), ARRAY[]::uuid[]) INTO v_ids
        FROM remittance_operations x
       WHERE x.conversation_id = p_conv AND x.id <> v_o.id AND x.status NOT IN ('completed', 'cancelled') AND cerebro_riel_op(x.id) IS NOT DISTINCT FROM v_rail;
      IF array_length(v_ids, 1) IS DISTINCT FROM 1 THEN
        v_res := jsonb_build_object('ok', false, 'motivo', 'no_hay_par', 'operation_id', v_o.id,
                  'mensaje', 'No veo exactamente otra operacion abierta de ' || _cerebro_nombre_servicio(v_rail) || ' para unir: indica con cual (id). No se cambio nada.');
        EXIT flow;
      END IF;
      v_con := v_ids[1];
    END IF;
    SELECT * INTO v_x FROM remittance_operations WHERE id = v_con AND conversation_id = p_conv FOR UPDATE;
    IF NOT FOUND OR v_x.id = v_o.id THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'operacion_no_encontrada', 'mensaje', 'La otra operacion no es de esta conversacion: no se cambio nada.');
      EXIT flow;
    END IF;
    IF v_x.status IN ('completed', 'cancelled', 'transferring') THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'estado_no_permite', 'estado', v_x.status, 'operation_id', v_x.id,
                'mensaje', 'La otra operacion ya no esta abierta para unirla: no se cambio nada.');
      EXIT flow;
    END IF;
    IF cerebro_riel_op(v_x.id) IS DISTINCT FROM v_rail OR v_x.service_type IS DISTINCT FROM v_o.service_type THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'servicios_distintos', 'mensaje',
                'Solo se unen operaciones del mismo servicio; estas son ' || _cerebro_nombre_servicio(v_rail) || ' y ' || _cerebro_nombre_servicio(cerebro_riel_op(v_x.id)) || '. No se cambio nada.');
      EXIT flow;
    END IF;
    IF v_o.mixed_group_id IS NOT NULL OR v_x.mixed_group_id IS NOT NULL THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'en_grupo',
                'mensaje', 'Una de las operaciones forma parte de un reparto: no las uno yo, una persona se encarga. No se cambio nada.');
      EXIT flow;
    END IF;
    IF _cerebro_op_tiene_dinero(v_o.id) AND _cerebro_op_tiene_dinero(v_x.id) THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'dinero_en_ambas',
                'mensaje', 'Las dos operaciones ya tienen deposito: unirlas mueve dinero y eso lo hace una persona. No se cambio nada.');
      EXIT flow;
    END IF;
    -- the one that holds money survives; otherwise the one named (p_op)
    IF _cerebro_op_tiene_dinero(v_x.id) THEN v_t := v_x; v_s := v_o; ELSE v_t := v_o; v_s := v_x; END IF;
    SELECT k INTO v_campo FROM unnest(ARRAY['beneficiaries', 'quoted_source_amount']) k
     WHERE ((coalesce(v_t.admin_locked_fields, '{}'::jsonb) ? k AND coalesce(v_t.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%' AND coalesce(v_t.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'agent:%')
         OR (coalesce(v_s.admin_locked_fields, '{}'::jsonb) ? k AND coalesce(v_s.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'automation:%' AND coalesce(v_s.admin_locked_fields -> k ->> 'by', '') NOT LIKE 'agent:%'))
     LIMIT 1;
    IF v_campo IS NOT NULL THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'bloqueado_por_humano', 'campo', v_campo,
                'mensaje', 'Un companero fijo ' || CASE v_campo WHEN 'beneficiaries' THEN 'los destinatarios' ELSE 'el monto' END
                           || ' de una de las operaciones: no las uno yo. No se cambio nada.');
      EXIT flow;
    END IF;
    v_new := coalesce(v_t.quoted_source_amount, 0) + coalesce(v_s.quoted_source_amount, 0);
    SELECT s.depositado INTO v_dep FROM cerebro_saldo_operacion(v_t.id) s;
    IF coalesce(v_dep, 0) > 0 AND v_new > v_dep THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'supera_el_deposito', 'deposito_verificado_gyd', v_dep, 'faltante_gyd', v_new - v_dep,
                'mensaje', 'Unidas sumarian ' || _cerebro_fmt_monto(v_new) || ' GYD y el deposito verificado es ' || _cerebro_fmt_monto(v_dep)
                           || ' GYD (faltarian ' || _cerebro_fmt_monto(v_new - v_dep) || ' GYD). No se cambio nada.');
      EXIT flow;
    END IF;
    v_min := cerebro_minimo_gyd(v_t.id);
    IF v_new > 0 AND v_min IS NOT NULL AND v_new < v_min THEN
      v_res := jsonb_build_object('ok', false, 'motivo', 'por_debajo_del_minimo', 'minimo_gyd', v_min,
                'mensaje', 'Unidas sumarian ' || _cerebro_fmt_monto(v_new) || ' GYD y el minimo de ' || _cerebro_nombre_servicio(v_rail) || ' es '
                           || _cerebro_fmt_monto(v_min) || ' GYD. No se cambio nada.');
      EXIT flow;
    END IF;

    -- recipients of the absorbed operation join the survivor (a twin by phone / card / account is retired, not duplicated)
    FOR v_b IN SELECT * FROM remittance_beneficiaries b WHERE b.operation_id = v_s.id AND b.status = 'vigente' ORDER BY b.position, b.id LOOP
      v_twin := NULL;
      SELECT t.id INTO v_twin FROM remittance_beneficiaries t
       WHERE t.operation_id = v_t.id AND t.status = 'vigente'
         AND ((nullif(btrim(coalesce(v_b.phone, '')), '') IS NOT NULL AND t.phone = v_b.phone)
           OR (nullif(btrim(coalesce(v_b.card_number, '')), '') IS NOT NULL AND t.card_number = v_b.card_number)
           OR (nullif(btrim(coalesce(v_b.zelle_account, '')), '') IS NOT NULL AND t.zelle_account = v_b.zelle_account))
       LIMIT 1;
      IF v_twin IS NOT NULL THEN
        UPDATE remittance_beneficiaries SET status = 'reemplazado', replaced_at = now() WHERE id = v_b.id;
        v_dups := v_dups + 1;
      ELSE
        SELECT coalesce(max(x.block_index), 0) + 1 INTO v_block FROM remittance_beneficiaries x WHERE x.operation_id = v_t.id;
        SELECT coalesce(max(x.position), 0) + 1 INTO v_pos FROM remittance_beneficiaries x WHERE x.operation_id = v_t.id AND x.status = 'vigente';
        UPDATE remittance_beneficiaries SET operation_id = v_t.id, block_index = v_block, position = v_pos WHERE id = v_b.id;
        v_moved := v_moved + 1;
      END IF;
    END LOOP;

    BEGIN
      PERFORM set_config('wacrm.origin', 'admin', true);
      PERFORM set_config('wacrm.actor', v_actor, true);
      UPDATE remittance_operations
         SET quoted_source_amount = CASE WHEN v_new > 0 THEN v_new ELSE quoted_source_amount END,
             admin_locked_fields = CASE WHEN v_new > 0 AND coalesce(v_s.quoted_source_amount, 0) > 0
                                        THEN COALESCE(admin_locked_fields, '{}'::jsonb) || jsonb_build_object('quoted_source_amount', jsonb_build_object('by', v_actor, 'at', now()))
                                        ELSE admin_locked_fields END
       WHERE id = v_t.id;
      UPDATE remittance_operations
         SET admin_locked_fields = admin_locked_fields
               - CASE WHEN v_t.admin_locked_fields ? 'quoted_destination_amount' THEN '' ELSE 'quoted_destination_amount' END
               - CASE WHEN v_t.admin_locked_fields ? 'destination_currency' THEN '' ELSE 'destination_currency' END
       WHERE id = v_t.id AND admin_locked_fields ?| ARRAY['quoted_destination_amount', 'destination_currency'];
      UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = v_s.id;
      PERFORM set_config('wacrm.origin', v_prev_origin, true);
      PERFORM set_config('wacrm.actor', v_prev_actor, true);
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('wacrm.origin', v_prev_origin, true);
      PERFORM set_config('wacrm.actor', v_prev_actor, true);
      RAISE;
    END;
    -- the objective that followed the absorbed operation now follows the survivor
    UPDATE cerebro_objetivo_envio SET operation_id = v_t.id WHERE conversation_id = p_conv AND cerrado_en IS NULL AND operation_id = v_s.id;
    SELECT * INTO v_after FROM remittance_operations WHERE id = v_t.id;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_t.account_id, 'remittance_operations', v_t.id, 'merge', 'agent_operation_merge', v_actor, 'two open operations of the same service joined',
            jsonb_build_object('absorbed', v_s.id, 'survivor_amount', v_t.quoted_source_amount, 'absorbed_amount', v_s.quoted_source_amount),
            jsonb_build_object('survivor', v_t.id, 'quoted_source_amount', v_after.quoted_source_amount, 'moved_recipients', v_moved, 'retired_duplicates', v_dups));
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_s.account_id, 'remittance_operations', v_s.id, 'status', 'agent_operation_merge', v_actor, 'absorbed into ' || v_t.id::text,
            jsonb_build_object('status', v_s.status), jsonb_build_object('status', 'cancelled', 'survivor', v_t.id));
    v_outcome := 'unida';
    v_res := jsonb_build_object('ok', true, 'cambio', true, 'operation_id', v_t.id, 'absorbida', v_s.id, 'servicio', v_rail,
              'monto_gyd', v_after.quoted_source_amount, 'destinatarios_movidos', v_moved, 'duplicados_retirados', v_dups,
              'mensaje', 'Listo: uni las dos operaciones de ' || _cerebro_nombre_servicio(v_rail) || ' en una'
                         || CASE WHEN v_after.quoted_source_amount > 0 THEN ' de ' || _cerebro_fmt_monto(v_after.quoted_source_amount) || ' GYD' ELSE '' END
                         || ' (' || v_moved || ' destinatario(s) pasados'
                         || CASE WHEN v_dups > 0 THEN ', ' || v_dups || ' repetido(s) retirado(s)' ELSE '' END || ').');
  END;

  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (coalesce(nullif(btrim(p_exec), ''), gen_random_uuid()::text) || ':modificar_operacion:' || md5(v_accion || coalesce(p_valor::text, '') || coalesce(p_op::text, '')),
          'modificar_operacion', p_exec, p_conv, coalesce(v_o.id, p_op), jsonb_build_array(to_jsonb(v_accion), coalesce(p_valor, 'null'::jsonb)),
          CASE WHEN (v_res ->> 'ok')::boolean THEN coalesce(v_outcome, 'ok') ELSE v_res ->> 'motivo' END)
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN v_res;
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('wacrm.origin', coalesce(current_setting('wacrm.origin', true), ''), true);
  RETURN jsonb_build_object('ok', false, 'motivo', 'error', 'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200),
                            'mensaje', 'No pude hacer el cambio por un problema interno: no se cambio nada. Un companero lo revisa.');
END $function$;

DROP FUNCTION IF EXISTS public._cerebro_aplicar_servicio_base(uuid, text, text, text, text);
DROP FUNCTION IF EXISTS public._cerebro_fijar_monto_acordado(uuid, numeric, text, boolean);
DROP FUNCTION IF EXISTS public._cerebro_monto_acordado_previo(uuid);
DROP FUNCTION IF EXISTS public._cerebro_op_monto_acordado(uuid);
REVOKE ALL ON FUNCTION public._cerebro_declarar_implicito(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_declarar_servicio(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.cerebro_aplicar_servicio(uuid, text, text, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_aplicar_servicio(uuid, text, text, text, text) TO service_role;
