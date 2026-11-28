-- 361 -- The message-rate limit locks once, alerts once, and never fires on a chat a team member is attending.
--
-- Root cause (2026-11-09, one customer burst of 64 messages in 60 min, the owner replying by hand): the n8n node `Control de abuso`
-- counted session_events of the last hour (> 30), called cerebro_registrar_derivacion(conv, motivo, 'abuso', true) and posted a LIMITE
-- alert to the notifier, then `Acaba de derivar?` sent the customer "Un momento por favor ...". cerebro_registrar_derivacion returns a
-- row whenever the chat is unassigned OR assigned to the bot agent, so every later pass "just handed off" again: 48 alerts and 48
-- waiting messages in 23 minutes. The limit also ignored that a person was writing in the chat, and 30/hour is below a fast real customer.
--
-- Data (production, 60 days, 200 conversations, inbound customer messages in any rolling 60 minutes): p50 8, p90 18, p99 30, max 64;
-- over 20: 13, over 30: 2, over 40: 1, over 60: 1, over 80: 0. Both conversations over 30 had a team member writing in the 30 minutes
-- before the peak. The highest legitimate hour is 33, so the new default is 40 (strictly more than 40 events in the last hour).
--
-- Design: the whole decision lives in cerebro_control_abuso(conv, repeated_questions). In order:
--   1. events in the last hour <= limit                      -> continue (excede false), nothing else.
--   2. the conversation row is locked (FOR UPDATE), so two concurrent passes serialize and the second sees the first one's lock.
--   3. already locked for abuse (ai_autoreply_disabled, ai_handoff_reason 'abuso', assigned to the bot) -> silent (excede true, no alert).
--   4. a team member wrote in the last N minutes (non-bot agent message) -> continue, no lock, no alert.
--   5. otherwise lock with cerebro_registrar_derivacion(..., 'abuso', true). A row back = first lock: post the LIMITE alert (same
--      notifier payload as the node had) and return bloquear_ahora true (the node sends the waiting message). No row back = the chat is
--      in somebody else's hands: silent.
-- Lock-once is the state itself, so the alert has no time throttle: after the team unassigns or re-enables the chat the state clears and a
-- new flood locks and alerts again (a 6 h timer would swallow that second, wanted alert).
-- Config keys (optional): abuso_limite_mensajes (default 40), abuso_humano_activo_minutos (default 30).
-- cerebro_registrar_derivacion is NOT changed (other motivos keep their behaviour). Rollback: ROLLBACK-361-abuse-limit-once.sql.

CREATE OR REPLACE FUNCTION public.cerebro_control_abuso(p_conversation_id uuid, p_preguntas_repetidas integer DEFAULT 0)
 RETURNS TABLE(eventos integer, excede boolean, bloquear_ahora boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_limite  integer := COALESCE(NULLIF(cerebro_config_get('abuso_limite_mensajes'), '')::integer, 40);
  v_humano  integer := COALESCE(NULLIF(cerebro_config_get('abuso_humano_activo_minutos'), '')::integer, 30);
  v_n       integer;
  v_asignado uuid;
  v_apagado boolean;
  v_razon   text;
  v_phone   text;
  v_bot constant uuid := '377b0c8c-c025-46ff-8088-7a929080831e';
BEGIN
  SELECT count(*)::integer INTO v_n
    FROM session_events s
   WHERE s.conversation_id = p_conversation_id AND s.creado_at > now() - interval '1 hour';

  IF v_n <= v_limite THEN
    RETURN QUERY SELECT v_n, false, false;
    RETURN;
  END IF;

  SELECT c.assigned_agent_id, COALESCE(c.ai_autoreply_disabled, false), c.ai_handoff_reason, ct.phone
    INTO v_asignado, v_apagado, v_razon, v_phone
    FROM conversations c JOIN contacts ct ON ct.id = c.contact_id
   WHERE c.id = p_conversation_id
     FOR UPDATE OF c;
  IF NOT FOUND THEN
    RETURN QUERY SELECT v_n, false, false;
    RETURN;
  END IF;

  -- Already locked for abuse and still in the bot's hands: stay silent, no second alert, no second waiting message.
  IF v_apagado AND v_razon = 'abuso' AND v_asignado = v_bot THEN
    RETURN QUERY SELECT v_n, true, false;
    RETURN;
  END IF;

  -- A team member is writing in this chat: never lock it.
  IF EXISTS (SELECT 1 FROM messages m
              WHERE m.conversation_id = p_conversation_id
                AND m.sender_type = 'agent'
                AND NOT COALESCE(m.ai_generated, false)
                AND m.created_at > now() - make_interval(mins => v_humano)) THEN
    RETURN QUERY SELECT v_n, false, false;
    RETURN;
  END IF;

  PERFORM 1 FROM cerebro_registrar_derivacion(p_conversation_id, 'Se alcanzó el límite de mensajes en una hora.', 'abuso', true);
  IF NOT FOUND THEN
    -- Assigned to a person: not ours to lock. Silent, as before.
    RETURN QUERY SELECT v_n, true, false;
    RETURN;
  END IF;

  PERFORM net.http_post(
    url := cerebro_config_get('notify_url'),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'X-Cerebro-Secret', cerebro_config_get('notify_secret')),
    body := jsonb_build_object('type', 'LIMITE',
                               'cliente_phone', v_phone,
                               'eventos', v_n,
                               'preguntas_repetidas', p_preguntas_repetidas));

  RETURN QUERY SELECT v_n, true, true;
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_control_abuso(uuid, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_control_abuso(uuid, integer) TO service_role;
