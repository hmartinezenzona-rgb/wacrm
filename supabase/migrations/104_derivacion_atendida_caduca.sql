-- =====================================================================
-- 104 — Una derivación del bot ya atendida se libera sola a los 5 minutos
--
-- EL PROBLEMA (medido en producción el 15-sep-2026)
-- Las derivaciones del bot (cerebro_registrar_derivacion: solicitud_cliente,
-- bucle, abuso, mlc, operacion_ambigua, fallo_sistema_nuevo...) asignan el
-- chat al perfil de derivaciones 377b0c8c y NO caducaban nunca. Quitarlas
-- a mano funciona, pero nadie lo hacía al terminar de atender: había 23
-- chats con el icono de persona y el bot callado, 22 de ellos con mensajes
-- humanos posteriores a la derivación, el más antiguo del 20-ago.
-- Además 8 estaban a medias: bot activo pero todavía asignados al perfil.
--
-- LA DECISIÓN (dueño, 15-sep-2026)
-- Si una persona ya respondió después de la derivación y luego pasan N
-- minutos sin actividad humana (por defecto 5), el chat vuelve al bot.
-- Si nadie la ha atendido todavía, la derivación se queda: el cliente pidió
-- un humano y el bot no debe volver a hablarle antes de que alguien lo haga.
--
-- QUÉ CUENTA
--   · Derivación = assigned_agent_id es el perfil 377b0c8c, O el chat ya no
--     está asignado pero sigue pausado con un motivo de derivación (alguien
--     quitó la asignación y no pulsó «Reanudar bot»: el icono de persona
--     se va, pero el bot sigue callado). 'agent_replied' es de la 102.
--     Los chats asignados a una persona del equipo tienen su propia
--     caducidad (CTE `caducar` del Cerebro) y aquí no se tocan.
--   · Inicio de la derivación = ai_handoff_at, o assigned_at si no hay.
--   · Actividad humana = mensajes sender_type 'agent' con ai_generated false.
--   · La pausa manual (bot pausado sin motivo) NUNCA se libera aquí.
--
-- CÓMO LIBERA
-- Igual que «Reanudar bot» y cerebro_liberar_derivacion_ambigua: quita la
-- asignación, la pausa, el motivo, la nota y reinicia el contador. Al quitar
-- la asignación dispara trg_limpiar_memoria_al_liberar, que deja al bot la
-- marca «ATENCION HUMANA YA TERMINADA» para que no mencione la derivación.
--
-- Corre cada minuto con pg_cron (`caducar-derivaciones-atendidas`). Si el
-- motivo sigue vivo (p. ej. el cliente vuelve a pedir MLC en 15 minutos, o
-- sigue el bucle), el Cerebro vuelve a derivar en el siguiente mensaje.
--
-- El plazo se cambia sin desplegar:
--   UPDATE cerebro_config SET valor = '10' WHERE clave = 'derivacion_atendida_caduca_minutos';
-- =====================================================================

INSERT INTO public.cerebro_config (clave, valor, descripcion)
VALUES (
  'derivacion_atendida_caduca_minutos',
  '5',
  'Minutos sin actividad humana tras los que una derivación del bot ya atendida por una persona vuelve al bot. Migración 104.'
)
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_caducar_derivacion_atendida(p_conversation_id uuid)
RETURNS TABLE(id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_minutos integer;
BEGIN
  v_minutos := COALESCE(
    NULLIF(cerebro_config_get('derivacion_atendida_caduca_minutos'), '')::integer,
    5);

  RETURN QUERY
  WITH ultimo_humano AS (
    SELECT max(m.created_at) AS en
      FROM messages m
     WHERE m.conversation_id = p_conversation_id
       AND m.sender_type = 'agent'
       AND COALESCE(m.ai_generated, false) = false
  )
  UPDATE conversations c
     SET assigned_agent_id = NULL,
         ai_autoreply_disabled = false,
         ai_reply_count = 0,
         ai_handoff_summary = NULL,
         ai_handoff_reason = NULL,
         ai_handoff_at = NULL
    FROM ultimo_humano u
   WHERE c.id = p_conversation_id
     AND (c.assigned_agent_id = '377b0c8c-c025-46ff-8088-7a929080831e'::uuid
          OR (c.assigned_agent_id IS NULL
              AND COALESCE(c.ai_autoreply_disabled, false)
              AND c.ai_handoff_reason IS NOT NULL
              AND c.ai_handoff_reason <> 'agent_replied'))
     -- La pausa manual no caduca nunca.
     AND NOT (COALESCE(c.ai_autoreply_disabled, false) AND c.ai_handoff_reason IS NULL)
     -- Alguien la atendió: hay un mensaje humano posterior a la derivación.
     AND u.en > COALESCE(c.ai_handoff_at, c.assigned_at, '-infinity'::timestamptz)
     -- Y desde entonces no hay actividad humana en N minutos.
     AND u.en < now() - make_interval(mins => v_minutos)
  RETURNING c.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_caducar_derivaciones_atendidas()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT count(*)::integer
    FROM conversations c
    CROSS JOIN LATERAL cerebro_caducar_derivacion_atendida(c.id) liberada
   WHERE c.assigned_agent_id = '377b0c8c-c025-46ff-8088-7a929080831e'::uuid
      OR (c.assigned_agent_id IS NULL
          AND c.ai_autoreply_disabled
          AND c.ai_handoff_reason IS NOT NULL
          AND c.ai_handoff_reason <> 'agent_replied');
$function$;

-- Perímetro de la 102/103: SECURITY DEFINER, nadie con sesión o clave
-- pública debe poder llamarlas.
REVOKE ALL ON FUNCTION public.cerebro_caducar_derivacion_atendida(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.cerebro_caducar_derivaciones_atendidas() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_caducar_derivacion_atendida(uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.cerebro_caducar_derivaciones_atendidas() TO service_role;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'caducar-derivaciones-atendidas';
SELECT cron.schedule(
  'caducar-derivaciones-atendidas',
  '* * * * *',
  'SELECT public.cerebro_caducar_derivaciones_atendidas()'
);
