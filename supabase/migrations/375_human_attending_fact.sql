-- 375: is a person of the team attending this chat right now? (read-only fact)
--
-- Owner, 2026-11-15: while an admin attends a chat the system must not write to the customer on its own. The Decisor already decides
-- this for the bot (node "Contexto conversacion": bot_pausado / asignado / humano_reciente). The stage notifier (n8n) is another sender and
-- had no way to ask. Production conversation 5a4c0ab8 (2026-11-14): an admin chatted, forced the deposit verification from the panel and
-- the notifier asked the customer for data he had just sent.
--
-- Same definition as the Decisor's, WITHOUT its side effects (that query releases an expired pause or assignment with an UPDATE; a
-- notifier asking a question must not change the conversation):
--   * a message of a person (sender agent, not ai_generated, not a panel action) in the last 5 minutes, after the chat was last handed
--     back to the bot (ai_resumed_at);
--   * the bot paused here: a pause left by a panel reply (ai_handoff_reason = 'agent_replied') lives pausa_humana_caduca_minutos (5)
--     counted from the last human activity; any other pause (the customer asked for a person, abuse) never expires;
--   * the chat assigned: a manual assignment lives asignacion_caduca_minutos (10) counted from the last human activity; the bot's own
--     derivation profile never expires.
-- Unknown or NULL conversation -> false.

CREATE OR REPLACE FUNCTION public.cerebro_humano_atendiendo(p_conv uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c        record;
  v_pausa  integer := coalesce(nullif(cerebro_config_get('pausa_humana_caduca_minutos'), '')::integer, 5);
  v_asig   integer := coalesce(nullif(cerebro_config_get('asignacion_caduca_minutos'), '')::integer, 10);
  v_ultimo timestamptz;
BEGIN
  IF p_conv IS NULL THEN RETURN false; END IF;

  SELECT cv.ai_autoreply_disabled, cv.ai_handoff_reason, cv.ai_handoff_at, cv.assigned_agent_id, cv.assigned_at, cv.ai_resumed_at
    INTO c
    FROM conversations cv
   WHERE cv.id = p_conv;
  IF NOT FOUND THEN RETURN false; END IF;

  -- a person wrote in the last 5 minutes, after the last hand-back to the bot
  IF EXISTS (SELECT 1
               FROM messages m
              WHERE m.conversation_id = p_conv
                AND m.sender_type = 'agent'
                AND coalesce(m.ai_generated, false) = false
                AND coalesce(m.is_panel_action, false) = false
                AND m.created_at > now() - interval '5 minutes'
                AND m.created_at > coalesce(c.ai_resumed_at, to_timestamp(0))) THEN
    RETURN true;
  END IF;

  -- the last human message, panel replies included: it keeps a pause or an assignment alive
  SELECT max(m.created_at) INTO v_ultimo
    FROM messages m
   WHERE m.conversation_id = p_conv
     AND m.sender_type = 'agent'
     AND coalesce(m.ai_generated, false) = false;

  IF coalesce(c.ai_autoreply_disabled, false) THEN
    IF c.ai_handoff_reason IS DISTINCT FROM 'agent_replied' THEN RETURN true; END IF;
    IF greatest(coalesce(c.ai_handoff_at, '-infinity'::timestamptz), coalesce(v_ultimo, '-infinity'::timestamptz))
         >= now() - make_interval(mins => v_pausa) THEN
      RETURN true;
    END IF;
  END IF;

  IF c.assigned_agent_id IS NOT NULL THEN
    IF c.assigned_agent_id = '377b0c8c-c025-46ff-8088-7a929080831e'::uuid THEN RETURN true; END IF;
    IF greatest(coalesce(c.assigned_at, '-infinity'::timestamptz), coalesce(v_ultimo, '-infinity'::timestamptz))
         >= now() - make_interval(mins => v_asig) THEN
      RETURN true;
    END IF;
  END IF;

  RETURN false;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_humano_atendiendo(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_humano_atendiendo(uuid) TO service_role;
