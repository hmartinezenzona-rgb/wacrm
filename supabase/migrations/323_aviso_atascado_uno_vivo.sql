-- =====================================================================
-- 323 -- Chats atascados: one live alert per conversation
--
-- 308 already cut the noise (30 minutes, 6-hour repeat, no courtesy alerts),
-- but every repeat still inserted another row: 90 notifications in a week for
-- 9 conversations, and the one that matters drowns.
--
-- Now an UNREAD alert for that chat is refreshed (bumped to the top, body
-- updated); a READ one is replaced by a fresh alert, so an acknowledged chat
-- that is still stuck surfaces again.
--
-- The refresh-or-insert lives in `cerebro_avisar_atascado_fila` so the test
-- can drive it with a fixture, outside business hours.
--
-- Assertion: supabase/staging/assertions/aviso-atascado-uno-vivo.sql.
-- Rollback: ROLLBACK-323-aviso-atascado-uno-vivo.sql.
-- =====================================================================

-- The refresh-or-insert step on its own: the caller is guarded by business
-- hours, so a fixture-driven test can only reach it through here.
CREATE OR REPLACE FUNCTION public.cerebro_avisar_atascado_fila(
  p_account uuid,
  p_conv uuid,
  p_contact uuid,
  p_titulo text,
  p_cuerpo text
) RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $helper$
DECLARE
  v_tocadas int;
BEGIN
  WITH objetivos AS (
    SELECT p.user_id
      FROM profiles p
     WHERE p.account_id = p_account
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id)
  ), refrescados AS (
    UPDATE notifications n
       -- clock_timestamp: inside one transaction `now()` is frozen, and a second
       -- refresh in the same run would keep the old time.
       SET created_at = clock_timestamp(),
           contact_id = p_contact,
           title = p_titulo,
           body  = p_cuerpo
      FROM objetivos o
     WHERE n.user_id = o.user_id
       AND n.type = 'chat_atascado'
       AND n.conversation_id = p_conv
       AND n.read_at IS NULL
    RETURNING n.id
  ), nuevos AS (
    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT p_account, o.user_id, 'chat_atascado', p_conv, p_contact, p_titulo, p_cuerpo
      FROM objetivos o
     WHERE NOT EXISTS (
           SELECT 1 FROM notifications n
            WHERE n.user_id = o.user_id
              AND n.type = 'chat_atascado'
              AND n.conversation_id = p_conv
              AND n.read_at IS NULL)
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM refrescados) + (SELECT count(*) FROM nuevos) INTO v_tocadas;
  RETURN v_tocadas;
END;
$helper$;

