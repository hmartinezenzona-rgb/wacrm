-- ============================================================
-- 335 — Entrevista V3: metas y barreras.
--
--   La 334 hizo que el sistema escribiera la pregunta tal cual; se fue el
--   eco, pero el bot quedó como formulario (no deja que el cliente se
--   explaye ni repregunta). Ahora el código lleva la LISTA de temas y el
--   TOPE, y el modelo lleva la plática:
--   - «pendientes»: todos los temas que faltan (tema, pregunta, texto de
--     ejemplo y ayuda), para que el modelo siga el hilo del cliente y no
--     un orden fijo. «siguiente» sigue siendo el sugerido.
--   - «turnos»: mensajes del asesor desde que se abrió la tarjeta. Al llegar
--     al tope («tope_turnos» en bot_entrevista, 14 si no hay) la entrevista
--     se da por completa con lo que haya: así no se repite una entrevista
--     de una hora. Faltando 3 turnos se avisa para no repreguntar.
--   - «que_hacer» en chat: platicar, no llenar un formulario (ver texto).
-- ============================================================
CREATE OR REPLACE FUNCTION public.bot_entrevista(
  p_account UUID, p_conversation UUID, p_detalle BOOLEAN DEFAULT false)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_cfg        JSONB;
  v_notas      TEXT := '';
  v_resp       JSONB := '{}'::jsonb;   -- clave -> respuesta
  v_preg       JSONB;
  v_cond       JSONB;
  v_valor      TEXT;
  v_linea      TEXT;
  v_activa     BOOLEAN;
  v_modo       TEXT;
  v_contest    JSONB := '[]'::jsonb;
  v_sig        JSONB := NULL;
  v_faltan     INT := 0;
  v_total      INT := 0;
  v_pend       JSONB := '[]'::jsonb;
  v_deal_desde TIMESTAMPTZ;
  v_turnos     INT := 0;
  v_tope       INT;
  v_completa   BOOLEAN;
