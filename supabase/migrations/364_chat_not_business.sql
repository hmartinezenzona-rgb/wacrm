-- 364: "not business" chats and one stuck-chat alert per customer message.
--
-- Audit 2026-11-10 (production, 30 days): chat_atascado produced 226 rows for 58 (user, conversation) pairs. It ignored
-- whether the chat was business at all, re-inserted a read alert every 6 h (a new sound each time) and, for chats the bot
-- derived (assignment never expires), alerted for a customer message a month old.
--
-- What this does:
--   * conversations.not_business_at / not_business_by: a team member marks a chat "not business" (who and when). The state
--     is cleared by crm_marcar_no_negocio(conv, false) or automatically when a NEW customer message arrives (trigger on
--     messages, customer rows only). Marking it also deletes the chat's unread chat_atascado notifications (see the close trigger below).
--   * chat_atascado_avisos: the last customer message each conversation was alerted for. A conversation is alerted at most
--     once per last customer message (never re-created after it was read); a new customer message re-arms it.
--   * cerebro_avisar_chats_atascados: same liberation, business hours and courtesy filter as 323; the detection loop moves
--     unchanged into _cerebro_atascados_detectar (so it can be tested outside business hours) with three new filters:
--     not_business_at IS NULL, last customer message newer than cerebro_config chat_atascado_max_dias (default 2 days),
--     and not already alerted for that message. p_repetir_min and the *_repetir_* keys are no longer used (signature kept).
--   * Closing a chat (owner decision 2026-11-11): when a conversation is hidden (deleted_at NULL -> value, what the panel
--     does) or marked not business (not_business_at NULL -> value), an AFTER UPDATE trigger deletes its unread chat_atascado
--     notifications for every profile and records the last customer message as already alerted, so it does not re-alert.
--     Read rows and every other notification type stay. A new customer message re-arms the chat (a new message id; the
--     webhook also clears deleted_at, and the customer message clears the not-business mark).
--   * Backfill: every conversation that already has a chat_atascado alert key is marked as alerted for its current last
--     customer message, so applying this does not re-sound the current backlog.
-- Money alerts (deal_incidencia, envio_sin_beneficiario, ...) never look at the flag.
-- Guard: new columns are nullable with no default; one new table (RLS on, no policies: only definer functions touch it).
-- Rollback: ROLLBACK-364-chat-not-business.sql.

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS not_business_at timestamptz,
  ADD COLUMN IF NOT EXISTS not_business_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