REVOKE ALL ON FUNCTION public.cerebro_avisar_atascado_fila(uuid, uuid, uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cerebro_avisar_atascado_fila(uuid, uuid, uuid, text, text) TO service_role;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_chats_atascados(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(liberadas integer, atascados integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_repetir_sin_op int; v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_creados int; v_liberadas int := 0;
  v_caduca int;
  v_espera text; v_quien text; r record;
BEGIN
  v_min     := COALESCE(p_minutos,     NULLIF(cerebro_config_get('chat_atascado_minutos'),     '')::int, 15);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('chat_atascado_repetir_min'), '')::int, 60);
  v_repetir_sin_op := COALESCE(NULLIF(cerebro_config_get('chat_atascado_repetir_sin_operacion_min'), '')::int, v_repetir);
  v_caduca  := COALESCE(NULLIF(cerebro_config_get('asignacion_caduca_minutos'), '')::int, 10);

  -- LIBERACION PROACTIVA (068). Corre siempre, tambien de noche.
  UPDATE conversations c
     SET assigned_agent_id = NULL
   WHERE c.assigned_agent_id IS NOT NULL
     AND c.assigned_agent_id <> '377b0c8c-c025-46ff-8088-7a929080831e'::uuid
     AND c.deleted_at IS NULL
     AND GREATEST(
           COALESCE(c.assigned_at, '-infinity'::timestamptz),
           COALESCE((SELECT max(m.created_at) FROM messages m
                      WHERE m.conversation_id = c.id
                        AND m.sender_type = 'agent'
                        AND COALESCE(m.ai_generated, false) = false),
                    '-infinity'::timestamptz)
         ) < now() - (v_caduca * interval '1 minute');
  GET DIAGNOSTICS v_liberadas = ROW_COUNT;

  -- Horario de atencion: L-S 9:00-17:00 hora de Guyana. Domingo cerrado.
  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < (SELECT abre FROM cerebro_horario()) OR v_ahora_gy::time >= (SELECT cierra FROM cerebro_horario()) THEN
    RETURN QUERY SELECT v_liberadas, 0, 0; RETURN;
  END IF;

  FOR r IN
    WITH ult2 AS (
      SELECT m.conversation_id, m.sender_type, m.created_at, m.content_text, m.content_type,
             row_number() OVER (PARTITION BY m.conversation_id ORDER BY m.created_at DESC) AS rn
        FROM messages m JOIN conversations cv ON cv.id = m.conversation_id
       WHERE cv.assigned_agent_id IS NOT NULL AND cv.deleted_at IS NULL
    ),
    ultimo AS (SELECT * FROM ult2 WHERE rn = 1),
    anterior AS (SELECT * FROM ult2 WHERE rn = 2)
    SELECT v.id, v.account_id, v.contact_id, u.created_at AS espera_desde,
           c.name, c.phone,
           (v.assigned_agent_id = '377b0c8c-c025-46ff-8088-7a929080831e'::uuid) AS derivado_por_bot,
           COALESCE(
             (SELECT au.email FROM auth.users au WHERE au.id = v.assigned_agent_id),
             (SELECT pr.email FROM profiles  pr WHERE pr.id = v.assigned_agent_id),
             v.assigned_agent_id::text) AS responsable
      FROM ultimo u
      JOIN conversations v ON v.id = u.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      LEFT JOIN anterior a ON a.conversation_id = u.conversation_id
     WHERE u.sender_type = 'customer'
       AND u.created_at < now() - make_interval(mins => v_min)
       -- (308) Nada que responder: si el ultimo mensaje del cliente es cortesia
       -- (ok, gracias, un emoji), no se avisa aunque el anterior no fuera del agente.
       AND NOT cerebro_es_cortesia(u.content_text, u.content_type)
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_alertas a2
              WHERE a2.clave = 'chat_atascado:' || v.id::text
                AND a2.ultimo > now() - make_interval(mins =>
                      CASE WHEN EXISTS (SELECT 1 FROM remittance_operations o
                                         WHERE o.conversation_id = v.id
                                           AND o.status NOT IN ('completed','cancelled'))
                           THEN v_repetir ELSE v_repetir_sin_op END))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.espera_desde)) >= 3600
        THEN round(EXTRACT(EPOCH FROM (now() - r.espera_desde)) / 3600)::text || ' h'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.espera_desde)) / 60)::text || ' min' END;

    v_quien := 'Asignado a ' || r.responsable || '. '
      || CASE WHEN r.derivado_por_bot
              THEN 'Lo derivo el propio bot y esa asignacion NO caduca: hasta que entre una persona, ese cliente no recibe nada.'
              ELSE 'Hubo actividad humana hace menos de ' || v_caduca::text
                || ' min (por eso sigue asignado: las manuales caducan solas y se liberan cada 5 min). Aun asi el cliente espera: atiendalo o suelte el chat.' END;

    -- UN AVISO VIVO POR CONVERSACION, NO UNA FILA POR REPETICION.
    -- Repetir mientras el cliente sigue esperando es correcto (308 ya lo
    -- espació a 6 h); lo que no puede pasar es que cada repeticion deje otra
    -- fila. Medido: 90 avisos en una semana sobre 9 conversaciones.
    v_creados := cerebro_avisar_atascado_fila(
      r.account_id, r.id, r.contact_id,
      COALESCE(NULLIF(r.name, ''), r.phone) || ' lleva ' || v_espera || ' esperando',
      'Escribio hace ' || v_espera || ' y no le ha contestado nadie, ni una persona ni el bot. ' || v_quien);
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('chat_atascado:' || r.id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;
  RETURN QUERY SELECT v_liberadas, v_n, v_avisos;
END;
$function$;
