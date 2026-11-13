-- Rollback of 371: restores cerebro_verificar_coherencia_servicio to its live production body (read 2026-11-13, md5 5b849da27e0478a0626e0df56331c397) and
-- drops the declaration check, its pending-fact reader and its table. Plans already made by the check stay (they are ordinary planned splits).

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

DROP FUNCTION IF EXISTS public.cerebro_declaracion_pendiente(uuid);
DROP FUNCTION IF EXISTS public._cerebro_declaracion_doble(uuid, text);
DROP TABLE IF EXISTS public.cerebro_declaracion_duda;
