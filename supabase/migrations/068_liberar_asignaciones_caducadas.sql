-- ============================================================
-- 068 — Liberacion PROACTIVA de asignaciones manuales caducadas
-- ============================================================
-- YA APLICADA EN PRODUCCION el 11-ago-2026 (03:56 UTC) via MCP
-- apply_migration. NO LA EJECUTES: este fichero es el registro.
--
-- El sintoma que la motivo (lo vio Humberto): chats que un admin asigno,
-- dejo de atender y se quedaban "pegados" asignados en el CRM durante
-- dias. La 056 SI funcionaba, pero era perezosa: liberaba la asignacion
-- caducada solo cuando ESE cliente volvia a escribir (y en esa misma
-- pasada el bot respondia — se verifico con datos que NINGUN cliente
-- llego a escribir a un chat caducado y quedarse sin respuesta). Lo que
-- no habia era liberacion proactiva: 11 chats se veian asignados, alguno
-- desde el dia 5, y en el CRM parecia que el arreglo no existia.
--
-- Ahora cerebro_avisar_chats_atascados() (vigilante 0nEQnuPE15UgRudW,
-- cada 5 min) libera ADEMAS las asignaciones manuales caducadas, sin
-- esperar al cliente, con la MISMA condicion del CTE caducar de la 056
-- (bot 377b0c8c... nunca caduca; GREATEST(assigned_at, ultimo mensaje
-- humano) contra asignacion_caduca_minutos; assigned_at NULL de las
-- asignaciones pre-056 cuenta como -infinity). La liberacion corre antes
-- del filtro de horario (vale las 24 h); los avisos siguen L-S 9-17.
-- Cambia el RETURNS TABLE (añade `liberadas`): DROP + CREATE atomico.
--
-- Primera pasada real (11-ago ~04:00 UTC): libero los 11 manuales
-- caducados; quedaron solo las 3 derivaciones del bot. Rollback:
-- ROLLBACK-068-avisar-chats-atascados-antes.sql.

DROP FUNCTION public.cerebro_avisar_chats_atascados(integer, integer);

-- (cuerpo identico al aplicado; la fuente de verdad es la definicion viva,
--  consultable con pg_get_functiondef)

CREATE FUNCTION public.cerebro_avisar_chats_atascados(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(liberadas integer, atascados integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_creados int; v_liberadas int := 0;
  v_caduca int;
  v_espera text; v_quien text; r record;
BEGIN
  v_min     := COALESCE(p_minutos,     NULLIF(cerebro_config_get('chat_atascado_minutos'),     '')::int, 15);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('chat_atascado_repetir_min'), '')::int, 60);
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
     OR v_ahora_gy::time < '09:00'::time OR v_ahora_gy::time >= '17:00'::time THEN
    RETURN QUERY SELECT v_liberadas, 0, 0; RETURN;
  END IF;

  -- (resto identico a la version de la 062 salvo el texto del aviso para
  --  chats manuales, actualizado porque la liberacion ya es proactiva;
  --  ver ROLLBACK-068-avisar-chats-atascados-antes.sql para el diff)
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
       AND NOT (
             a.sender_type = 'agent'
             AND u.content_type = 'text'
             AND (
               btrim(lower(coalesce(u.content_text, '')), E' \t\n.,!¡¿?:;-👍🙏😊😉✅❤️')
                   ~ ('^(|ok|oka|okay|okey|oki|vale|listo|dale|gracias|muchas gracias|'
                   || 'perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|'
                   || 'thank you|thanks|thank u|ty|got it|understood|alright|'
                   || 'sure|yes|yep|yeah|si|sí)$')
               OR
               ( length(btrim(coalesce(u.content_text, ''))) <= 60
                 AND u.content_text !~ '\?'
                 AND u.content_text !~ '[0-9]'
                 AND lower(u.content_text) ~ '(gracias|thank|okay|okey|^ok\M|vale|perfecto|listo|bendicion|saludos|besos)'
                 AND lower(u.content_text) !~ '(cuando|cuándo|todavia|todavía|aun|aún|falta|esper|pendiente|dinero|plata|transferencia|demora|tarda|no me|no ha|no lle)'
               )
             )
           )
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_alertas a2
              WHERE a2.clave = 'chat_atascado:' || v.id::text
                AND a2.ultimo > now() - make_interval(mins => v_repetir))
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

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'chat_atascado', r.id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ' lleva ' || v_espera || ' esperando',
           'Escribio hace ' || v_espera || ' y no le ha contestado nadie, ni una persona ni el bot. ' || v_quien
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('chat_atascado:' || r.id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;
  RETURN QUERY SELECT v_liberadas, v_n, v_avisos;
END;
$function$;

