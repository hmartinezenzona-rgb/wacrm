-- =====================================================================
-- 057 — Vigilante de chats asignados con el cliente esperando
--
--   YA APLICADA EN PRODUCCION EL 10-AGO-2026. NO LA REPITAS.
--
-- EL PROBLEMA QUE QUEDABA ABIERTO TRAS LA 056
--
--   La 056 hace que una asignacion MANUAL caduque a los 10 minutos. Pero
--   quien libera es una query del Cerebro, asi que **la caducidad solo
--   actua cuando LLEGA UN MENSAJE NUEVO**: un cliente que ya escribio y
--   esta esperando NO se rescata solo. Y las derivaciones del PROPIO BOT
--   (derivar_humano y el control de abuso, perfil 377b0c8c-…) no caducan
--   nunca, a proposito. En ninguno de los dos casos vigilaba nadie: si
--   ninguna persona abre ese chat, el cliente se queda esperando y **no
--   salta ninguna alerta**.
--
--   Este vigilante cubre ese hueco. Dispara cuando en un chat ASIGNADO el
--   ultimo mensaje es del CLIENTE y lleva mas de N minutos sin que le
--   conteste nadie —ni persona ni bot—.
--
-- POR QUE AVISA A TODO EL EQUIPO Y NO AL OPERADOR ASIGNADO
--
--   Porque no se puede. `notifications.user_id` tiene FK a
--   `auth.users(id)`, y las derivaciones del bot escriben en
--   assigned_agent_id un `profiles.id` (la incoherencia documentada en la
--   056). Insertar ese valor como user_id reventaria justo en el caso que
--   mas importa vigilar. Ademas un cliente abandonado es un problema del
--   negocio, no un recado personal: que lo vean los tres.
--
--   El responsable SI va en el cuerpo del aviso, resuelto por las dos
--   convenciones (auth.users primero, profiles despues), para que se sepa
--   a quien preguntar sin depender de cual de los dos IDs sea.
--
-- POR QUE AL CRM Y NO POR WHATSAPP
--
--   Mismo motivo que el vigilante 039: un aviso por WhatsApp que fallara
--   se realimentaria. El CRM no depende de la ventana de 24 h.
--
-- LA SALVEDAD DEL ACUSE PURO (añadida el mismo dia, tras verla fallar)
--
--   La primera version aviso de Lesa: Osmany le respondio y ella cerro
--   con un "Okay" 11 segundos despues. No habia nada que responder, y aun
--   asi el aviso iba a repetirse cada hora para siempre. Eso es justo lo
--   que entrena al equipo a ignorar la campana.
--
--   Ahora NO avisa cuando el ultimo mensaje del cliente es un acuse puro
--   ("ok", "gracias", "thank you", un 👍 suelto) Y el mensaje anterior era
--   de una persona: el operador acaba de hablar y sabe como va.
--
--   La guarda que importa es `content_type = 'text'`. Una imagen o un
--   audio NUNCA cuentan como acuse: un comprobante sin respuesta tiene
--   que seguir avisando. Verificado con los tres casos:
--     acuse puro -> 0 avisos | comprobante -> 1 | pregunta de verdad -> 1
--
-- POR QUE SOLO EN HORARIO DE ATENCION
--
--   Un aviso a las 23:00 no lo lee nadie y solo entrena al equipo a
--   ignorar la campana. Fuera de horario el chat sigue atascado y se
--   avisa al abrir, diciendo la espera REAL ("lleva 16 h"), no los 15
--   minutos del umbral.
--
-- AJUSTES SIN DESPLEGAR NADA
--   UPDATE cerebro_config SET valor='20' WHERE clave='chat_atascado_minutos';
--   UPDATE cerebro_config SET valor='120' WHERE clave='chat_atascado_repetir_min';
--
-- ROLLBACK
--   Desactivar el workflow en n8n. Sin nadie que la llame, la funcion no
--   hace nada. Para borrarlo del todo:
--     DROP FUNCTION IF EXISTS cerebro_avisar_chats_atascados(int,int);
--     DELETE FROM cerebro_alertas WHERE clave LIKE 'chat_atascado:%';
--     DELETE FROM cerebro_config WHERE clave LIKE 'chat_atascado_%';
--   (El tipo 'chat_atascado' del CHECK puede quedarse; quitarlo obliga a
--    borrar antes las notificaciones de ese tipo.)
--
-- REVISION
--   SELECT * FROM notifications WHERE type='chat_atascado'
--    ORDER BY created_at DESC;
--   SELECT clave, ultimo, now()-ultimo AS hace FROM cerebro_alertas
--    WHERE clave LIKE 'chat_atascado:%' ORDER BY ultimo DESC;
-- =====================================================================

ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE notifications ADD CONSTRAINT notifications_type_check
  CHECK (type IN ('conversation_assigned', 'deal_incidencia', 'mensaje_fallido',
                  'promo_etecsa', 'chat_atascado'));

INSERT INTO cerebro_config (clave, valor, descripcion, actualizado) VALUES
  ('chat_atascado_minutos', '15',
   'Minutos que puede llevar un cliente esperando en un chat ASIGNADO antes de '
   'que el vigilante avise en el CRM.', now()),
  ('chat_atascado_repetir_min', '60',
   'Cada cuantos minutos se repite el aviso de un mismo chat atascado. Evita '
   'una campana cada 5 minutos por el mismo caso.', now())
