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
  v_guardia text;
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

  -- (360) Nothing open and nothing declared: a send completed within the window is not reopened by a recipient write.
  IF v_r.o_op IS NULL THEN
    v_guardia := cerebro_guardia_envio_nuevo(p_conv, ARRAY[]::text[], ARRAY[]::text[], ARRAY[v_a]);
    IF v_guardia IS NOT NULL THEN
      RETURN QUERY SELECT NULL::uuid, v_guardia; RETURN;
    END IF;
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
    || CASE WHEN v_legacy_replace THEN ' (Reemplazo al destinatario anterior; si es OTRA persona, no una correccion, vuelve a llamar con agregar=true.)' ELSE '' END || v_aviso
    || CASE WHEN _cerebro_envio_abierto_ahora(v_deal) THEN ' SE ABRIO UN ENVIO NUEVO para estos datos, a la espera de su deposito (queda auditado).' ELSE '' END)::text;
END $function$;
;