CREATE TABLE IF NOT EXISTS public.chat_atascado_avisos (
  conversation_id uuid PRIMARY KEY REFERENCES public.conversations(id) ON DELETE CASCADE,
  message_id      uuid NOT NULL,
  avisado_at      timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.chat_atascado_avisos ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.chat_atascado_avisos FROM PUBLIC, anon, authenticated;

-- Backfill: current backlog counts as already alerted for the present last customer message.
INSERT INTO public.chat_atascado_avisos (conversation_id, message_id)
SELECT DISTINCT ON (cv.id) cv.id, m.id
  FROM public.cerebro_alertas a
  JOIN public.conversations cv ON a.clave = 'chat_atascado:' || cv.id::text
  JOIN public.messages m ON m.conversation_id = cv.id AND m.sender_type = 'customer'
 ORDER BY cv.id, m.created_at DESC
ON CONFLICT (conversation_id) DO NOTHING;

CREATE OR REPLACE FUNCTION public.crm_marcar_no_negocio(p_conversation_id uuid, p_no_negocio boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_conv conversations%ROWTYPE;
BEGIN
  SELECT * INTO v_conv FROM conversations WHERE id = p_conversation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'conversation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_conv.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to change this conversation' USING ERRCODE = '42501';
  END IF;

  IF coalesce(p_no_negocio, true) THEN
    UPDATE conversations
       SET not_business_at = now(), not_business_by = auth.uid()
     WHERE id = p_conversation_id
    RETURNING * INTO v_conv;
    -- Its unread stuck-chat alerts are deleted by trigger zzz_conversations_cerrar_atascado.
  ELSE
    UPDATE conversations
       SET not_business_at = NULL, not_business_by = NULL
     WHERE id = p_conversation_id
    RETURNING * INTO v_conv;
  END IF;

  RETURN jsonb_build_object('conversation_id', p_conversation_id,
                            'no_negocio', v_conv.not_business_at IS NOT NULL,
                            'not_business_at', v_conv.not_business_at,
                            'not_business_by', v_conv.not_business_by);
END $function$;

REVOKE ALL ON FUNCTION public.crm_marcar_no_negocio(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_marcar_no_negocio(uuid, boolean) TO authenticated, service_role;

-- A customer writing again reactivates the chat.
CREATE OR REPLACE FUNCTION public.cerebro_reactivar_no_negocio()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE conversations
     SET not_business_at = NULL, not_business_by = NULL
   WHERE id = NEW.conversation_id AND not_business_at IS NOT NULL;
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_reactivar_no_negocio() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zzz_messages_reactivar_no_negocio ON public.messages;
CREATE TRIGGER zzz_messages_reactivar_no_negocio
  AFTER INSERT ON public.messages
  FOR EACH ROW WHEN (NEW.sender_type = 'customer')
  EXECUTE FUNCTION public.cerebro_reactivar_no_negocio();

-- Hiding a chat or marking it not business closes its pending stuck-chat alerts.
CREATE OR REPLACE FUNCTION public.cerebro_cerrar_atascado_conversacion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  DELETE FROM notifications
   WHERE conversation_id = NEW.id AND type = 'chat_atascado' AND read_at IS NULL;
  -- Closed for the current last customer message: only a newer customer message alerts again.
  INSERT INTO chat_atascado_avisos (conversation_id, message_id)
  SELECT NEW.id, m.id FROM messages m
   WHERE m.conversation_id = NEW.id AND m.sender_type = 'customer'
   ORDER BY m.created_at DESC LIMIT 1
  ON CONFLICT (conversation_id) DO UPDATE SET message_id = EXCLUDED.message_id, avisado_at = now();
  RETURN NULL;
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_cerrar_atascado_conversacion() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS zzz_conversations_cerrar_atascado ON public.conversations;
CREATE TRIGGER zzz_conversations_cerrar_atascado
  AFTER UPDATE OF deleted_at, not_business_at ON public.conversations
  FOR EACH ROW WHEN ((OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
                  OR (OLD.not_business_at IS NULL AND NEW.not_business_at IS NOT NULL))
  EXECUTE FUNCTION public.cerebro_cerrar_atascado_conversacion();

-- Detection loop of 323 (unchanged) plus the three new filters. Returns (stuck chats found, notification rows touched).
CREATE OR REPLACE FUNCTION public._cerebro_atascados_detectar(p_minutos integer)
 RETURNS TABLE(atascados integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int := p_minutos;
  v_max_dias int;
  v_caduca int;
  v_n int := 0; v_avisos int := 0; v_creados int;
  v_espera text; v_quien text; r record;
BEGIN
  v_max_dias := COALESCE(NULLIF(cerebro_config_get('chat_atascado_max_dias'), '')::int, 2);
  v_caduca   := COALESCE(NULLIF(cerebro_config_get('asignacion_caduca_minutos'), '')::int, 10);

  FOR r IN
    WITH ult2 AS (
      SELECT m.id AS message_id, m.conversation_id, m.sender_type, m.created_at, m.content_text, m.content_type,
             row_number() OVER (PARTITION BY m.conversation_id ORDER BY m.created_at DESC) AS rn
        FROM messages m JOIN conversations cv ON cv.id = m.conversation_id
       WHERE cv.assigned_agent_id IS NOT NULL AND cv.deleted_at IS NULL
    ),
    ultimo AS (SELECT * FROM ult2 WHERE rn = 1),
    anterior AS (SELECT * FROM ult2 WHERE rn = 2)
    SELECT v.id, v.account_id, v.contact_id, u.created_at AS espera_desde, u.message_id,
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
       -- (364) A customer message older than the cutoff is history, not an emergency.
       AND u.created_at > now() - make_interval(days => v_max_dias)
       -- (364) A team member said this chat is not business.
       AND v.not_business_at IS NULL
       -- (308) Nothing to answer: a courtesy last message (ok, thanks, an emoji) does not alert.
       AND NOT cerebro_es_cortesia(u.content_text, u.content_type)
       -- (364) One alert per customer message, never re-created after it was read.
       AND NOT EXISTS (SELECT 1 FROM chat_atascado_avisos ca
                        WHERE ca.conversation_id = v.id AND ca.message_id = u.message_id)
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

    v_creados := cerebro_avisar_atascado_fila(
      r.account_id, r.id, r.contact_id,
      COALESCE(NULLIF(r.name, ''), r.phone) || ' lleva ' || v_espera || ' esperando',
      'Escribio hace ' || v_espera || ' y no le ha contestado nadie, ni una persona ni el bot. ' || v_quien
        || ' Si no es un chat del negocio, marquelo como "No es del negocio" en la conversacion.');
    v_avisos := v_avisos + v_creados;

    INSERT INTO chat_atascado_avisos (conversation_id, message_id)
    VALUES (r.id, r.message_id)
    ON CONFLICT (conversation_id) DO UPDATE SET message_id = EXCLUDED.message_id, avisado_at = now();
  END LOOP;
  RETURN QUERY SELECT v_n, v_avisos;
END $function$;

REVOKE ALL ON FUNCTION public._cerebro_atascados_detectar(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._cerebro_atascados_detectar(integer) TO service_role;

CREATE OR REPLACE FUNCTION public.cerebro_avisar_chats_atascados(p_minutos integer DEFAULT NULL::integer, p_repetir_min integer DEFAULT NULL::integer)
 RETURNS TABLE(liberadas integer, atascados integer, avisos_creados integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_min int; v_ahora_gy timestamp;
  v_n int := 0; v_avisos int := 0; v_liberadas int := 0;
  v_caduca int;
BEGIN
  v_min     := COALESCE(p_minutos, NULLIF(cerebro_config_get('chat_atascado_minutos'), '')::int, 15);
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

  SELECT d.atascados, d.avisos_creados INTO v_n, v_avisos FROM _cerebro_atascados_detectar(v_min) d;
  RETURN QUERY SELECT v_liberadas, v_n, v_avisos;
END;
$function$;
