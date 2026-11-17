-- ============================================================
-- 318 — Bot de AP: juntar los mensajes seguidos del cliente
--
-- Idea tomada del Cerebro de Remesas Ya (debounce "¿soy el último?").
-- Un cliente suele escribir en varios mensajes cortos ("hola" / "necesito
-- válvulas" / "de 1 pulgada"). Antes el bot contestaba cada uno por separado
-- y se pisaba. Ahora:
--   1. Cada mensaje (ya pasado a texto: nota de voz transcrita, foto
--      descrita) se guarda con bot_guardar_evento.
--   2. El flujo espera unos segundos.
--   3. bot_reclamar_lote: solo la ejecución del ÚLTIMO mensaje sigue; toma
--      todos los pendientes de la conversación, en orden, y los marca
--      como procesados en el mismo paso (nadie más los vuelve a tomar).
-- También cuenta los mensajes de la última hora (freno anti-abuso).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.bot_eventos (
  id               BIGSERIAL PRIMARY KEY,
  account_id       UUID NOT NULL,
  conversation_id  UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  texto            TEXT NOT NULL,
  recibido_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  procesado_en     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS bot_eventos_pendientes
  ON public.bot_eventos (conversation_id, id) WHERE procesado_en IS NULL;
CREATE INDEX IF NOT EXISTS bot_eventos_hora
  ON public.bot_eventos (conversation_id, recibido_en);
ALTER TABLE public.bot_eventos ENABLE ROW LEVEL SECURITY;  -- solo vía las funciones

-- Guarda un mensaje ya pasado a texto. Devuelve su id y cuántos mensajes
-- lleva la conversación en la última hora.
CREATE OR REPLACE FUNCTION public.bot_guardar_evento(
  p_account UUID, p_conversation UUID, p_texto TEXT, p_recibido TIMESTAMPTZ DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_id   BIGINT;
  v_hora INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM conversations
                  WHERE id = p_conversation AND account_id = p_account) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'conversacion');
  END IF;
  IF length(trim(COALESCE(p_texto, ''))) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'vacio');
  END IF;

  INSERT INTO bot_eventos (account_id, conversation_id, texto, recibido_en)
  VALUES (p_account, p_conversation, left(trim(p_texto), 4000),
          COALESCE(LEAST(p_recibido, now()), now()))
  RETURNING id INTO v_id;

  SELECT count(*) INTO v_hora FROM bot_eventos
   WHERE conversation_id = p_conversation AND recibido_en > now() - interval '1 hour';

  RETURN jsonb_build_object('ok', true, 'id', v_id, 'mensajes_hora', v_hora);
END;
$$;

-- Llamada tras la espera. Si llegó otro mensaje después de p_id, devuelve
-- ultimo=false (esa otra ejecución contestará todo). Si no, reclama todos
-- los pendientes y los devuelve juntos, en el orden en que llegaron.
CREATE OR REPLACE FUNCTION public.bot_reclamar_lote(
  p_account UUID, p_conversation UUID, p_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_textos TEXT[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('bot_lote:' || p_conversation::text));

  IF EXISTS (SELECT 1 FROM bot_eventos
              WHERE conversation_id = p_conversation AND account_id = p_account
                AND id > p_id) THEN
    RETURN jsonb_build_object('ultimo', false);
  END IF;

  -- Si mientras esperaba una persona tomó el chat (o se pasó a humano),
  -- el bot no contesta: se descarta lo pendiente.
  IF EXISTS (SELECT 1 FROM conversations
              WHERE id = p_conversation AND ai_autoreply_disabled) THEN
    UPDATE bot_eventos SET procesado_en = now()
     WHERE conversation_id = p_conversation AND procesado_en IS NULL;
    RETURN jsonb_build_object('ultimo', false, 'pausado', true);
  END IF;

  WITH tomados AS (
    UPDATE bot_eventos SET procesado_en = now()
     WHERE conversation_id = p_conversation AND account_id = p_account
       AND procesado_en IS NULL
       AND recibido_en > now() - interval '30 minutes'
    RETURNING texto, recibido_en, id
  )
  SELECT array_agg(texto ORDER BY recibido_en, id) INTO v_textos FROM tomados;

  IF v_textos IS NULL THEN
    RETURN jsonb_build_object('ultimo', true, 'texto', '', 'mensajes', 0);
  END IF;
  RETURN jsonb_build_object('ultimo', true,
                            'texto', array_to_string(v_textos, E'\n'),
                            'mensajes', array_length(v_textos, 1));
END;
$$;

REVOKE ALL ON FUNCTION public.bot_guardar_evento(UUID, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bot_reclamar_lote(UUID, UUID, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_guardar_evento(UUID, UUID, TEXT, TIMESTAMPTZ) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bot_reclamar_lote(UUID, UUID, BIGINT) TO anon, authenticated, service_role;

-- Limpieza: lo procesado de más de 7 días no sirve.
DO $c$
BEGIN
  PERFORM cron.unschedule('ap-limpiar-bot-eventos')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ap-limpiar-bot-eventos');
  PERFORM cron.schedule('ap-limpiar-bot-eventos', '17 4 * * *',
    $q$DELETE FROM public.bot_eventos WHERE recibido_en < now() - interval '7 days'$q$);
END
$c$;
