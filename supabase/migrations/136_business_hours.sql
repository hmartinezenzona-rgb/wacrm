-- =====================================================================
-- 136 — Business hours in ONE place: cerebro_config horario_abre / horario_cierra
--
-- The opening hours (Monday-Saturday 9:00-17:00 Guyana time, Sunday closed)
-- were written by hand in 5 watchers, plus per-watcher settings, plus 3 places
-- of the Cerebro (Decisor, Contexto conversacion, agent prompt). Changing the
-- hours meant editing all of them and missing one silently.
--
-- The source is now cerebro_config ('horario_abre' 09:00, 'horario_cierra'
-- 17:00), read through cerebro_horario(), which falls back to 09:00/17:00 when
-- a key is missing or empty (the ONLY place those defaults are written). The
-- Cerebro already reads cerebro_config on every turn ('Contexto conversacion'),
-- so no new query or failure point is added there.
--
-- The 5 watchers keep their own override keys (sin_beneficiario_desde,
-- envio_incompleto_hasta, perdido_hora_desde, remesas_viejas_desde, ...): only
-- their FALLBACK changes from a literal to cerebro_horario(). The per-watcher
-- rows that just repeated 09:00/17:00 (envio_incompleto_*, perdido_hora_*) are
-- emptied so they follow the global hours; their old values are in the
-- rollback. Every function body is today's body with only the fallback
-- replaced (checked by undoing the substitution: identical).
-- Behaviour is unchanged: the new keys hold today's hours.
--
-- ROLLBACK: ROLLBACK-136-business-hours.sql
-- Guarded by supabase/staging/assertions/business-hours.sql
-- =====================================================================

INSERT INTO cerebro_config (clave, valor, descripcion, actualizado) VALUES
  ('horario_abre', '09:00', 'Hora de apertura (Guyana), lunes a sabado. Fuente unica del horario (136): la leen el Cerebro y los vigilantes.', now()),
  ('horario_cierra', '17:00', 'Hora de cierre (Guyana), lunes a sabado; domingo cerrado. Fuente unica del horario (136).', now())
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION cerebro_horario()
RETURNS TABLE(abre time, cierra time)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(NULLIF(cerebro_config_get('horario_abre'), '')::time, '09:00'::time),
         COALESCE(NULLIF(cerebro_config_get('horario_cierra'), '')::time, '17:00'::time)
$$;

COMMENT ON FUNCTION cerebro_horario() IS
  '136. Business hours (Guyana time) from cerebro_config horario_abre / horario_cierra; defaults 09:00 / 17:00.';
REVOKE EXECUTE ON FUNCTION cerebro_horario() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cerebro_horario() TO service_role;

-- Per-watcher rows that only repeated the global hours now follow them.
UPDATE cerebro_config SET valor = '', actualizado = now()
 WHERE (clave, valor) IN (('envio_incompleto_desde', '09:00'), ('envio_incompleto_hasta', '17:00'),
                          ('perdido_hora_desde', '9'), ('perdido_hora_hasta', '17'));

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
       AND NOT (
             a.sender_type = 'agent'
             AND cerebro_es_cortesia(u.content_text, u.content_type)
           )
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

