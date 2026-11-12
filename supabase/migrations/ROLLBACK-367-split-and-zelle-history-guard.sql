-- ROLLBACK for 367: restores the exact bodies that production ran before it (read from production 2026-11-12).

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
            OR (coalesce(o.quoted_source_amount, 0) > 0 AND NOT _cerebro_op_monto_acordado(o.id)))
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
            -- the holder keeps no money: its request amount goes with the money (293: it gets back the amount agreed for it, if any)
            PERFORM set_config('wacrm.origin', 'admin', true);
            PERFORM set_config('wacrm.actor', c_actor, true);
            UPDATE remittance_operations SET quoted_source_amount = coalesce(_cerebro_monto_acordado_previo(v_op), 0), updated_at = now() WHERE id = v_op AND NOT _cerebro_op_tiene_dinero(v_op);
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
