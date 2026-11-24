-- ============================================================
-- 334 — La pregunta de la entrevista la manda el sistema, no el modelo.
--
--   Antes: la nota del turno le daba al agente el TEMA de la pregunta
--   («qué vende o qué servicios da…») y el agente escribía el mensaje
--   completo. Un modelo de lenguaje, cuando le contestan algo, primero
--   acusa recibo («Sale, Saltillo y horario normal de México.») y luego
--   pregunta; la regla «no repitas lo que dijo» solo cambiaba las palabras
--   del acuse. Por eso se repetían las respuestas del cliente.
--
--   Ahora: cada pregunta lleva «texto», que es el mensaje tal cual. El
--   agente solo escribe cuando hace falta (el cliente preguntó algo, no
--   entendió o mandó un audio confuso) y el flujo pega la pregunta
--   después. Si no hay nada que aclarar, el agente responde
--   [SOLO_PREGUNTA] y el mensaje es nada más la pregunta.
--   Mismo principio que en Remesas: el código decide, la IA habla.
--
--   «pregunta» se queda como el tema (lo usan la ficha y los avisos);
--   si una pregunta no tiene «texto», el flujo cae al comportamiento
--   anterior y la escribe el agente.
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
BEGIN
  SELECT data INTO v_cfg FROM bot_entrevista WHERE account_id = p_account;
  IF v_cfg IS NULL OR jsonb_array_length(COALESCE(v_cfg->'preguntas', '[]'::jsonb)) = 0 THEN
    RETURN jsonb_build_object('hay_entrevista', false);
  END IF;

  SELECT COALESCE(d.notes, '') INTO v_notas
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
      IF v_sig IS NULL THEN
        v_sig := jsonb_build_object('tema', COALESCE(v_preg->>'etiqueta', v_preg->>'clave'),
                                    'pregunta', v_preg->>'pregunta',
                                    'texto', COALESCE(v_preg->>'texto', ''),
                                    'ayuda', COALESCE(v_preg->>'ayuda', ''));
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'hay_entrevista', true,
    'modo', v_modo,
    -- Lo que el flujo manda antes de la primera pregunta, para no empezar en seco.
    'arranque', COALESCE(v_cfg->>'arranque', ''),
    'ya_contesto', v_contest,
    'siguiente', v_sig,
    'faltan', v_faltan,
    'total', v_total,
    'completa', v_faltan = 0,
    'que_hacer', CASE
      WHEN v_modo = 'pdf' THEN 'El cliente eligió el PDF: no hagas las preguntas aquí; si manda respuestas por escrito o con audios, recíbelas.'
      WHEN v_modo = 'llamada' THEN 'El cliente eligió una llamada: no hagas las preguntas aquí.'
      WHEN v_faltan = 0 THEN COALESCE(v_cfg->>'cierre', 'Ya terminó: agradece en una frase.')
      WHEN COALESCE(v_sig->>'texto', '') <> '' THEN 'La pregunta la manda el sistema tal cual («siguiente.texto»): tú NO la escribas ni la cambies. Si el cliente solo contestó, responde exactamente [SOLO_PREGUNTA] y nada más. Si preguntó algo, no entendió o su audio no se entiende, contéstale en una o dos frases, sin preguntar nada y sin repetir lo que dijo; para explicar la pregunta usa la «ayuda». No hables de «ya_contesto».'
      ELSE 'Haz SOLO la pregunta de «siguiente», en UNA sola pregunta aunque tenga varias partes, con tus palabras y sin repetir lo que el cliente contestó. Si no la entiende, explícasela con la «ayuda». Si prefiere no contestar, sigue sin insistir. No preguntes nada de «ya_contesto».'
    END)
    || CASE WHEN p_detalle THEN jsonb_build_object('preguntas', v_cfg->'preguntas',
                                                     'modo_etiqueta', COALESCE(v_cfg->>'modo_etiqueta', 'Entrevista'))
            ELSE '{}'::jsonb END;
END;
$$;
REVOKE ALL ON FUNCTION public.bot_entrevista(UUID, UUID, BOOLEAN) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_entrevista(UUID, UUID, BOOLEAN) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
