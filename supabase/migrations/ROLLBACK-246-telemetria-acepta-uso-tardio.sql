-- Rollback for 246_telemetria_acepta_uso_tardio.sql
--
-- Puts the five usage fields back to INSERT-only, i.e. restores the behaviour
-- where a late call carrying model usage is silently discarded. Only roll this
-- back if 246 itself is suspected of harm; note that the pre-246 behaviour IS
-- the defect, so rolling back re-breaks the token collector.
--
-- Everything else is byte-identical to 246: the only difference is the five
-- lines removed from the ON CONFLICT DO UPDATE branch.

CREATE OR REPLACE FUNCTION public.cerebro_telemetria_registrar(p_execution_id text, p_datos jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_inicio timestamptz;
BEGIN
  IF NULLIF(trim(coalesce(p_execution_id, '')), '') IS NULL THEN
    RETURN;
  END IF;

  SELECT e.started_at INTO v_inicio
    FROM cerebro_ejecuciones e
   WHERE e.execution_id = p_execution_id;

  INSERT INTO cerebro_telemetria_turno AS t (
    execution_id, conversation_id, started_at, finished_at, latency_ms,
    ruta, modelo_llamado, model_calls, prompt_tokens, completion_tokens,
    reasoning_tokens, cache_hit_tokens, prompt_chars, contexto_chars,
    vision_calls, vision_input_tokens, vision_output_tokens,
    vision_rotation_selected, vision_ledger_confirmed, vision_policy,
    audio_calls, audio_duration_ms,
    ownership_fence_blocked, ownership_fence_reason,
    response_chars, questions, entrega,
    renderer_modo, renderer_aplicado, renderer_motivo, renderer_chars,
    renderer_questions, error_type, extra
  )
  VALUES (
    p_execution_id,
    NULLIF(p_datos->>'conversation_id','')::uuid,
    v_inicio,
    now(),
    CASE WHEN v_inicio IS NOT NULL THEN (extract(epoch FROM (now() - v_inicio)) * 1000)::integer END,
    p_datos->>'ruta',
    (p_datos->>'modelo_llamado')::boolean,
    (p_datos->>'model_calls')::integer,
    (p_datos->>'prompt_tokens')::integer,
    (p_datos->>'completion_tokens')::integer,
    (p_datos->>'reasoning_tokens')::integer,
    (p_datos->>'cache_hit_tokens')::integer,
    (p_datos->>'prompt_chars')::integer,
    (p_datos->>'contexto_chars')::integer,
    (p_datos->>'vision_calls')::integer,
    (p_datos->>'vision_input_tokens')::integer,
    (p_datos->>'vision_output_tokens')::integer,
    (p_datos->>'vision_rotation_selected')::integer,
    (p_datos->>'vision_ledger_confirmed')::boolean,
    p_datos->>'vision_policy',
    (p_datos->>'audio_calls')::integer,
    (p_datos->>'audio_duration_ms')::integer,
    coalesce((p_datos->>'ownership_fence_blocked')::boolean, false),
    p_datos->>'ownership_fence_reason',
    (p_datos->>'response_chars')::integer,
    (p_datos->>'questions')::integer,
    p_datos->>'entrega',
    p_datos->>'renderer_modo',
    (p_datos->>'renderer_aplicado')::boolean,
    p_datos->>'renderer_motivo',
    (p_datos->>'renderer_chars')::integer,
    (p_datos->>'renderer_questions')::integer,
    p_datos->>'error_type',
    p_datos->'extra'
  )
  ON CONFLICT (execution_id) DO UPDATE SET
    conversation_id = coalesce(EXCLUDED.conversation_id, t.conversation_id),
    finished_at = EXCLUDED.finished_at,
    latency_ms = coalesce(EXCLUDED.latency_ms, t.latency_ms),
    ruta = coalesce(EXCLUDED.ruta, t.ruta),
    modelo_llamado = coalesce(EXCLUDED.modelo_llamado, t.modelo_llamado),
    vision_calls = coalesce(EXCLUDED.vision_calls, t.vision_calls),
    vision_policy = coalesce(EXCLUDED.vision_policy, t.vision_policy),
    audio_calls = coalesce(EXCLUDED.audio_calls, t.audio_calls),
    ownership_fence_blocked = EXCLUDED.ownership_fence_blocked OR t.ownership_fence_blocked,
    ownership_fence_reason = coalesce(EXCLUDED.ownership_fence_reason, t.ownership_fence_reason),
    response_chars = coalesce(EXCLUDED.response_chars, t.response_chars),
    questions = coalesce(EXCLUDED.questions, t.questions),
    entrega = coalesce(EXCLUDED.entrega, t.entrega),
    renderer_modo = coalesce(EXCLUDED.renderer_modo, t.renderer_modo),
    renderer_aplicado = coalesce(EXCLUDED.renderer_aplicado, t.renderer_aplicado),
    renderer_motivo = coalesce(EXCLUDED.renderer_motivo, t.renderer_motivo),
    renderer_chars = coalesce(EXCLUDED.renderer_chars, t.renderer_chars),
    renderer_questions = coalesce(EXCLUDED.renderer_questions, t.renderer_questions),
    prompt_chars = coalesce(EXCLUDED.prompt_chars, t.prompt_chars),
    contexto_chars = coalesce(EXCLUDED.contexto_chars, t.contexto_chars),
    error_type = coalesce(EXCLUDED.error_type, t.error_type),
    extra = coalesce(EXCLUDED.extra, t.extra);
EXCEPTION WHEN others THEN
  RETURN;
END;
$function$;