CREATE OR REPLACE FUNCTION public.cerebro_avisar_envios_incompletos(p_horas integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(incompletos integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_horas int; v_repetir int; v_ahora_gy timestamp;
  v_desde time; v_hasta time;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_horas   := COALESCE(p_horas,       NULLIF(cerebro_config_get('envio_incompleto_horas'), '')::int, 4);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('envio_incompleto_repetir_min'), '')::int, 120);
  -- La ventana sale de cerebro_config y no del codigo: asi se puede ajustar sin
  -- desplegar, y asi se puede PROBAR la funcion entera fuera de horario, que es
  -- justo cuando se despliega. Los otros vigilantes la llevan a fuego y por eso
  -- su rama de aviso solo se ve funcionar al dia siguiente.
  v_desde := COALESCE(NULLIF(cerebro_config_get('envio_incompleto_desde'), '')::time, (SELECT abre FROM cerebro_horario()));
  v_hasta := COALESCE(NULLIF(cerebro_config_get('envio_incompleto_hasta'), '')::time, (SELECT cierra FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < v_desde OR v_ahora_gy::time >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT d.id, d.account_id, d.contact_id, d.conversation_id,
           s.objetivo, s.depositado, s.saldo, s.moneda, o.pedido, c.name, c.phone,
           (SELECT max(m.consumido_en) FROM depositos_mmg m
             WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) AS ultimo_deposito
      FROM deals d
      JOIN conversations v ON v.id = d.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      LEFT JOIN cerebro_objetivo_envio o ON o.conversation_id = d.conversation_id
      CROSS JOIN LATERAL cerebro_saldo_envio(d.id) s
     WHERE d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.status = 'open'
       AND d.stage_id = '3cf01654-cd27-47c1-ac92-62abf5435751'
       AND s.saldo > 0
       AND COALESCE(
             (SELECT max(m.consumido_en) FROM depositos_mmg m
               WHERE m.deal_id = d.id AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL),
             d.created_at) < now() - make_interval(hours => v_horas)
       AND NOT EXISTS (
             SELECT 1 FROM cerebro_alertas a
              WHERE a.clave = 'envio_incompleto:' || d.id::text
                AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - COALESCE(r.ultimo_deposito, now()))) >= 86400
        THEN round(EXTRACT(EPOCH FROM (now() - r.ultimo_deposito)) / 86400)::text || ' dias'
      ELSE round(EXTRACT(EPOCH FROM (now() - COALESCE(r.ultimo_deposito, now()))) / 3600)::text || ' h' END;

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'envio_incompleto', r.conversation_id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ': faltan '
             || rtrim(trim(to_char(r.saldo, 'FM999,999,999,990.99')), '.') || ' ' || r.moneda
             || ' y lleva ' || v_espera || ' sin depositar mas',
           'Dijo que iba a enviar ' || COALESCE(r.pedido,
                 rtrim(trim(to_char(r.objetivo, 'FM999,999,999,990.99')), '.') || ' ' || r.moneda)
             || ' y lleva depositados '
             || rtrim(trim(to_char(r.depositado, 'FM999,999,999,990.99')), '.') || ' ' || r.moneda
             || '. FALTAN ' || rtrim(trim(to_char(r.saldo, 'FM999,999,999,990.99')), '.')
             || '. Ese dinero YA esta verificado contra el libro y consumido, pero el envio se '
             || 'queda en Por verificar y NO se transfiere hasta que complete. '
             || 'Si ya no va a completar, hay que decidir a mano que se hace con lo depositado.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('envio_incompleto:' || r.id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_envios_sin_beneficiario(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(sin_destino integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_silencio int;
  v_ahora_gy timestamp; v_desde time; v_hasta time;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_min      := COALESCE(p_minutos,     NULLIF(cerebro_config_get('sin_beneficiario_min'), '')::int, 30);
  v_repetir  := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('sin_beneficiario_repetir_min'), '')::int, 120);
  v_silencio := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_silencio_humano_min'), '')::int, 20);
  v_desde    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_desde'), '')::time, (SELECT abre FROM cerebro_horario()));
  v_hasta    := COALESCE(NULLIF(cerebro_config_get('sin_beneficiario_hasta'), '')::time, (SELECT cierra FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF EXTRACT(DOW FROM v_ahora_gy) = 0
     OR v_ahora_gy::time < v_desde OR v_ahora_gy::time >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  FOR r IN
    SELECT d.id, d.account_id, d.contact_id, d.conversation_id,
           d.value, d.currency, s.name AS etapa, c.name, c.phone,
           dep.dinero_dentro
      FROM deals d
      JOIN pipeline_stages s ON s.id = d.stage_id
      JOIN conversations v ON v.id = d.conversation_id
      JOIN contacts      c ON c.id = v.contact_id
      JOIN remittance_operations o ON o.deal_id = d.id
      CROSS JOIN LATERAL (
        SELECT max(m.consumido_en) AS dinero_dentro
          FROM depositos_mmg m
         WHERE m.deal_id = d.id
           AND m.consumido_en IS NOT NULL AND m.anulado_en IS NULL) dep
     WHERE d.pipeline_id = '78220927-0745-45a8-ba08-a1b33734dbf1'
       AND d.status = 'open'
       AND d.stage_id IN ('3cf01654-cd27-47c1-ac92-62abf5435751',
                          'f5cf87f8-b570-4d71-b6ea-a3cafd458c63')
       AND COALESCE(o.service_type, 'remesa') <> 'recarga'
       AND dep.dinero_dentro IS NOT NULL
       AND dep.dinero_dentro < now() - make_interval(mins => v_min)
       AND NOT EXISTS (SELECT 1 FROM remittance_beneficiaries b
                        WHERE b.operation_id = o.id AND b.status = 'vigente')
       AND COALESCE(d.notes, '') NOT LIKE '%BENEFICIARIO%'
       AND NOT EXISTS (SELECT 1 FROM messages m
                        WHERE m.conversation_id = d.conversation_id
                          AND m.sender_type = 'agent'
                          AND NOT COALESCE(m.ai_generated, false)
                          AND m.created_at > now() - make_interval(mins => v_silencio))
       AND NOT EXISTS (SELECT 1 FROM cerebro_alertas a
                        WHERE a.clave = 'sin_beneficiario:' || d.id::text
                          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) >= 86400
        THEN round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 86400)::text || ' dias'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.dinero_dentro)) / 3600)::text || ' h' END;

    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT r.account_id, p.user_id, 'envio_sin_beneficiario', r.conversation_id, r.contact_id,
           COALESCE(NULLIF(r.name, ''), r.phone) || ': '
             || rtrim(trim(to_char(r.value, 'FM999,999,999,990.99')), '.') || ' ' || r.currency
             || ' dentro y SIN DESTINATARIO, lleva ' || v_espera,
           'El deposito esta verificado y consumido, pero el envio NO tiene a quien '
             || 'transferirle: ni tarjeta, ni celular, ni cuenta Zelle. Esta en "'
             || r.etapa || '" y ahi se queda. '
             || 'OJO: el bot puede haberle dicho al cliente que sus datos quedaban '
             || 'anotados sin que se anotara nada - abra el chat y compruebe lo que se '
             || 'le prometio antes de escribirle. Si el cliente ya dio los datos, el '
             || 'arreglo NO es tocar remittance_beneficiaries a mano: se escribe el '
             || 'bloque BENEFICIARIO en las notas del deal y el trigger hace el resto.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('sin_beneficiario:' || r.id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_mensajes_perdidos(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(perdidos integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_repetir int; v_dias int; v_desde int; v_hasta int;
  v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; r record;
