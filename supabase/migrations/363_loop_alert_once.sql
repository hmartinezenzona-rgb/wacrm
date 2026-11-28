-- 363 -- The closed-question loop (bucle) hands the chat off once and alerts once, like the message-rate limit (361).
--
-- Root cause: after 361 the n8n node `Control de abuso` still called cerebro_registrar_derivacion(conv, motivo, 'bucle', true) on every
-- pass in which the loop was seen. That function returns a row whenever the chat is unassigned OR assigned to the bot agent, so every
-- later pass "just handed off" again: the BUCLE alert and the waiting message to the customer repeated for as long as the chat stayed held.
--
-- Design: a SIBLING function, cerebro_control_bucle(conv, en_bucle, preguntas_repetidas, excede, eventos), instead of extending
-- cerebro_control_abuso. Extending would change that function's RETURNS TABLE, which needs DROP + CREATE (grants and the production node
-- that already calls the 3-column shape would break between migration and node change). A sibling is additive: nothing existing is
-- redefined, the node is switched afterwards, and the rollback is one DROP. The loop detection (4 repeated questions in the hour, counted
-- from messages) stays in the node and arrives as en_bucle; this function only decides what to do about it. In order:
--   1. not in a loop, or the abuse limit already decides (excede)  -> false, nothing else.
--   2. the conversation row is locked (FOR UPDATE), so two concurrent passes serialize and the second sees the first one's lock.
--   3. already held by the bot for bucle or abuso (ai_autoreply_disabled, reason, assigned to the bot) -> false, silent.
--   4. otherwise cerebro_registrar_derivacion(..., 'bucle', true). A row back = first derivation: post the BUCLE alert (same notifier
--      payload as the node had: type, cliente_phone, eventos, preguntas_repetidas) and return true (the node sends the waiting message).
--      No row back = a person holds the chat: false, silent, untouched.
-- Lock-once is the chat state itself, so there is no alert timer: after the team unassigns or re-enables the chat a new loop alerts again.
-- A chat held by the bot for any other reason is re-labelled bucle once (one alert), as before.
-- cerebro_registrar_derivacion and cerebro_control_abuso are NOT changed. Rollback: ROLLBACK-363-loop-alert-once.sql (restore the node first).

CREATE OR REPLACE FUNCTION public.cerebro_control_bucle(p_conversation_id uuid, p_en_bucle boolean, p_preguntas_repetidas integer,
                                                       p_excede boolean DEFAULT false, p_eventos integer DEFAULT 0)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_asignado uuid;
  v_apagado boolean;
  v_razon   text;
  v_phone   text;
  v_bot constant uuid := '377b0c8c-c025-46ff-8088-7a929080831e';
BEGIN
  IF NOT COALESCE(p_en_bucle, false) OR COALESCE(p_excede, false) THEN
    RETURN false;
  END IF;

  SELECT c.assigned_agent_id, COALESCE(c.ai_autoreply_disabled, false), c.ai_handoff_reason, ct.phone
    INTO v_asignado, v_apagado, v_razon, v_phone
    FROM conversations c JOIN contacts ct ON ct.id = c.contact_id
   WHERE c.id = p_conversation_id
     FOR UPDATE OF c;
  IF NOT FOUND THEN
    RETURN false;
  END IF;

  -- Already held by the bot for a loop or for abuse: stay silent, no second alert, no second waiting message.
  IF v_apagado AND v_asignado = v_bot AND v_razon IN ('bucle', 'abuso') THEN
    RETURN false;
  END IF;

  PERFORM 1 FROM cerebro_registrar_derivacion(p_conversation_id, 'La conversación repitió una pregunta cerrada varias veces.', 'bucle', true);
  IF NOT FOUND THEN
    -- Assigned to a person: not ours to lock. Silent.
    RETURN false;
  END IF;

  PERFORM net.http_post(
    url := cerebro_config_get('notify_url'),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'X-Cerebro-Secret', cerebro_config_get('notify_secret')),
    body := jsonb_build_object('type', 'BUCLE',
                               'cliente_phone', v_phone,
                               'eventos', p_eventos,
                               'preguntas_repetidas', p_preguntas_repetidas));

  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_control_bucle(uuid, boolean, integer, boolean, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_control_bucle(uuid, boolean, integer, boolean, integer) TO service_role;
