-- ROLLBACK 286: back to the 283 bodies.
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
BEGIN
  -- The callers have validated the service and the operation; they hold its row lock (taken again here, same transaction).
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

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

  -- 1. The operation: new service, quote cleared, rail locked against the bot. The 096 guard locks the changed
  --    destination fields for a human writer; they are released right after (2).
  UPDATE remittance_operations
     SET service_type = v_new_type,
         delivery_method = v_new_dm,
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
    'retired_recipients', to_jsonb(v_retired), 'retyped_recipients', to_jsonb(v_retyped));

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_op.account_id, 'remittance_operations', p_operation_id, 'service', p_audit_action,
          p_actor, p_reason, v_before, v_after);

  RETURN jsonb_build_object('operation_id', p_operation_id, 'service', v_servicio, 'changed', true,
                            'retired', to_jsonb(v_retired), 'retyped', to_jsonb(v_retyped));
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