ON CONFLICT (clave) DO UPDATE
  SET valor = EXCLUDED.valor, descripcion = EXCLUDED.descripcion, actualizado = now();


CREATE OR REPLACE FUNCTION public.cerebro_avisar_chats_atascados(
  p_minutos     int DEFAULT NULL,   -- NULL = leer de cerebro_config
  p_repetir_min int DEFAULT NULL
)
RETURNS TABLE (atascados int, avisos_creados int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_min int; v_repetir int; v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; v_quien text; r record;
BEGIN
  v_min     := COALESCE(p_minutos,     NULLIF(cerebro_config_get('chat_atascado_minutos'),     '')::int, 15);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('chat_atascado_repetir_min'), '')::int, 60);

  -- Horario de atencion: L-S 9:00-17:00 hora de Guyana. Domingo cerrado.
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
       -- ACUSE PURO JUSTO DESPUES DE QUE UNA PERSONA CONTESTARA.
       -- El cliente cierra con "Okay", "Gracias" o un 👍 y no hay nada que
       -- responder: el operador acaba de hablar y sabe como va. Sin esta
       -- salvedad un "Okay" avisaria cada hora para siempre y el equipo
       -- aprenderia a ignorar la campana. ES y EN: en Guyana se atiende en
       -- los dos idiomas.
       -- El content_type='text' es la guarda que importa: una imagen o un
       -- audio NUNCA son un acuse. Un comprobante sin respuesta tiene que
       -- seguir avisando.
       AND NOT (
             a.sender_type = 'agent'
             AND u.content_type = 'text'
             AND btrim(lower(coalesce(u.content_text, '')), E' \t\n.,!¡¿?:;-👍🙏😊😉✅❤️')
                 ~ ('^(|ok|oka|okay|okey|oki|vale|listo|dale|gracias|muchas gracias|'
                 || 'perfecto|perfect|bien|bueno|entendido|entiendo|de acuerdo|'
                 || 'thank you|thanks|thank u|ty|got it|understood|alright|'
                 || 'sure|yes|yep|yeah|si|sí)$')
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

    -- OJO CON ESTE TEXTO: la caducidad de la 056 solo actua cuando LLEGA UN
    -- MENSAJE NUEVO. Un cliente que ya escribio y espera NO se rescata solo.
    -- Decir lo contrario aqui haria que el equipo ignorara el aviso.
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
$fn$;

GRANT EXECUTE ON FUNCTION public.cerebro_avisar_chats_atascados(int, int) TO PUBLIC;


-- =====================================================================
-- QUIEN LA LLAMA
--   Workflow de n8n `Vigilante - chats asignados sin respuesta`
--   (0nEQnuPE15UgRudW), cada 5 minutos, un solo nodo Postgres:
--       SELECT * FROM cerebro_avisar_chats_atascados();
--   Copia en ~/cerebro-fase1/Vigilante-chats-atascados.json. Queda fuera
--   de la carpeta del proyecto en n8n: mover un workflow a una carpeta
--   solo se puede arrastrandolo en la UI, no por API.
--
-- PROBADO ASI (no deja rastro: el RAISE revierte la transaccion entera,
-- incluidos los mensajes de prueba que se insertan)
--   DO $$
--   DECLARE v_conv uuid; r1 record; r2 record;
--   BEGIN
--     SELECT v.id INTO v_conv FROM conversations v
--       JOIN contacts c ON c.id=v.contact_id WHERE c.phone='<un asignado>';
--     SELECT * INTO r1 FROM cerebro_avisar_chats_atascados(15, 0);  -- 0 = sin throttle
--     INSERT INTO messages (conversation_id, sender_type, content_type,
--                           content_text, status, created_at)
--     VALUES (v_conv,'customer','image','','delivered', now() - interval '20 minutes');
--     SELECT * INTO r2 FROM cerebro_avisar_chats_atascados(15, 0);
--     RAISE EXCEPTION 'antes: %  con comprobante: %', r1.atascados, r2.atascados;
--   END $$;
--
--   Y en produccion, ejecucion 26727: 3 atascados, 9 avisos (3 chats por
--   3 personas del equipo). Segunda pasada: 0, el throttle corta.
--
-- LA PRIMERA PASADA NO SE SEMBRO, al reves que en la 039
--   Alli se sembro la tabla de deduplicacion para no disparar por 41
--   mensajes viejos. Aqui solo salian 3 casos y dos de ellos —Yunior con
--   90 h y Odessa con 43 h— eran clientes de verdad a los que nadie
--   contesto nunca. Silenciarlos habria sido esconder el hallazgo.
--   Humberto los libero a mano el mismo dia.
--
-- PARA HERMES
--   El tipo de notificacion 'chat_atascado' es nuevo. Si la UI le pone
--   icono o sonido por tipo, este no lo tiene todavia. Un chat atascado
--   es de la familia de 'deal_incidencia': alguien tiene que ir a mirarlo.
-- =====================================================================
