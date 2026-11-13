-- 371 -- Two services declared in one turn become a planned split; when in doubt, the bot is told to ask.
--
-- Owner test 2026-11-13 (conversation 2ca2cf79, exec 727547): one message "2 recargas a <2 numbers> y tambien un zelle de 50 USD" (no Zelle account yet).
-- registrar_numeros_recarga opened the recarga (agreed 12,400) and calcular_usd quoted the Zelle (13,000 GYD), but repartir_envio was not called: the
-- Zelle the customer asked for was recorded nowhere and the panel showed one loose recarga. The reply text said total 25,400.
--
-- The split must not depend on the model remembering a tool. The n8n node "Verificar coherencia servicio" already runs after the agent on EVERY agent turn
-- with ($conversation_id, $execution.id) and never stops the turn (onError continue), so the check lives behind it and no n8n change is needed:
-- cerebro_verificar_coherencia_servicio now calls _cerebro_declaracion_doble first, inside a block that swallows any error.
--
-- _cerebro_declaracion_doble(conv, exec), all of these must hold or it does nothing:
--   * the execution is registered (cerebro_ejecuciones, turn start T0), no split plan exists, no operation is in a mixed group, and the send was not completed
--     with that very money inside the completed-send window (same guard as cerebro_repartir_envio, 367);
--   * the turn quoted exactly ONE service Y in {zelle, clasica, tropical} (tool_execution_log rows of the quote tools with their via; a via-less calcular_usd
--     leaves no row, so the turn's USD quote counts as Zelle), with an explicit GYD amount at or above Y's minimum. Two different services = comparison: nothing;
--   * exactly ONE open operation of service X in {recarga, saldo, combo, visa}: collecting/awaiting, ungrouped, no money, holding an AGREED amount (293)
--     written after the bot's last message before the turn (so it was asked in this turn, not before). At most one other open operation, and only an empty
--     one of Y's rail (opened earlier in the turn by a recipient writer; the plan reuses it);
--   * the customer's text of the turn (messages since the bot's last reply) names Y's service and carries no price-question marker.
-- Then it plans [X agreed amount, Y quoted amount] with _cerebro_reparto_planear (one empty operation per part with its agreed amount, no mixed_group_id,
-- no money: 369), sets the send objective to the plan total (calcular_usd had left only Y's amount) and logs one tool_execution_log row 'declaracion_doble'
-- per execution (idempotent). Customer words are only a requirement and a veto: they never open a service on their own (268).
--
-- When the tool evidence matches but the text guard fails (price-question marker, Y not named, no text) NOTHING is created: the doubt is kept in
-- cerebro_declaracion_duda (one row per conversation) and cerebro_declaracion_pendiente(conv) exposes it while it still holds (inside the quote window,
-- no plan, X still open and empty, no operation of Y, nothing closed since) so the next turn can ask the customer whether he also wants Y.
--
-- Minimums of Y are those of cerebro_minimo_gyd (zelle 50 USD, clasica/tropical 20 USD at the live rate). Rollback: ROLLBACK-371-declaracion-doble.sql.
-- Guarded by supabase/staging/assertions/declaracion-doble.sql. cerebro_verificar_coherencia_servicio is redefined from its live production body
-- (read 2026-11-13, md5 5b849da27e0478a0626e0df56331c397, equal to staging) adding only the block after the advisory lock.

CREATE TABLE IF NOT EXISTS public.cerebro_declaracion_duda (
  conversation_id  uuid PRIMARY KEY REFERENCES public.conversations(id) ON DELETE CASCADE,
  servicio         text NOT NULL,
  monto_gyd        numeric NOT NULL,
  servicio_actual  text NOT NULL,
  monto_actual_gyd numeric NOT NULL,
  motivo           text NOT NULL,
  ejecucion        text,
  creado_at        timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.cerebro_declaracion_duda ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cerebro_declaracion_duda FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public._cerebro_declaracion_doble(p_conv uuid, p_exec text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  -- a price question: a question mark, or the words customers use to ask a price
  c_marca constant text := '[?¿]|\mcu[aá]nt[oa]s?|\mprecio|\msalen?\M|\mcuest[ao]|\mtasa\M|\mcotiz|\mcu[aá]l es\M|\mcosto';
  v_exec    text := nullif(btrim(coalesce(p_exec, '')), '');
  v_key     text;
  v_t0      timestamptz;
  v_w0      timestamptz;
  v_ys      text[];
  v_y       text;
  v_gy      numeric;
  v_min     numeric;
  v_palabra text;
  v_txt     text;
  v_motivo  text;
  v_x       remittance_operations%ROWTYPE;
  v_nx      int;
  v_otras   int;
  v_plan    jsonb;
  v_sum     numeric;
BEGIN
  IF p_conv IS NULL OR v_exec IS NULL THEN RETURN jsonb_build_object('hecho', false, 'motivo', 'sin_ejecucion'); END IF;
  v_key := v_exec || ':declaracion_doble';
  IF EXISTS (SELECT 1 FROM tool_execution_log l WHERE l.idempotency_key = v_key) THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'ya_hecho');
  END IF;
  SELECT e.created_at INTO v_t0 FROM cerebro_ejecuciones e WHERE e.execution_id = v_exec AND e.conversation_id = p_conv;
  IF v_t0 IS NULL THEN RETURN jsonb_build_object('hecho', false, 'motivo', 'sin_turno'); END IF;

  -- a plan waiting or a send already grouped: this is not the first declaration
  IF EXISTS (SELECT 1 FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv)
     OR EXISTS (SELECT 1 FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled') AND o.mixed_group_id IS NOT NULL) THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'ya_hay_reparto');
  END IF;

  -- the services quoted in THIS execution (cerebro_registrar_via_cotizada leaves one row per quote with its via)
  SELECT coalesce(array_agg(DISTINCT l.outcome), ARRAY[]::text[]) INTO v_ys
    FROM tool_execution_log l
   WHERE l.execution_id = v_exec AND l.conversation_id = p_conv AND l.outcome IS NOT NULL
     AND l.tool_name IN ('calcular_usd', 'calcular_usd_desde_gyd', 'calcular_envio', 'calcular_inverso');
  IF cardinality(v_ys) = 0 THEN
    -- a calcular_usd without via is priced as Zelle and leaves no row: the turn's USD quote stands for it
    SELECT q.origen_gyd INTO v_gy FROM cerebro_ultima_cotizacion q
     WHERE q.conversation_id = p_conv AND q.destino_moneda = 'USD' AND q.herramienta IN ('calcular_usd', 'calcular_usd_desde_gyd') AND q.cotizado_en >= v_t0;
    IF v_gy IS NOT NULL THEN v_ys := ARRAY['zelle']; END IF;
  ELSIF cardinality(v_ys) = 1 THEN
    SELECT CASE WHEN l.arguments ->> 0 ~ '^[0-9]+(\.[0-9]+)?$' THEN (l.arguments ->> 0)::numeric END INTO v_gy
      FROM tool_execution_log l
     WHERE l.execution_id = v_exec AND l.conversation_id = p_conv AND l.outcome = v_ys[1]
       AND l.tool_name IN ('calcular_usd', 'calcular_usd_desde_gyd', 'calcular_envio', 'calcular_inverso')
     ORDER BY l.created_at DESC, l.id DESC LIMIT 1;
  END IF;
  IF cardinality(v_ys) <> 1 OR v_ys[1] NOT IN ('zelle', 'clasica', 'tropical') THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'sin_servicio_cotizado_unico');
  END IF;
  v_y := v_ys[1];
  IF coalesce(v_gy, 0) <= 0 THEN RETURN jsonb_build_object('hecho', false, 'motivo', 'sin_monto'); END IF;
  v_min := CASE v_y
    WHEN 'zelle' THEN COALESCE(COALESCE(NULLIF(cerebro_config_get('minimo_usd_zelle'), '')::numeric, 50) * crm_tasa_vigente('usd'),
                               NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric, NULLIF(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
    WHEN 'clasica' THEN COALESCE(COALESCE(NULLIF(cerebro_config_get('minimo_usd_clasica'), '')::numeric, 20) * crm_tasa_vigente('usd'),
                                 NULLIF(cerebro_config_get('minimo_gyd_clasica'), '')::numeric, NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric, 13000)
    WHEN 'tropical' THEN COALESCE(COALESCE(NULLIF(cerebro_config_get('minimo_usd_tropical'), '')::numeric, 20) * crm_tasa_vigente('usd'),
                                  NULLIF(cerebro_config_get('minimo_gyd_tropical'), '')::numeric, NULLIF(cerebro_config_get('minimo_gyd_usd'), '')::numeric, 13000)
  END;
  IF v_gy < v_min THEN RETURN jsonb_build_object('hecho', false, 'motivo', 'bajo_minimo'); END IF;

  -- the open operations: exactly one of service X, at most one other and that one an empty operation of Y's rail
  SELECT count(*) FILTER (WHERE o.service_type IN ('recarga', 'saldo', 'combo', 'visa')),
         count(*) FILTER (WHERE o.service_type NOT IN ('recarga', 'saldo', 'combo', 'visa'))
    INTO v_nx, v_otras
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
  IF v_nx <> 1 OR v_otras > 1 THEN RETURN jsonb_build_object('hecho', false, 'motivo', 'operaciones_no_encajan'); END IF;
  SELECT o.* INTO v_x FROM remittance_operations o
   WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled') AND o.service_type IN ('recarga', 'saldo', 'combo', 'visa');
  IF v_x.status NOT IN ('collecting_information', 'awaiting_deposit') OR v_x.mixed_group_id IS NOT NULL
     OR _cerebro_op_tiene_dinero(v_x.id) OR NOT _cerebro_op_monto_acordado(v_x.id) THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'servicio_actual_no_encaja');
  END IF;
  IF v_otras = 1 AND NOT EXISTS (
       SELECT 1 FROM remittance_operations o
        WHERE o.conversation_id = p_conv AND o.status IN ('collecting_information', 'awaiting_deposit') AND o.service_type = 'remesa'
          AND o.mixed_group_id IS NULL AND NOT _cerebro_op_tiene_dinero(o.id) AND cerebro_riel_op(o.id) = v_y
          AND (coalesce(o.quoted_source_amount, 0) = 0 OR _cerebro_op_monto_acordado(o.id))) THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'otra_operacion_no_encaja');
  END IF;

  -- the turn: what the customer wrote since the bot's last message before the execution started (at most 15 minutes back)
  SELECT greatest(coalesce(max(m.created_at), v_t0 - interval '15 minutes'), v_t0 - interval '15 minutes') INTO v_w0
    FROM messages m WHERE m.conversation_id = p_conv AND m.sender_type = 'agent' AND m.created_at < v_t0;
  -- X must have been agreed IN this turn, not before it
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit a
                  WHERE a.row_id = v_x.id AND a.table_name = 'remittance_operations' AND a.action = 'agent_amount_change'
                    AND a.after ->> 'agreed' = 'true' AND a.created_at >= v_w0) THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'servicio_actual_de_otro_turno');
  END IF;

  -- (367) a send completed with this very money inside the window: plan nothing, the case goes to a person elsewhere
  IF _cerebro_completada_reciente(p_conv) IS NOT NULL THEN
    v_sum := v_x.quoted_source_amount + v_gy;
    IF EXISTS (SELECT 1 FROM remittance_operations o
                WHERE o.conversation_id = p_conv AND o.status = 'completed'
                  AND coalesce(o.completed_at, o.status_changed_at, o.updated_at)
                      > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('envio_completado_ventana_horas'), '')::int, 6))
                  AND (SELECT coalesce(sum(d.monto), 0) FROM depositos_mmg d
                        WHERE d.operation_id = o.id AND d.consumido_en IS NOT NULL AND d.anulado_en IS NULL AND d.moneda = 'GYD') >= v_sum) THEN
      RETURN jsonb_build_object('hecho', false, 'motivo', 'deposito_ya_aplicado');
    END IF;
  END IF;

  -- the customer's words: they must name Y and ask no price. Anything else is doubt: nothing is created, the next turn asks.
  SELECT string_agg(lower(m.content_text), ' ' ORDER BY m.created_at) INTO v_txt
    FROM messages m WHERE m.conversation_id = p_conv AND m.sender_type = 'customer' AND m.created_at > v_w0 AND nullif(btrim(coalesce(m.content_text, '')), '') IS NOT NULL;
  v_palabra := CASE v_y WHEN 'zelle' THEN 'zelle' WHEN 'clasica' THEN 'cl[aá]sica' WHEN 'tropical' THEN 'tropical' END;
  v_motivo := CASE WHEN nullif(btrim(coalesce(v_txt, '')), '') IS NULL THEN 'sin_texto'
                   WHEN v_txt !~ v_palabra THEN 'y_sin_nombrar'
                   WHEN v_txt ~ c_marca THEN 'pregunta' END;
  IF v_motivo IS NOT NULL THEN
    INSERT INTO cerebro_declaracion_duda (conversation_id, servicio, monto_gyd, servicio_actual, monto_actual_gyd, motivo, ejecucion, creado_at)
    VALUES (p_conv, v_y, v_gy, v_x.service_type, v_x.quoted_source_amount, v_motivo, v_exec, now())
    ON CONFLICT (conversation_id) DO UPDATE
       SET servicio = EXCLUDED.servicio, monto_gyd = EXCLUDED.monto_gyd, servicio_actual = EXCLUDED.servicio_actual,
           monto_actual_gyd = EXCLUDED.monto_actual_gyd, motivo = EXCLUDED.motivo, ejecucion = EXCLUDED.ejecucion, creado_at = now();
    INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
    VALUES (v_key, 'declaracion_doble', v_exec, p_conv, v_x.id, jsonb_build_array(v_x.service_type, v_x.quoted_source_amount, v_y, v_gy), 'duda:' || v_motivo)
    ON CONFLICT (idempotency_key) DO NOTHING;
    RETURN jsonb_build_object('hecho', false, 'motivo', 'duda', 'detalle', v_motivo);
  END IF;

  v_plan := _cerebro_reparto_planear(p_conv,
              jsonb_build_array(jsonb_build_object('servicio', v_x.service_type, 'monto_gyd', trim_scale(v_x.quoted_source_amount)),
                                jsonb_build_object('servicio', v_y, 'monto_gyd', trim_scale(v_gy))),
              true, 'automation:declaracion_doble');
  IF NOT coalesce((v_plan ->> 'ok')::boolean, false) THEN
    RETURN jsonb_build_object('hecho', false, 'motivo', 'plan_rechazado');
  END IF;
  -- calcular_usd left the objective at Y's amount only: the send is now both parts
  PERFORM cerebro_fijar_objetivo(p_conv, v_x.quoted_source_amount + v_gy, 'GYD');
  DELETE FROM cerebro_declaracion_duda WHERE conversation_id = p_conv;
  INSERT INTO tool_execution_log (idempotency_key, tool_name, execution_id, conversation_id, operation_id, arguments, outcome)
  VALUES (v_key, 'declaracion_doble', v_exec, p_conv, v_x.id, jsonb_build_array(v_x.service_type, v_x.quoted_source_amount, v_y, v_gy), 'planeado')
  ON CONFLICT (idempotency_key) DO NOTHING;
  RETURN jsonb_build_object('hecho', true, 'motivo', 'planeado', 'total', v_x.quoted_source_amount + v_gy);
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_declaracion_pendiente(p_conv uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object('servicio', d.servicio, 'monto_gyd', d.monto_gyd, 'servicio_actual', d.servicio_actual,
                            'monto_actual_gyd', d.monto_actual_gyd, 'motivo', d.motivo, 'creado_at', d.creado_at)
    FROM cerebro_declaracion_duda d
   WHERE d.conversation_id = p_conv
     AND d.creado_at > now() - make_interval(hours => COALESCE(NULLIF(cerebro_config_get('cotizacion_ventana_horas'), '')::int, 6))
     AND d.creado_at > COALESCE((SELECT max(COALESCE(o.completed_at, o.cancelled_at)) FROM remittance_operations o
                                  WHERE o.conversation_id = p_conv AND o.status IN ('completed', 'cancelled')), '-infinity'::timestamptz)
     AND NOT EXISTS (SELECT 1 FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv)
     AND EXISTS (SELECT 1 FROM remittance_operations o
                  WHERE o.conversation_id = p_conv AND o.service_type = d.servicio_actual AND o.status IN ('collecting_information', 'awaiting_deposit')
                    AND o.mixed_group_id IS NULL AND NOT _cerebro_op_tiene_dinero(o.id))
     AND NOT EXISTS (SELECT 1 FROM remittance_operations o
                      WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled') AND cerebro_riel_op(o.id) = d.servicio);
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_verificar_coherencia_servicio(p_conversation_id uuid, p_execution_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_rieles  constant text[] := ARRAY['zelle', 'clasica', 'tropical', 'cuban_card', 'efectivo_usd'];
  v_exec    text := nullif(btrim(coalesce(p_execution_id, '')), '');
  v_ids     uuid[];
  v_op      uuid;
  v_o       remittance_operations%ROWTYPE;
  v_riel    text;
  v_cot     text;
  v_n       integer := 0;
  v_alert   uuid;
  v_nids    uuid[];
  v_new     boolean := false;
  v_nombre  jsonb := jsonb_build_object('zelle', 'Zelle', 'clasica', 'tarjeta Clásica', 'tropical', 'tarjeta Tropical',
                                        'cuban_card', 'CUP (tarjeta en pesos)', 'efectivo_usd', 'Efectivo en USD');
BEGIN
  IF p_conversation_id IS NULL THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_conversacion', 'resueltas', 0);
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_coherencia:' || p_conversation_id::text, 0));

  -- (371) Two services declared in one turn become a planned split (see _cerebro_declaracion_doble). Never breaks the coherence check or the turn.
  BEGIN
    PERFORM _cerebro_declaracion_doble(p_conversation_id, p_execution_id);
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] _cerebro_declaracion_doble failed for % (%): %', p_conversation_id, SQLSTATE, SQLERRM;
  END;

  SELECT coalesce(array_agg(o.id ORDER BY o.created_at), ARRAY[]::uuid[]) INTO v_ids
    FROM remittance_operations o
   WHERE o.conversation_id = p_conversation_id
     AND o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'incident');

  -- No open operation: an alert left from before has nothing to talk about any more.
  IF coalesce(array_length(v_ids, 1), 0) = 0 THEN
    v_n := cerebro_coherencia_resolver(p_conversation_id, NULL, NULL);
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_operacion', 'resueltas', v_n);
  END IF;
  IF array_length(v_ids, 1) > 1 THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'operacion_ambigua', 'resueltas', 0);
  END IF;
  v_op := v_ids[1];
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'remesa' THEN
    v_n := cerebro_coherencia_resolver(p_conversation_id, NULL, NULL);
    RETURN jsonb_build_object('coherente', true, 'motivo', 'no_remesa', 'resueltas', v_n);
  END IF;

  v_riel := cerebro_riel_op(v_op);
  -- An open alert whose pair no longer holds (the rails match, or the operation moved to a third rail) is closed.
  v_n := cerebro_coherencia_resolver(p_conversation_id, v_op, v_riel);

  IF v_exec IS NULL THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_ejecucion', 'resueltas', v_n);
  END IF;
  IF v_riel IS NULL OR NOT (v_riel = ANY (c_rieles)) THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_riel', 'resueltas', v_n);
  END IF;

  -- The LAST quote the bot gave in this execution (its via was recorded by cerebro_registrar_via_cotizada).
  SELECT t.outcome INTO v_cot
    FROM tool_execution_log t
   WHERE t.execution_id = v_exec AND t.conversation_id = p_conversation_id
     AND t.tool_name IN ('calcular_usd_desde_gyd', 'calcular_usd', 'calcular_envio', 'calcular_inverso')
   ORDER BY t.created_at DESC, t.id DESC
   LIMIT 1;
  IF v_cot IS NULL OR NOT (v_cot = ANY (c_rieles)) THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'sin_cotizacion', 'resueltas', v_n);
  END IF;
  IF v_cot = v_riel THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'misma_via', 'resueltas', v_n);
  END IF;

  -- The bot acted on what it quoted: a successful change / mark to that service in this execution ...
  IF EXISTS (SELECT 1 FROM tool_execution_log t
              WHERE t.execution_id = v_exec AND t.conversation_id = p_conversation_id
                AND ((t.tool_name = 'cambiar_servicio' AND t.outcome IN ('changed', 'unchanged'))
                  OR (t.tool_name = 'marcar_destino_usd' AND t.outcome IN ('marcado', 'sin_cambios')))
                AND cerebro_servicio_normalizar(t.arguments ->> 0) = v_cot) THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'via_confirmada', 'resueltas', v_n);
  END IF;
  -- ... or declared it for the operation that does not exist yet.
  IF EXISTS (SELECT 1 FROM cerebro_destino_pendiente p
              WHERE p.conversation_id = p_conversation_id AND p.origen = 'agente' AND p.tipo = v_cot
                AND p.actualizado > now() - interval '24 hours') THEN
    RETURN jsonb_build_object('coherente', true, 'motivo', 'via_declarada', 'resueltas', v_n);
  END IF;

  -- Quoted one service, the operation is on another, nothing was done about it: one alert per operation and pair.
  SELECT a.id INTO v_alert FROM cerebro_alertas_coherencia a
   WHERE a.operation_id = v_op AND a.cotizado = v_cot AND a.riel_operacion = v_riel AND a.resuelta_en IS NULL;
  IF v_alert IS NULL THEN
    WITH n AS (
      INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
      SELECT v_o.account_id, p.user_id, 'coherencia_servicio', p_conversation_id, v_o.contact_id,
             'Revisar servicio: el bot cotizó ' || (v_nombre ->> v_cot) || ' y la operación está en ' || (v_nombre ->> v_riel),
             'En esta conversación el bot cotizó ' || (v_nombre ->> v_cot) || ', pero la operación sigue en ' || (v_nombre ->> v_riel) ||
             '. Puede haber sido solo una consulta de precio. Revise si el cliente cambió de servicio y, si es así, cámbielo en el panel. ' ||
             'El bot no cambió nada y no escribió al cliente por este aviso.'
        FROM profiles p
       WHERE p.account_id = v_o.account_id
         AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id)
      RETURNING id)
    SELECT coalesce(array_agg(id), ARRAY[]::uuid[]) INTO v_nids FROM n;
    INSERT INTO cerebro_alertas_coherencia (account_id, conversation_id, operation_id, cotizado, riel_operacion, ejecucion, notification_ids)
    VALUES (v_o.account_id, p_conversation_id, v_op, v_cot, v_riel, v_exec, v_nids)
    RETURNING id INTO v_alert;
    v_new := true;
  END IF;

  RETURN jsonb_build_object('coherente', false, 'cotizado', v_cot, 'operacion', v_riel, 'alert_id', v_alert,
                            'operation_id', v_op, 'nueva', v_new, 'resueltas', v_n);
END $function$;

REVOKE ALL ON FUNCTION public._cerebro_declaracion_doble(uuid, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cerebro_declaracion_pendiente(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_declaracion_pendiente(uuid) TO service_role;
