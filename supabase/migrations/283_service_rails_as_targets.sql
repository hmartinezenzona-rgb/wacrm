-- 283: cambiar_servicio absorbs what marcar_destino_usd did; every rail is a service target through cerebro_aplicar_servicio.
--
-- The agent's tool cambiar_servicio -> cerebro_aplicar_servicio -> cerebro_resolver_servicio already treats clasica / tropical / efectivo_usd / cuban_card
-- as targets. What marcar_destino_usd still did better, and now lives there:
--   * _cerebro_servicio_clave(text): the customer's words (cup, pesos, tarjeta cup, efectivo, Efectivo USD, CLASICA, Tropical...) become the keys; used by
--     cerebro_declarar_servicio, cerebro_aplicar_servicio and cerebro_resolver_servicio (unknown words still answer servicio_invalido).
--   * Before any money exists a change TO A RAIL is allowed (it used to answer deposito_bajo_minimo "faltan 13,000" for an empty operation): the minimum is
--     checked when the deposit arrives. With a deposit the rules are unchanged.
--   * Several open operations and no deposit: the request is applied to the operation of its service. One already of that service = sin_cambio; else the
--     single plain remesa is converted (a Mexico / recarga / combo / visa / balance operation is never re-typed by another service's request and
--     nothing else is cancelled); two remesas stay varias_operaciones. A waiting split plan follows the converted operation's new service.
--   * crm_registrar_numeros_recarga only asks the resolver to convert an operation into the recharge when money is registered (as before).
-- cerebro_marcar_destino_usd keeps working unchanged and is documented as DEPRECATED (COMMENT); the agent should call cambiar_servicio.
-- Rollback: ROLLBACK-283-service-rails-as-targets.sql.

CREATE OR REPLACE FUNCTION public._cerebro_servicio_clave(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $f$
  -- The service names the agent may pass, in the words customers and operators use, to the keys the database knows.
  -- Unknown words come back cleaned (lower case, trimmed) so the callers keep answering servicio_invalido for them.
  WITH t AS (SELECT btrim(regexp_replace(lower(translate(coalesce(p_texto, ''), 'ÁÉÍÓÚÑÜáéíóúñü', 'AEIOUNUaeiounu')), '\s+', ' ', 'g')) AS v)
  SELECT CASE
    WHEN v IN ('cup', 'cuban_card', 'pesos', 'pesos cubanos', 'tarjeta', 'tarjeta cup', 'tarjeta en cup', 'tarjeta en pesos', 'tarjeta en pesos cubanos') THEN 'cuban_card'
    WHEN v IN ('efectivo', 'efectivo usd', 'efectivo_usd', 'cash', 'entrega en efectivo') THEN 'efectivo_usd'
    WHEN v LIKE 'clasica%' THEN 'clasica'
    WHEN v LIKE 'tropical%' THEN 'tropical'
    WHEN v IN ('zelle') THEN 'zelle'
    WHEN v IN ('recarga', 'recargas', 'saldo de recarga') THEN 'recarga'
    WHEN v IN ('saldo', 'saldo movil') THEN 'saldo'
    WHEN v IN ('combo', 'combos') THEN 'combo'
    WHEN v IN ('visa', 'extension de visa', 'extension visa') THEN 'visa'
    WHEN v IN ('mexico', 'envio a mexico') THEN 'mexico'
    ELSE v END
    FROM t;
$f$;
REVOKE ALL ON FUNCTION public._cerebro_servicio_clave(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cerebro_servicio_clave(text) TO service_role;

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
  RETURN v_r || jsonb_build_object('aplicado', true, 'cambios', v_cambios);
EXCEPTION WHEN OTHERS THEN
  -- Never raise into the bot (the lock or the resolver call itself failed).
  RETURN coalesce(v_r, v_safe) || jsonb_build_object('aplicado', false, 'cambios', '{}'::jsonb,
                                                     'sqlstate', SQLSTATE, 'detalle', left(SQLERRM, 200),
                                                       'mensaje', 'No se pudo aplicar el cambio de servicio por un error interno: no se cambió nada.');
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

COMMENT ON FUNCTION public.cerebro_marcar_destino_usd(uuid, text, text) IS 'DEPRECATED (283): use cambiar_servicio (cerebro_aplicar_servicio); it targets the operation of the service, understands cup / efectivo and works before any deposit. Kept for compatibility.';