BEGIN
  SELECT data INTO v_cfg FROM bot_entrevista WHERE account_id = p_account;
  IF v_cfg IS NULL OR jsonb_array_length(COALESCE(v_cfg->'preguntas', '[]'::jsonb)) = 0 THEN
    RETURN jsonb_build_object('hay_entrevista', false);
  END IF;

  SELECT COALESCE(d.notes, ''), d.created_at INTO v_notas, v_deal_desde
    FROM conversations v
    JOIN contacts c ON c.id = v.contact_id
    LEFT JOIN LATERAL (
      SELECT d.* FROM deals d
       WHERE d.account_id = p_account AND d.contact_id = c.id AND d.status <> 'lost'
       ORDER BY (d.status = 'open') DESC, d.created_at DESC LIMIT 1) d ON true
   WHERE v.id = p_conversation AND v.account_id = p_account;
  v_notas := COALESCE(v_notas, '');

  -- Respuestas que ya están en la ficha, por etiqueta.
  FOR v_preg IN SELECT value FROM jsonb_array_elements(v_cfg->'preguntas') LOOP
    v_valor := '';
    FOREACH v_linea IN ARRAY string_to_array(v_notas, E'\n') LOOP
      IF lower(v_linea) LIKE lower(COALESCE(v_preg->>'etiqueta', v_preg->>'clave')) || ':%' THEN
        v_valor := btrim(substr(v_linea, position(':' IN v_linea) + 1));
      END IF;
    END LOOP;
    IF v_valor <> '' THEN v_resp := v_resp || jsonb_build_object(v_preg->>'clave', v_valor); END IF;
  END LOOP;

  -- Cómo eligió conocernos: chat, pdf o llamada.
  v_modo := '';
  FOREACH v_linea IN ARRAY string_to_array(v_notas, E'\n') LOOP
    IF lower(v_linea) LIKE lower(COALESCE(v_cfg->>'modo_etiqueta', 'Entrevista')) || ':%' THEN
      v_modo := lower(btrim(substr(v_linea, position(':' IN v_linea) + 1)));
    END IF;
  END LOOP;

  FOR v_preg IN SELECT value FROM jsonb_array_elements(v_cfg->'preguntas') LOOP
    v_activa := true;
    FOR v_cond IN SELECT value FROM jsonb_array_elements(COALESCE(v_preg->'si', '[]'::jsonb)) LOOP
      v_valor := lower(COALESCE(v_resp->>(v_cond->>'clave'), ''));
      IF v_cond ? 'en' THEN
        v_activa := v_activa AND EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_cond->'en') x WHERE lower(x) = v_valor);
      ELSIF v_cond ? 'contiene' THEN
        v_activa := v_activa AND v_valor LIKE '%' || lower(v_cond->>'contiene') || '%';
      ELSE
        v_activa := v_activa AND v_valor <> '';
      END IF;
    END LOOP;
    CONTINUE WHEN NOT v_activa;
    v_total := v_total + 1;
    IF v_resp ? (v_preg->>'clave') THEN
      v_contest := v_contest || jsonb_build_array(jsonb_build_object(
        'tema', COALESCE(v_preg->>'etiqueta', v_preg->>'clave'), 'respuesta', v_resp->>(v_preg->>'clave')));
    ELSE
      v_faltan := v_faltan + 1;
      v_pend := v_pend || jsonb_build_array(jsonb_build_object(
        'tema', COALESCE(v_preg->>'etiqueta', v_preg->>'clave'),
        'pregunta', v_preg->>'pregunta',
        'texto', COALESCE(v_preg->>'texto', ''),
        'ayuda', COALESCE(v_preg->>'ayuda', '')));
      IF v_sig IS NULL THEN
        v_sig := jsonb_build_object('tema', COALESCE(v_preg->>'etiqueta', v_preg->>'clave'),
                                    'pregunta', v_preg->>'pregunta',
                                    'texto', COALESCE(v_preg->>'texto', ''),
                                    'ayuda', COALESCE(v_preg->>'ayuda', ''));
      END IF;
    END IF;
  END LOOP;

  -- Tope: mensajes del asesor desde que se abrió la tarjeta.
  v_tope := COALESCE(NULLIF(v_cfg->>'tope_turnos', '')::int, 14);
  IF v_deal_desde IS NOT NULL THEN
    SELECT count(*) INTO v_turnos FROM messages m
     WHERE m.conversation_id = p_conversation AND m.sender_type = 'agent'
       AND m.created_at >= v_deal_desde;
  END IF;
  v_completa := v_faltan = 0 OR (v_modo = 'chat' AND v_turnos >= v_tope);

  RETURN jsonb_build_object(
    'hay_entrevista', true,
    'modo', v_modo,
    -- Lo que el flujo manda antes de la primera pregunta, para no empezar en seco.
    'arranque', COALESCE(v_cfg->>'arranque', ''),
    'ya_contesto', v_contest,
    'siguiente', v_sig,
    'pendientes', v_pend,
    'turnos', v_turnos,
    'tope', v_tope,
    'por_tope', v_faltan > 0 AND v_completa,
    'faltan', v_faltan,
    'total', v_total,
    'completa', v_completa,
    'que_hacer', CASE
      WHEN v_modo = 'pdf' THEN 'El cliente eligió el PDF: no hagas las preguntas aquí; si manda respuestas por escrito o con audios, recíbelas.'
      WHEN v_modo = 'llamada' THEN 'El cliente eligió una llamada: no hagas las preguntas aquí.'
      WHEN v_completa THEN COALESCE(v_cfg->>'cierre', 'Ya terminó: agradece en una frase.')
      ELSE 'Platica la entrevista, no la llenes como formulario. Te faltan los temas de «pendientes»; el sugerido es «siguiente», pero si el cliente ya está hablando de otro tema de la lista, síguele el hilo. UNA pregunta por mensaje, abierta (¿me cuenta cómo…?, ¿cómo le hace cuando…?). Si contestó muy corto o vago algo importante, puedes repreguntar UNA vez ese tema; si no, pasa a otro. Antes de preguntar puedes acusar recibo corto y variado o reaccionar con algo que aporte (por ejemplo, señalarle una oportunidad con sus propios números), pero nunca resumas ni repitas lo que acaba de decir. Si no entiende, explícale con la «ayuda». No preguntes nada de «ya_contesto».'
        || CASE WHEN v_turnos >= v_tope - 3 THEN ' Ya casi se acaba el tiempo de la entrevista: no repreguntes; pregunta solo lo más importante que falte.' ELSE '' END
    END)
    || CASE WHEN p_detalle THEN jsonb_build_object('preguntas', v_cfg->'preguntas',
                                                     'modo_etiqueta', COALESCE(v_cfg->>'modo_etiqueta', 'Entrevista'))
            ELSE '{}'::jsonb END;
END;
$$;
REVOKE ALL ON FUNCTION public.bot_entrevista(UUID, UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_entrevista(UUID, UUID, BOOLEAN) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
