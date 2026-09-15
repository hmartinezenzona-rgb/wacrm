-- =====================================================================
-- 103 — La pausa por envío humano caduca también por reloj
--
-- POR QUÉ NO BASTABA LA 102
-- La 102 quita la pausa `agent_replied` cuando llega un mensaje del cliente
-- (la llama `Contexto conversacion`). El bot ya contestaba bien, pero la
-- bandeja seguía pintando esos chats con el icono de «atendida por una
-- persona» (resolveConversationOwnership: pausada + agent_replied = human)
-- hasta que el cliente volviera a escribir. El 15-sep quedaban 58 así.
-- Decisión del dueño (15-sep-2026): liberarlos ya, sin icono, y que a partir
-- de ahora la pausa se quite sola a los 5 minutos aunque nadie escriba.
--
-- QUÉ HACE
--   · cerebro_caducar_pausas_humanas(): barrido de todas las conversaciones.
--     NO repite la regla: llama a cerebro_caducar_pausa_humana(id) de la 102
--     por cada candidata, así la regla vive en un único sitio.
--   · Job de pg_cron `caducar-pausas-humanas` cada minuto. La pausa dura
--     entre 5 y 6 minutos sin actividad humana.
--
-- LO QUE NO CAMBIA
--   · La pausa manual del panel (sin motivo) no caduca nunca y sigue
--     pintando el icono de «Bot pausado».
--   · Las derivaciones del bot (solicitud_cliente, bucle, abuso, mlc,
--     operacion_ambigua...) no pasan por aquí.
--   · No toca assigned_agent_id. updated_at sí se mueve (trigger
--     set_updated_at), pero la bandeja ordena por last_message_at, así que
--     liberar no reordena la lista.
-- =====================================================================

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

-- Mismo perímetro que la 102: SECURITY DEFINER y masiva, nadie con sesión o
-- clave pública debe poder llamarla.
REVOKE ALL ON FUNCTION public.cerebro_caducar_pausas_humanas() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_caducar_pausas_humanas() TO service_role;

-- Idempotente: si el job ya existe se reprograma con el mismo nombre.
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'caducar-pausas-humanas';
SELECT cron.schedule(
  'caducar-pausas-humanas',
  '* * * * *',
  'SELECT public.cerebro_caducar_pausas_humanas()'
);
