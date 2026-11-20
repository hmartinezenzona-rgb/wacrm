-- ROLLBACK 385: restores the bodies from before 385 (live production bodies read 2026-11-20 with pg_get_functiondef;
-- cerebro_humano_atendiendo as in 375). Only agent_replied pauses expire again.

CREATE OR REPLACE FUNCTION public.cerebro_caducar_pausa_humana(p_conversation_id uuid)
 RETURNS TABLE(id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_minutos integer;
BEGIN
  v_minutos := COALESCE(
    NULLIF(cerebro_config_get('pausa_humana_caduca_minutos'), '')::integer,
    5);

  RETURN QUERY
  UPDATE conversations c
     SET ai_autoreply_disabled = false,
         ai_handoff_reason = NULL,
         ai_handoff_at = NULL
   WHERE c.id = p_conversation_id
     AND COALESCE(c.ai_autoreply_disabled, false)
     AND c.ai_handoff_reason = 'agent_replied'
     AND GREATEST(
           COALESCE(c.ai_handoff_at, '-infinity'::timestamptz),
           COALESCE((SELECT max(m.created_at)
                       FROM messages m
                      WHERE m.conversation_id = c.id
                        AND m.sender_type = 'agent'
                        AND COALESCE(m.ai_generated, false) = false),
                    '-infinity'::timestamptz)
         ) < now() - make_interval(mins => v_minutos)
  RETURNING c.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_caducar_pausas_humanas()
 RETURNS integer
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT count(*)::integer
    FROM conversations c
    CROSS JOIN LATERAL cerebro_caducar_pausa_humana(c.id) liberada
   WHERE c.ai_autoreply_disabled
     AND c.ai_handoff_reason = 'agent_replied';
$function$;

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
