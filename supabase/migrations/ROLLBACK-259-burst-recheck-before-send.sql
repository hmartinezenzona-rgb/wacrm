-- =====================================================================
-- ROLLBACK 259: the gate and the claim go back to their bodies before 259 (gate STABLE, executable by PUBLIC as it
-- was), and cerebro_ejecuciones.memoria_hasta is dropped. No data changes.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_reclamar_lote(p_conversation_id uuid, p_execution_id text)
 RETURNS SETOF session_events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  RETURN QUERY
  WITH cand AS (
    SELECT e.id
      FROM session_events e
     WHERE e.conversation_id = p_conversation_id
       AND e.processing_status IN ('pending','retry_wait')
     ORDER BY e.id
       FOR UPDATE SKIP LOCKED
  ),
  reclamados AS (
    UPDATE session_events s
       SET processing_status       = 'processing',
           processing_execution_id = p_execution_id,
           processing_started_at   = now(),
           next_retry_at           = NULL,
           procesado               = true
     WHERE s.id IN (SELECT id FROM cand)
    RETURNING s.*
  )
  SELECT * FROM reclamados ORDER BY id;

  DELETE FROM cerebro_reintentos WHERE conversation_id = p_conversation_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.cerebro_valla_de_propiedad(p_conversation_id uuid, p_execution_id text)
 RETURNS TABLE(bloquear boolean, motivo text, desde timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_desde timestamptz;
  v_conv  record;
BEGIN
  -- Desde cuando miramos: el momento en que este lote se reclamo. Si el lote ya
  -- se cerro, caemos al inicio de la ejecucion, y si tampoco, a una ventana
  -- corta. Nunca NULL: sin ventana no habria valla.
  SELECT min(se.processing_started_at) INTO v_desde
    FROM session_events se
   WHERE se.processing_execution_id = p_execution_id;

  IF v_desde IS NULL THEN
    SELECT e.started_at INTO v_desde
      FROM cerebro_ejecuciones e
     WHERE e.execution_id = p_execution_id;
  END IF;

  v_desde := coalesce(v_desde, now() - interval '2 minutes');

  SELECT c.ai_autoreply_disabled, c.deleted_at, c.assigned_agent_id,
         c.assigned_at, c.ai_handoff_at
    INTO v_conv
    FROM conversations c
   WHERE c.id = p_conversation_id;

  IF NOT FOUND THEN
    RETURN QUERY SELECT true, 'conversacion_inexistente'::text, v_desde;
    RETURN;
  END IF;

  -- 1 · el bot esta pausado AHORA
  IF coalesce(v_conv.ai_autoreply_disabled, false) THEN
    RETURN QUERY SELECT true, 'bot_pausado'::text, v_desde;
    RETURN;
  END IF;

  -- 2 · la conversacion se oculto
  IF v_conv.deleted_at IS NOT NULL THEN
    RETURN QUERY SELECT true, 'conversacion_oculta'::text, v_desde;
    RETURN;
  END IF;

  -- 3 · alguien se asigno el chat DESPUES de que empezara el turno. Una
  --     asignacion anterior ya la vio el Decisor (y callo); si llego aqui es
  --     que habia caducado, y eso no se vuelve a bloquear.
  IF v_conv.assigned_agent_id IS NOT NULL
     AND v_conv.assigned_at IS NOT NULL
     AND v_conv.assigned_at >= v_desde THEN
    RETURN QUERY SELECT true, 'asignada_durante_el_turno'::text, v_desde;
    RETURN;
  END IF;

  -- 4 · derivacion registrada durante el turno
  IF v_conv.ai_handoff_at IS NOT NULL AND v_conv.ai_handoff_at >= v_desde THEN
    RETURN QUERY SELECT true, 'derivada_durante_el_turno'::text, v_desde;
    RETURN;
  END IF;

  -- 5 · una persona del equipo escribio mientras se procesaba el turno.
  --     ai_generated = true es el bot y la API (incluido el notificador de
  --     etapa), asi que queda fuera. Las plantillas y las imagenes enviadas a
  --     mano SI cuentan: son una persona atendiendo.
  IF EXISTS (SELECT 1
               FROM messages m
              WHERE m.conversation_id = p_conversation_id
                AND m.sender_type = 'agent'
                AND coalesce(m.ai_generated, false) = false
                AND m.created_at >= v_desde) THEN
    RETURN QUERY SELECT true, 'humano_escribio_durante_el_turno'::text, v_desde;
    RETURN;
  END IF;

  RETURN QUERY SELECT false, NULL::text, v_desde;
END;
$function$
;

-- Rebuild the ACL in its original order {=X, postgres=X, service_role=X}.
REVOKE ALL ON FUNCTION public.cerebro_valla_de_propiedad(uuid, text) FROM PUBLIC, postgres, service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_valla_de_propiedad(uuid, text) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_valla_de_propiedad(uuid, text) TO postgres;
GRANT EXECUTE ON FUNCTION public.cerebro_valla_de_propiedad(uuid, text) TO service_role;
ALTER TABLE public.cerebro_ejecuciones DROP COLUMN IF EXISTS memoria_hasta;
