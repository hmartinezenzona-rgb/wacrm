-- =====================================================================
-- 102 — La pausa que deja un envío humano caduca a los 5 minutos
--
-- EL PROBLEMA (medido en producción el 15-sep-2026)
-- Desde el 7-sep, cada envío desde el panel pausa el bot en ese chat
-- (`pauseAiOnAgentSend`, ai_handoff_reason = 'agent_replied') y la pausa no
-- caducaba nunca: solo la quitaba «Reanudar IA». Un operador escribía un
-- «Hola buenos días», se iba, y el cliente se quedaba sin bot para siempre.
-- Había 59 chats pausados así, 24 con el cliente esperando respuesta.
--
-- LA DECISIÓN (dueño, 15-sep-2026)
-- La pausa por envío humano caduca tras N minutos sin actividad humana
-- (por defecto 5). Sustituye a la decisión del 6-sep de que no caducara.
--
-- QUÉ CADUCA Y QUÉ NO
--   · Solo ai_handoff_reason = 'agent_replied'. La pausa del botón manual no
--     escribe motivo y las derivaciones del propio bot (bucle, abuso, mlc,
--     solicitud_cliente, operacion_ambigua...) llevan el suyo: ninguna pasa
--     por aquí.
--   · El reloj es el último mensaje humano o el momento de la pausa, el más
--     reciente. Los mensajes del bot (ai_generated = true) no cuentan.
--   · NO toca assigned_agent_id: la asignación tiene su propia caducidad
--     (CTE `caducar` del Cerebro, 'asignacion_caduca_minutos').
--
-- CÓMO SE USA
-- La llama el nodo `Contexto conversacion` del Cerebro en un CTE, igual que
-- cerebro_liberar_derivacion_ambigua. Libera de VERDAD (UPDATE, no un filtro)
-- para que la bandeja deje de mostrar el chat pausado y para que
-- trg_marcar_reanudacion_de_ia selle ai_resumed_at.
--
-- Actúa cuando llega un mensaje del cliente, que es cuando el bot tiene algo
-- que responder. Un chat pausado sin mensajes nuevos no se toca.
--
-- El plazo se cambia sin desplegar:
--   UPDATE cerebro_config SET valor = '10' WHERE clave = 'pausa_humana_caduca_minutos';
-- =====================================================================

INSERT INTO public.cerebro_config (clave, valor, descripcion)
VALUES (
  'pausa_humana_caduca_minutos',
  '5',
  'Minutos sin actividad humana tras los que caduca la pausa del bot que deja un envío desde el panel (agent_replied). Migración 102.'
)
ON CONFLICT (clave) DO NOTHING;

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

-- La lección de la 089: una función nueva nace con EXECUTE para PUBLIC. Esta
-- es SECURITY DEFINER y quita la pausa de cualquier conversación por id, así
-- que nadie con sesión o clave pública debe poder llamarla. n8n entra por
-- conexión Postgres directa con el rol postgres (dueño), que no lo pierde.
REVOKE ALL ON FUNCTION public.cerebro_caducar_pausa_humana(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_caducar_pausa_humana(uuid) TO service_role;
