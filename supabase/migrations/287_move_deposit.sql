-- 287: cerebro_modificar_operacion gains p_accion 'mover_deposito' (owner decision 2026-10-23, Engram cerebro/bot-moves-deposit): the bot may move a
-- VERIFIED deposit from one operation to another of the same conversation when the customer confirms it. No new function.
--
--   cerebro_modificar_operacion(p_conv, p_op = the operation that holds the deposit, 'mover_deposito', p_valor = {"a": "<target operation>", "deposito": "<MMG ref>"}, p_exec)
--   Rules: same conversation; source and target open (not transferring / completed / cancelled); neither in a split group; no lock a person left on either
--   (any field); the source must hold a VERIFIED deposit (a receipt not crossed yet is not money); with several deposits the reference says which; the deposit moves
--   WHOLE (one depositos_mmg row and the receipts of its reference), never split, never duplicated; the target, with that deposit, must reach its service minimum
--   (else `faltante_gyd`, nothing moved) and may not exceed what it asks (else change its amount first). The target takes the deposit (an empty request becomes the
--   deposit) and is ready_to_transfer when covered, deposit_verification when not; the source goes back to awaiting_deposit when that was its only money. The open
--   objective that followed the source follows the target. Audit action agent_deposit_move on both operations (real actor); plain-Spanish `mensaje`.
-- Rollback: ROLLBACK-287-move-deposit.sql.

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
  'agent_beneficiary_corrected'::text,
  'agent_deposit_move'::text]));

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