BEGIN
  v_min     := COALESCE(p_minutos,     NULLIF(cerebro_config_get('perdido_minutos'),     '')::int, 10);
  v_repetir := COALESCE(p_repetir_min, NULLIF(cerebro_config_get('perdido_repetir_min'), '')::int, 120);
  v_dias    := COALESCE(NULLIF(cerebro_config_get('perdido_retencion_dias'), '')::int, 14);
  v_desde   := COALESCE(NULLIF(cerebro_config_get('perdido_hora_desde'), '')::int, EXTRACT(hour FROM (SELECT abre FROM cerebro_horario()))::int);
  v_hasta   := COALESCE(NULLIF(cerebro_config_get('perdido_hora_hasta'), '')::int, EXTRACT(hour FROM (SELECT cierra FROM cerebro_horario()))::int);

  DELETE FROM whatsapp_webhook_log
   WHERE procesado = true AND recibido_en < now() - make_interval(days => v_dias);

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF (EXTRACT(DOW FROM v_ahora_gy) = 0 AND NOT (v_desde = 0 AND v_hasta >= 24))
     OR EXTRACT(hour FROM v_ahora_gy) < v_desde
     OR EXTRACT(hour FROM v_ahora_gy) >= v_hasta THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  -- ---- Deteccion 1: WhatsApp -> WaCRM ----
  FOR r IN
    SELECT w.remitente,
           count(*)                                    AS cuantos,
           min(w.recibido_en)                          AS primero,
           coalesce(max(w.error), 'sin detalle')       AS motivo,
           coalesce(
             (SELECT wc.account_id FROM whatsapp_config wc
               WHERE wc.phone_number_id = max(w.phone_number_id)),
             (SELECT wc2.account_id FROM whatsapp_config wc2 LIMIT 1)) AS account_id
      FROM whatsapp_webhook_log w
     WHERE w.procesado = false
       AND w.remitente IS NOT NULL
       AND w.recibido_en < now() - make_interval(mins => v_min)
       AND w.recibido_en > now() - interval '24 hours'
     GROUP BY w.remitente
    HAVING NOT EXISTS (
       SELECT 1 FROM cerebro_alertas a
        WHERE a.clave = 'mensaje_perdido:' || w.remitente
          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.primero)) >= 3600
        THEN round(EXTRACT(EPOCH FROM (now() - r.primero)) / 3600)::text || ' h'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.primero)) / 60)::text || ' min' END;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT r.account_id, p.user_id, 'mensaje_perdido',
           'Mensaje de ' || r.remitente || ' NO llego al CRM (' || r.cuantos || ')',
           'El cliente ' || r.remitente || ' escribio hace ' || v_espera ||
           ' y su mensaje NO se guardo. El ve doble tick de entregado.' ||
           chr(10) || chr(10) ||
           'Mensajes afectados: ' || r.cuantos || '. Motivo: ' || r.motivo ||
           chr(10) || chr(10) ||
           'Hay que escribirle a mano. No espera respuesta del bot: el bot nunca vio el mensaje.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('mensaje_perdido:' || r.remitente, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  -- ---- Deteccion 2 (069): WaCRM -> Cerebro ----
  FOR r IN
    SELECT c.phone AS remitente,
           count(*)           AS cuantos,
           min(m.created_at)  AS primero,
           v.account_id
      FROM messages m
      JOIN conversations v ON v.id = m.conversation_id
      JOIN contacts c      ON c.id = v.contact_id
     WHERE m.sender_type = 'customer'
       AND m.message_id IS NOT NULL
       AND m.created_at < now() - make_interval(mins => v_min)
       AND m.created_at > now() - interval '24 hours'
       AND NOT EXISTS (SELECT 1 FROM session_events se
                        WHERE se.whatsapp_message_id = m.message_id)
       -- atencion posterior de CUALQUIER agente (humano o bot) apaga el
       -- aviso: si el bot respondio despues, el canal esta vivo (070)
       AND NOT EXISTS (SELECT 1 FROM messages h
                        WHERE h.conversation_id = m.conversation_id
                          AND h.sender_type = 'agent'
                          AND h.created_at > m.created_at)
     GROUP BY c.phone, v.account_id
    HAVING NOT EXISTS (
       SELECT 1 FROM cerebro_alertas a
        WHERE a.clave = 'bot_no_recibio:' || c.phone
          AND a.ultimo > now() - make_interval(mins => v_repetir))
  LOOP
    v_n := v_n + 1;
    v_espera := CASE
      WHEN EXTRACT(EPOCH FROM (now() - r.primero)) >= 3600
        THEN round(EXTRACT(EPOCH FROM (now() - r.primero)) / 3600)::text || ' h'
      ELSE round(EXTRACT(EPOCH FROM (now() - r.primero)) / 60)::text || ' min' END;

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT r.account_id, p.user_id, 'mensaje_perdido',
           'El bot NO recibio el mensaje de ' || r.remitente || ' (' || r.cuantos || ')',
           'El mensaje SI esta en el CRM (el cliente escribio hace ' || v_espera ||
           '), pero el Cerebro nunca lo recibio: el bot no va a contestar.' ||
           chr(10) || chr(10) ||
           'Causas tipicas: firma HMAC rechazada tras un cambio de clave, el webhook' ||
           ' de WaCRM hacia n8n caido, o el flujo del Cerebro apagado.' ||
           chr(10) || chr(10) ||
           'Atienda al cliente a mano y avise a quien lleve el sistema.'
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('bot_no_recibio:' || r.remitente, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END $function$;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_remesas_abiertas_viejas(p_horas integer DEFAULT NULL::integer, p_ignorar_horario boolean DEFAULT false)
 RETURNS TABLE(viejas integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_horas    int;
  v_repetir  int;
  v_desde    time;
  v_ahora_gy timestamp;
  v_n        int := 0;
  v_avisos   int := 0;
  v_creados  int;
  r          record;
BEGIN
  v_horas   := COALESCE(p_horas, NULLIF(cerebro_config_get('remesas_viejas_horas'), '')::int, 48);
  v_repetir := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_repetir_min'), '')::int, 1200);
  v_desde   := COALESCE(NULLIF(cerebro_config_get('remesas_viejas_desde'), '')::time, (SELECT abre FROM cerebro_horario()));

  v_ahora_gy := now() AT TIME ZONE 'America/Guyana';
  IF NOT p_ignorar_horario AND (EXTRACT(DOW FROM v_ahora_gy) = 0 OR v_ahora_gy::time < v_desde) THEN
    RETURN QUERY SELECT 0, 0; RETURN;
  END IF;

  -- One summary per account.
  FOR r IN
    SELECT o.account_id, count(*)::int AS n,
           string_agg('- ' || COALESCE(NULLIF(c.name, ''), c.phone, 'cliente') || ': '
                      || CASE WHEN COALESCE(NULLIF(o.quoted_source_amount, 0), d.value, 0) > 0
                              THEN rtrim(trim(to_char(COALESCE(NULLIF(o.quoted_source_amount, 0), d.value), 'FM999,999,999,990.99')), '.') || ' GYD'
                              ELSE 'sin deposito' END
                      || ', abierta hace ' || floor(EXTRACT(EPOCH FROM (now() - o.created_at)) / 86400)::int || ' dias'
                      || COALESCE(' (' || s.name || ')', ''),
                      E'\n' ORDER BY o.created_at) AS lista
      FROM remittance_operations o
      LEFT JOIN deals d ON d.id = o.deal_id
      LEFT JOIN pipeline_stages s ON s.id = d.stage_id
      LEFT JOIN conversations v ON v.id = o.conversation_id
      LEFT JOIN contacts c ON c.id = v.contact_id
     WHERE o.status NOT IN ('completed', 'cancelled')
       AND COALESCE(o.service_type, 'remesa') <> 'recarga'
       AND o.created_at < now() - make_interval(hours => v_horas)
     GROUP BY o.account_id
  LOOP
    v_n := v_n + r.n;
    CONTINUE WHEN EXISTS (SELECT 1 FROM cerebro_alertas a
                           WHERE a.clave = 'remesas_viejas:' || r.account_id::text
                             AND a.ultimo > now() - make_interval(mins => v_repetir));

    INSERT INTO notifications (account_id, user_id, type, title, body)
    SELECT r.account_id, p.user_id, 'remesa_abierta_vieja',
           r.n || CASE WHEN r.n = 1 THEN ' remesa abierta' ELSE ' remesas abiertas' END
             || ' hace mas de ' || v_horas || ' h',
           'Si ya se pagaron, marquelas como Entregadas en el panel; si no van, cancelelas. '
             || 'Una remesa vieja abierta puede hacer que los datos de una remesa nueva del mismo '
             || 'cliente se asignen a la vieja.' || E'\n\n' || r.lista
      FROM profiles p
     WHERE p.account_id = r.account_id
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
    GET DIAGNOSTICS v_creados = ROW_COUNT;
    v_avisos := v_avisos + v_creados;

    INSERT INTO cerebro_alertas (clave, ultimo)
    VALUES ('remesas_viejas:' || r.account_id::text, now())
    ON CONFLICT (clave) DO UPDATE SET ultimo = now();
  END LOOP;

  RETURN QUERY SELECT v_n, v_avisos;
END $function$;

NOTIFY pgrst, 'reload schema';
