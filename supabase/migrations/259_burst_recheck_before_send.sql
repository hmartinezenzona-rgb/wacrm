-- =====================================================================
-- 259: burst, re-check before sending.
--
-- When the customer writes again while the Cerebro is still answering batch A, B's message lands as a new pending
-- event; B's execution claims [B] alone and the customer gets two replies, the first one blind to B (10.8% of batches,
-- 2026-09-21..10-21). The final gate "Valla de propiedad" runs with A's reply written but not sent, usually before B's
-- claim. Check 6 there now hands A back: A's events return to pending, the memory rows A's agent wrote are deleted,
-- and the reply is not sent; B's execution then claims A + B and answers them together.
--
-- Check 6 runs after checks 1-5 and drops only when ALL hold (otherwise A sends as before):
--   - a newer event of the conversation is still unclaimed (pending / retry_wait);
--   - A's batch has no image or document (receipts and deposits have side effects);
--   - A logged no tool other than calcular_* / consultar_* (no data written);
--   - the memory baseline of A's claim is known (cerebro_ejecuciones.memoria_hasta, set by cerebro_reclamar_lote).
-- Both functions take a per-conversation advisory lock so a release never interleaves with a claim.
-- The gate now writes, so it is VOLATILE and no longer executable by PUBLIC (service_role only, as the claim).
--
-- ROLLBACK: ROLLBACK-259-burst-recheck-before-send.sql
-- Guarded by supabase/staging/assertions/burst-recheck-before-send.sql
-- =====================================================================

ALTER TABLE public.cerebro_ejecuciones ADD COLUMN IF NOT EXISTS memoria_hasta integer;
COMMENT ON COLUMN public.cerebro_ejecuciones.memoria_hasta IS
  '259. Highest cerebro_memoria.id of the conversation when this execution claimed its batch; the gate deletes rows above it when it hands the batch back.';

CREATE OR REPLACE FUNCTION public.cerebro_reclamar_lote(p_conversation_id uuid, p_execution_id text)
 RETURNS SETOF session_events
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- 259: serialize with the gate's hand-back for this conversation.
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_lote:' || p_conversation_id::text, 0));

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

  -- 259: memory baseline of this turn (the agent writes its rows after this point).
  UPDATE cerebro_ejecuciones e
     SET memoria_hasta = coalesce((SELECT max(m.id) FROM cerebro_memoria m
                                    WHERE m.session_id = p_conversation_id::text), 0)
   WHERE e.execution_id = p_execution_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_valla_de_propiedad(p_conversation_id uuid, p_execution_id text)
 RETURNS TABLE(bloquear boolean, motivo text, desde timestamp with time zone)
 LANGUAGE plpgsql
 VOLATILE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_desde timestamptz;
  v_conv  record;
  v_max   bigint;
  v_media boolean;
  v_hasta integer;
BEGIN
  -- 259: serialize with cerebro_reclamar_lote for this conversation (check 6 hands the batch back).
  PERFORM pg_advisory_xact_lock(hashtextextended('cerebro_lote:' || p_conversation_id::text, 0));

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

  -- 6 · (259) el cliente escribio otra vez mientras se pensaba esta respuesta y ese mensaje todavia no lo
  --     reclamo nadie: no se envia; el lote vuelve a pendiente y la ejecucion mas nueva responde todo junto.
  --     Solo si el turno no dejo efectos: sin imagen/documento, sin herramientas que escriben, y con la marca
  --     de memoria del reclamo (para borrar lo que escribio el agente). En cualquier otro caso sale como antes.
  SELECT max(se.id), bool_or(se.tipo IN ('image', 'document'))
    INTO v_max, v_media
    FROM session_events se
   WHERE se.processing_execution_id = p_execution_id
     AND se.processing_status = 'processing';

  SELECT e.memoria_hasta INTO v_hasta
    FROM cerebro_ejecuciones e
   WHERE e.execution_id = p_execution_id;

  IF v_max IS NOT NULL
     AND NOT coalesce(v_media, false)
     AND v_hasta IS NOT NULL
     AND EXISTS (SELECT 1 FROM session_events n
                  WHERE n.conversation_id = p_conversation_id
                    AND n.id > v_max
                    AND n.processing_status IN ('pending', 'retry_wait'))
     AND NOT EXISTS (SELECT 1 FROM tool_execution_log t
                      WHERE t.execution_id = p_execution_id
                        AND t.tool_name !~ '^(calcular_|consultar_)') THEN
    UPDATE session_events se
       SET processing_status       = 'pending',
           processing_execution_id = NULL,
           processing_started_at   = NULL,
           procesado               = false
     WHERE se.processing_execution_id = p_execution_id
       AND se.processing_status = 'processing';

    DELETE FROM cerebro_memoria m
     WHERE m.session_id = p_conversation_id::text
       AND m.id > v_hasta;

    RETURN QUERY SELECT true, 'mensaje_nuevo_durante_el_turno'::text, v_desde;
    RETURN;
  END IF;

  RETURN QUERY SELECT false, NULL::text, v_desde;
END;
$function$;

REVOKE ALL ON FUNCTION public.cerebro_valla_de_propiedad(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_valla_de_propiedad(uuid, text) TO service_role;
