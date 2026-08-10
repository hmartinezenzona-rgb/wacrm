-- 062 — El vigilante de chats atascados deja de avisar por despedidas
-- YA APLICADA EN PRODUCCION el 10-ago-2026. NO LA EJECUTES.
--
-- (La 060 esta reservada para la rama DELETE de trg_sync_operacion_desde_deal
--  y la 061 para el tipo de aviso `mensaje_perdido`. Esta salio antes por ser
--  ruido que el equipo estaba viendo hoy mismo.)
--
-- POR QUE
-- La 057 ya contemplaba el acuse puro ("Ok", "Gracias", "Thanks"), pero exigia
-- que el texto fuera EXACTAMENTE una de esas palabras. Las despedidas reales
-- son mas largas:
--   "Gracias a ustedes siempre eficiente besos"  -> 9 avisos
--   "Gracias a ustedes"                          -> 9 avisos
--   "Ok Gracias Amigo"                           -> 12 avisos
-- 30 de los 42 avisos `chat_atascado` eran eso. La remesa de KIRENIA se habia
-- completado a las 14:13 y ella dio las gracias a las 14:22.
--
-- LO QUE SE DESCARTO, Y POR QUE IMPORTA
-- Se probo una regla por ESTADO ("no hay operacion abierta"), que parecia mas
-- solida que mirar el texto. Medida contra los 12 casos reales fallaba en LOS
-- DOS limites: silenciaba a un cliente que estaba dando el nombre del
-- beneficiario y avisaba por un "Ok". Descartada por medicion, no por opinion.
--
-- LA REGLA, medida sobre 344 mensajes reales de cliente que siguen a uno del
-- agente: se callan 103, siguen avisando 241. Revisados los 35 textos distintos
-- que se callan: todos son cierres o compromisos del propio cliente
-- ("Ok manana le mando todo"). Ninguno espera respuesta.
--
-- Las cuatro guardas, y que hace cada una:
--   content_type='text'  una imagen o un audio NUNCA son una despedida
--   sin '?'              si pregunta algo, espera respuesta
--   sin digitos          una tarjeta, un monto o un telefono son un DATO
--   lista de pendientes  cierra el hueco de "ok pero y mi dinero", que pasaria
--                        las tres guardas anteriores
--
-- COMPROBACION (la que valida de verdad: el control con la regla vieja)
--   Con la regla vieja salian KIRENIA, Onelsi y WTZ. Con la nueva, cero.
--   Ningun otro chat cambio de lado.
--
-- REVERSION
--   Ejecutar ROLLBACK-062-avisar-chats-atascados-antes.sql

CREATE OR REPLACE FUNCTION public.cerebro_avisar_chats_atascados(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(atascados integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; v_quien text; r record;
BEGIN
  v_min     := COALESCE(p_minutos,     NULLIF(cerebro_config_get('chat_atascado_minutos'),     '')::int, 15);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('chat_atascado_repetir_min'), '')::int, 60);

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < '09:00'::time OR v_ahora_gy::time >= '17:00'::time THEN
    RETURN QUERY SELECT 0, 0; RETURN;
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
       -- CIERRE DE CORTESIA JUSTO DESPUES DE QUE UNA PERSONA CONTESTARA.
       -- Dos formas: el acuse puro de siempre, o una despedida mas larga.
       AND NOT (
             a.sender_type = 'agent'
             AND u.content_type = 'text'
             AND (
               -- 1) Acuse puro: el texto ENTERO es una de estas palabras.
               btrim(lower(coalesce(u.content_text, '')), E' \t\n.,!¡¿?:;-👍🙏😊😉✅❤️')
                   ~ ('^(|ok|oka|okay|okey|oki|vale|listo|dale|gracias|muchas gracias|'
                   || 'perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|'
                   || 'thank you|thanks|thank u|ty|got it|understood|alright|'
                   || 'sure|yes|yep|yeah|si|sí)$')
               OR
               -- 2) Despedida de cortesia: LLEVA una formula de cortesia, es
               --    corta, no pregunta nada, no trae ningun dato y no menciona
               --    nada pendiente.
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
              ELSE 'La asignacion caduca sola, pero SOLO cuando el cliente vuelve a escribir. Mientras no escriba, aqui no entra nadie: hay que atenderlo a mano o soltar el chat.' END;

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
  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

-- ---------------------------------------------------------------------------
-- FLECO CONOCIDO, MEDIDO Y DESCARTADO A PROPOSITO (10-ago)
--
-- La excepcion exige que el mensaje ANTERIOR sea del agente (`a.sender_type =
-- 'agent'`). Si el cliente manda DOS CIERRES SEGUIDOS, el segundo se escapa.
--
-- MEDIDO sobre todo el historico: de 135 mensajes de cierre del cliente, 118
-- van justo detras del agente (cubiertos). De los 16 que van detras de otro
-- mensaje del propio cliente, solo 7 venian tras otro cierre:
--
--   Clarita            "Ok"                    -> "Gracias"
--   Clarita            "Gracias"               -> "Saludos y bendiciones"
--   Josefa             "Thanks"                -> "Si"
--   AISHA LRG          "Vale"                  -> "Gracias"
--   sanzjuanpastor     "Ok"                    -> "Gracias"
--   Yoanis Coba Cedre  "Ok"                    -> "Gracias"
--   KIRENIA SAnchez    "Ok"                    -> "Gracias"
--
-- POR QUE NO SE ARREGLA
-- NINGUNO de los siete es el ultimo mensaje de su chat: en los siete contesto
-- el agente despues o el cliente siguio escribiendo. Y el vigilante SOLO mira
-- el ultimo mensaje. O sea: el fleco nunca ha producido un aviso falso. Cero.
--
-- Y el caso que lo hizo anotar NI SIQUIERA ES UN CASO DE ESTO: Yunior fue
-- "Si claro Hermano gracias" -> "Asi mismo", y "Asi mismo" no lleva ninguna
-- formula de cortesia, asi que la regla general tampoco lo atraparia. Cubrirlo
-- exigiria ir metiendo expresiones sueltas en una lista, que no tiene final.
--
-- QUE LO CAMBIARIA
-- Que aparezca un aviso `chat_atascado` cuyo ULTIMO mensaje sea un cierre.
-- Entonces si toca, y la regla ya esta pensada: en vez de mirar solo el mensaje
-- anterior, exigir que TODOS los mensajes del cliente posteriores al ultimo del
-- agente sean cierres. Se hace buscando el rn del ultimo mensaje del agente y
-- comprobando con NOT EXISTS que no hay nada mas nuevo que no sea un cierre.
