-- ============================================================
-- 338 — Agente "mesero" para negocios de comida por encargo (Doña Miriam).
--        Va en una base que ya tiene 300/301/336 (menú y encargo_web).
--
-- Trae lo común del agente de WhatsApp (sin catálogo ni entrevista):
--   * bot_pasar_a_humano, bot_guardar_evento, bot_reclamar_lote,
--     bot_nota_interna, bot_cerrar, bot_ficha, bot_config/bot_config_leer
--     (copias de 313, 318, 321, 322 y 327). El aviso de "quiere hablar
--     contigo" va al CRM de bot_config.crm_url.
--   * bot_precios: las cifras que el bot puede decir salen del menú
--     (precio, anticipo, extras y sus sumas hasta 10 charolas).
-- Y las herramientas del mesero:
--   * bot_menu(cuenta): los próximos días de entrega con lo que lleva la
--     charola, los extras, el precio y cuántas quedan.
--   * bot_apartar(cuenta, conversación, pedido): arma las charolas con el
--     menú de ese día y aparta con encargo_web a nombre del teléfono del chat.
-- ============================================================

-- El webhook de WhatsApp no pisa un nombre que se puso a mano (como en 317).
ALTER TABLE public.contacts ADD COLUMN IF NOT EXISTS name_source TEXT;

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS humano_pedido_en   timestamptz,
  ADD COLUMN IF NOT EXISTS humano_avisado_en  timestamptz,
  ADD COLUMN IF NOT EXISTS cierre_resumen     TEXT,
  ADD COLUMN IF NOT EXISTS cierre_categoria   TEXT,
  ADD COLUMN IF NOT EXISTS cierre_sentimiento TEXT,
  ADD COLUMN IF NOT EXISTS cerrada_en         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS seguimiento_n      INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS seguimiento_en     TIMESTAMPTZ;

-- ------------------------------------------------------------
-- Configuración del agente por cuenta (igual que 322).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bot_config (
  account_id UUID PRIMARY KEY REFERENCES public.accounts(id) ON DELETE CASCADE,
  data       JSONB NOT NULL DEFAULT '{}'::jsonb,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.bot_config ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS bot_config_miembros ON public.bot_config;
CREATE POLICY bot_config_miembros ON public.bot_config
  FOR ALL TO authenticated
  USING (account_id IN (SELECT account_id FROM public.profiles WHERE user_id = auth.uid()))
  WITH CHECK (account_id IN (SELECT account_id FROM public.profiles WHERE user_id = auth.uid()));

CREATE OR REPLACE FUNCTION public.bot_config_leer(p_account UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT COALESCE((SELECT data FROM bot_config WHERE account_id = p_account), '{}'::jsonb);
$$;
REVOKE ALL ON FUNCTION public.bot_config_leer(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_config_leer(UUID) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Pasar a una persona (313, con la URL del CRM en bot_config).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_pasar_a_humano(p_account uuid, p_conversation uuid, p_motivo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions' AS $$
DECLARE
  v_motivo text := left(btrim(COALESCE(p_motivo, '')), 300);
  v_id uuid;
  v_crm text := (SELECT data->>'crm_url' FROM bot_config WHERE account_id = p_account);
BEGIN
  UPDATE conversations
     SET ai_autoreply_disabled = true, ai_handoff_summary = NULLIF(v_motivo, ''),
         humano_pedido_en = now(), humano_avisado_en = NULL
   WHERE id = p_conversation AND account_id = p_account
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'conversacion_no_encontrada');
  END IF;
  IF COALESCE(v_crm, '') <> '' THEN
    BEGIN
      PERFORM net.http_post(
        url := rtrim(v_crm, '/') || '/api/avisos/evento',
        body := jsonb_build_object('tipo', 'humano', 'conversation_id', v_id),
        headers := '{"Content-Type": "application/json"}'::jsonb);
    EXCEPTION WHEN others THEN NULL;
    END;
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION public.bot_pasar_a_humano(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_pasar_a_humano(uuid, uuid, text) TO anon, authenticated;

-- ------------------------------------------------------------
-- Juntar mensajes seguidos (318).
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.bot_eventos (
  id               BIGSERIAL PRIMARY KEY,
  account_id       UUID NOT NULL,
  conversation_id  UUID NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
  texto            TEXT NOT NULL,
  recibido_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
  procesado_en     TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS bot_eventos_pendientes ON public.bot_eventos (conversation_id, id) WHERE procesado_en IS NULL;
CREATE INDEX IF NOT EXISTS bot_eventos_hora ON public.bot_eventos (conversation_id, recibido_en);
ALTER TABLE public.bot_eventos ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.bot_guardar_evento(
  p_account UUID, p_conversation UUID, p_texto TEXT, p_recibido TIMESTAMPTZ DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_id BIGINT; v_hora INT;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM conversations WHERE id = p_conversation AND account_id = p_account) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'conversacion');
  END IF;
  IF length(trim(COALESCE(p_texto, ''))) = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'vacio');
  END IF;
  INSERT INTO bot_eventos (account_id, conversation_id, texto, recibido_en)
  VALUES (p_account, p_conversation, left(trim(p_texto), 4000), COALESCE(LEAST(p_recibido, now()), now()))
  RETURNING id INTO v_id;
  SELECT count(*) INTO v_hora FROM bot_eventos
   WHERE conversation_id = p_conversation AND recibido_en > now() - interval '1 hour';
  RETURN jsonb_build_object('ok', true, 'id', v_id, 'mensajes_hora', v_hora);
END;
$$;

CREATE OR REPLACE FUNCTION public.bot_reclamar_lote(p_account UUID, p_conversation UUID, p_id BIGINT)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_textos TEXT[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('bot_lote:' || p_conversation::text));
  IF EXISTS (SELECT 1 FROM bot_eventos WHERE conversation_id = p_conversation AND account_id = p_account AND id > p_id) THEN
    RETURN jsonb_build_object('ultimo', false);
  END IF;
  IF EXISTS (SELECT 1 FROM conversations WHERE id = p_conversation AND ai_autoreply_disabled) THEN
    UPDATE bot_eventos SET procesado_en = now() WHERE conversation_id = p_conversation AND procesado_en IS NULL;
    RETURN jsonb_build_object('ultimo', false, 'pausado', true);
  END IF;
  WITH tomados AS (
    UPDATE bot_eventos SET procesado_en = now()
     WHERE conversation_id = p_conversation AND account_id = p_account
       AND procesado_en IS NULL AND recibido_en > now() - interval '30 minutes'
    RETURNING texto, recibido_en, id)
  SELECT array_agg(texto ORDER BY recibido_en, id) INTO v_textos FROM tomados;
  IF v_textos IS NULL THEN
    RETURN jsonb_build_object('ultimo', true, 'texto', '', 'mensajes', 0);
  END IF;
  RETURN jsonb_build_object('ultimo', true, 'texto', array_to_string(v_textos, E'\n'), 'mensajes', array_length(v_textos, 1));
END;
$$;
REVOKE ALL ON FUNCTION public.bot_guardar_evento(UUID, UUID, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bot_reclamar_lote(UUID, UUID, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_guardar_evento(UUID, UUID, TEXT, TIMESTAMPTZ) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.bot_reclamar_lote(UUID, UUID, BIGINT) TO anon, authenticated, service_role;

DO $c$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule('limpiar-bot-eventos') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'limpiar-bot-eventos');
    PERFORM cron.schedule('limpiar-bot-eventos', '17 4 * * *',
      $q$DELETE FROM public.bot_eventos WHERE recibido_en < now() - interval '7 days'$q$);
  END IF;
END
$c$;

-- ------------------------------------------------------------
-- Notas, cierre y ficha (321, 327).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_nota_interna(p_account UUID, p_conversation UUID, p_texto TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_contact UUID; v_owner UUID; v_texto TEXT := left(btrim(COALESCE(p_texto, '')), 1500);
BEGIN
  IF v_texto = '' THEN RETURN jsonb_build_object('ok', false, 'error', 'vacia'); END IF;
  SELECT contact_id INTO v_contact FROM conversations WHERE id = p_conversation AND account_id = p_account;
  SELECT user_id INTO v_owner FROM profiles WHERE account_id = p_account AND account_role = 'owner' LIMIT 1;
  IF v_contact IS NULL OR v_owner IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'conversacion_no_encontrada');
  END IF;
  INSERT INTO contact_notes (contact_id, user_id, account_id, note_text)
  VALUES (v_contact, v_owner, p_account, 'Asistente: ' || v_texto);
  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION public.bot_nota_interna(UUID, UUID, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_nota_interna(UUID, UUID, TEXT) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bot_cerrar(p_account UUID, p_conversation UUID, p_resumen TEXT,
                                             p_categoria TEXT DEFAULT NULL, p_sentimiento TEXT DEFAULT NULL)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_cat TEXT := CASE lower(btrim(COALESCE(p_categoria, '')))
                  WHEN 'venta' THEN 'Venta' WHEN 'pago' THEN 'Pago' WHEN 'duda' THEN 'Duda'
                  WHEN 'sin respuesta' THEN 'Sin respuesta' WHEN 'spam' THEN 'Spam' ELSE 'Otro' END;
  v_sen TEXT := CASE lower(btrim(COALESCE(p_sentimiento, '')))
                  WHEN 'positivo' THEN 'Positivo' WHEN 'negativo' THEN 'Negativo' ELSE 'Neutral' END;
  v_res TEXT := left(btrim(COALESCE(p_resumen, '')), 1200);
  v_id UUID;
BEGIN
  UPDATE conversations
     SET status = 'closed', cierre_resumen = NULLIF(v_res, ''), cierre_categoria = v_cat,
         cierre_sentimiento = v_sen, cerrada_en = now()
   WHERE id = p_conversation AND account_id = p_account
  RETURNING id INTO v_id;
  IF v_id IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'conversacion_no_encontrada'); END IF;
  IF v_res <> '' AND v_cat <> 'Spam' THEN
    PERFORM public.bot_nota_interna(p_account, p_conversation,
      'Chat cerrado · ' || v_cat || ' · cliente ' || lower(v_sen) || E'\n' || v_res);
  END IF;
  RETURN jsonb_build_object('ok', true, 'categoria', v_cat, 'sentimiento', v_sen);
END;
$$;
REVOKE ALL ON FUNCTION public.bot_cerrar(UUID, UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_cerrar(UUID, UUID, TEXT, TEXT, TEXT) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bot_ficha(p_account UUID, p_conversation UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object(
    'nombre', CASE WHEN c.name_source = 'manual' THEN c.name ELSE '' END,
    'nombre_perfil', c.name,
    'negocio', COALESCE(c.company, ''),
    'correo', COALESCE(c.email, ''),
    'columna', COALESCE((SELECT s.name FROM pipeline_stages s WHERE s.id = d.stage_id), ''),
    'datos', COALESCE(d.notes, ''),
    'tiene_ficha', d.id IS NOT NULL,
    'humano', COALESCE(v.ai_autoreply_disabled, false),
    'sesion', COALESCE(floor(extract(epoch FROM v.cerrada_en))::bigint::text, ''),
    -- Encargos de este cliente (los últimos 5), para «lo mismo de la vez pasada».
    'encargos', COALESCE((
      SELECT string_agg(to_char(x.expected_close_date, 'DD/MM') || ' · ' || x.title
                        || ' · ' || COALESCE((SELECT s.name FROM pipeline_stages s WHERE s.id = x.stage_id), ''),
                        E'\n' ORDER BY x.created_at DESC)
        FROM (SELECT * FROM deals WHERE account_id = p_account AND contact_id = c.id
               ORDER BY created_at DESC LIMIT 5) x), ''),
    'ultimos', COALESCE((
      SELECT string_agg(CASE WHEN x.sender_type = 'customer' THEN 'Cliente: ' ELSE 'Asesor: ' END
                        || left(COALESCE(NULLIF(x.content_text, ''), x.transcrito, '[' || x.content_type || ']'), 600),
                        E'\n' ORDER BY x.created_at)
        FROM (SELECT m.sender_type, m.content_text, m.content_type, m.created_at,
                     (SELECT regexp_replace(e.texto, '^\(El cliente mandó una nota de voz\. Esto es lo que dice:\)\s*', '(nota de voz) ')
                        FROM bot_eventos e
                       WHERE m.sender_type = 'customer' AND COALESCE(m.content_text, '') = ''
                         AND e.conversation_id = m.conversation_id
                         AND e.recibido_en BETWEEN m.created_at - interval '5 seconds' AND m.created_at + interval '2 minutes'
                       ORDER BY e.recibido_en LIMIT 1) AS transcrito
                FROM messages m WHERE m.conversation_id = v.id
                 AND m.created_at > COALESCE(v.cerrada_en, '-infinity'::timestamptz)
               ORDER BY m.created_at DESC LIMIT 12) x), ''))
    FROM conversations v
    JOIN contacts c ON c.id = v.contact_id
    LEFT JOIN LATERAL (
      SELECT d.* FROM deals d
       WHERE d.account_id = p_account AND d.contact_id = c.id AND d.status <> 'lost'
       ORDER BY (d.status = 'open') DESC, d.created_at DESC LIMIT 1) d ON true
   WHERE v.id = p_conversation AND v.account_id = p_account;
$$;
REVOKE ALL ON FUNCTION public.bot_ficha(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ficha(UUID, UUID) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Menú de los próximos días de entrega.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_menu(p_account UUID)
RETURNS JSONB LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  c       menu_config%ROWTYPE;
  v_cfg   JSONB := _pedido_cfg(p_account);
  v_hoy   DATE := (now() AT TIME ZONE 'America/Monterrey')::date;
  v_dias  JSONB := '[]'::jsonb;
  v_f     DATE;
  v_dow   INT;
  v_k     INT := 0;
  v_partes JSONB;
  v_extras JSONB;
  v_ocup  INT;
  v_completo BOOLEAN;
  v_g     JSONB;
  v_it    RECORD;
  v_nom_dia TEXT[] := ARRAY['domingo','lunes','martes','miércoles','jueves','viernes','sábado'];
  v_nom_mes TEXT[] := ARRAY['enero','febrero','marzo','abril','mayo','junio','julio','agosto','septiembre','octubre','noviembre','diciembre'];
BEGIN
  SELECT * INTO c FROM menu_config WHERE account_id = p_account;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok', false, 'error', 'sin_menu'); END IF;

  WHILE jsonb_array_length(v_dias) < 6 AND v_k < 21 LOOP
    v_f := v_hoy + COALESCE(c.dias_antes, 1) + v_k;
    v_k := v_k + 1;
    v_dow := extract(dow FROM v_f)::int;
    CONTINUE WHEN NOT (v_dow = ANY (COALESCE(c.dias_entrega, ARRAY[1,2,3,4,5,6])));
    CONTINUE WHEN v_f = ANY (COALESCE(c.fechas_cerradas, ARRAY[]::date[]));

    v_partes := '[]'::jsonb; v_extras := '[]'::jsonb; v_completo := true;
    FOR v_g IN SELECT * FROM jsonb_array_elements(v_cfg->'grupos') LOOP
      IF v_g->>'tipo' = 'extra' THEN
        FOR v_it IN SELECT i.nombre, i.precio FROM menu_items i
                     WHERE i.account_id = p_account AND i.grupo = v_g->>'id' AND i.disponible
                       AND (i.dias IS NULL OR cardinality(i.dias) = 0 OR v_dow = ANY (i.dias))
                       AND (i.agotado_hasta IS NULL OR i.agotado_hasta < v_f)
                     ORDER BY i.orden, i.nombre LOOP
          v_extras := v_extras || jsonb_build_object('nombre', v_it.nombre, 'precio', v_it.precio);
        END LOOP;
      ELSE
        SELECT i.nombre INTO v_it FROM menu_items i
         WHERE i.account_id = p_account AND i.grupo = v_g->>'id' AND i.disponible
           AND (i.dias IS NULL OR cardinality(i.dias) = 0 OR v_dow = ANY (i.dias))
           AND (i.agotado_hasta IS NULL OR i.agotado_hasta < v_f)
         ORDER BY i.orden, i.nombre LIMIT 1;
        IF FOUND THEN
          v_partes := v_partes || jsonb_build_object('grupo', v_g->>'id', 'parte', v_g->>'nombre', 'nombre', v_it.nombre);
        ELSIF v_g->>'tipo' = 'uno' THEN
          v_completo := false;
        END IF;
      END IF;
    END LOOP;

    SELECT COALESCE(sum(x.charolas), 0) INTO v_ocup FROM _charolas_por_dia(p_account, v_f, v_f) x;

    v_dias := v_dias || jsonb_build_object(
      'fecha', v_f,
      'dia', v_nom_dia[v_dow + 1] || ' ' || extract(day FROM v_f)::int || ' de ' || v_nom_mes[extract(month FROM v_f)::int],
      'cuando', CASE WHEN v_f = v_hoy + 1 THEN 'mañana' WHEN v_f = v_hoy + 2 THEN 'pasado mañana' ELSE '' END,
      'hay_menu', v_completo,
      'quedan', GREATEST(c.cupo_diario - v_ocup, 0),
      'lleva', v_partes,
      'extras', v_extras);
  END LOOP;

  RETURN jsonb_build_object(
    'ok', true,
    'hoy', v_nom_dia[extract(dow FROM v_hoy)::int + 1] || ' ' || extract(day FROM v_hoy)::int || ' de ' || v_nom_mes[extract(month FROM v_hoy)::int],
    'precio', c.precio_charola, 'anticipo', c.anticipo, 'aviso', c.aviso,
    'se_encarga_con', COALESCE(c.dias_antes, 1) || ' día(s) de anticipación',
    'dias', v_dias);
END;
$$;
REVOKE ALL ON FUNCTION public.bot_menu(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_menu(UUID) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Apartar desde el chat: p = {fecha, cantidad, extras:[{nombre, cantidad}], nombre, notas}
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_apartar(p_account UUID, p_conversation UUID, p JSONB)
RETURNS JSONB LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_tel    TEXT;
  v_perfil TEXT;
  v_nombre TEXT;
  v_fecha  DATE;
  v_cant   INT;
  v_dia    JSONB;
  v_menu   JSONB := bot_menu(p_account);
  v_unidad JSONB;
  v_charolas JSONB := '[]'::jsonb;
  v_ex     JSONB;
  v_n      INT;
  v_i      INT := 0;
  v_r      JSONB;
  v_parte  JSONB;
BEGIN
  SELECT regexp_replace(COALESCE(ct.phone, ''), '\D', '', 'g'), ct.name
    INTO v_tel, v_perfil
    FROM conversations cv JOIN contacts ct ON ct.id = cv.contact_id
   WHERE cv.id = p_conversation AND cv.account_id = p_account;
  IF v_tel IS NULL THEN RETURN jsonb_build_object('ok', false, 'error', 'conversacion_no_encontrada'); END IF;

  BEGIN
    v_fecha := (p->>'fecha')::date;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fecha', 'detalle', 'usa la fecha AAAA-MM-DD que da ver_menu');
  END;
  SELECT d INTO v_dia FROM jsonb_array_elements(v_menu->'dias') d WHERE (d->>'fecha')::date = v_fecha;
  IF v_dia IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fecha', 'detalle', 'ese día no hay entrega; ofrece uno de ver_menu');
  END IF;
  IF NOT (v_dia->>'hay_menu')::boolean THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_menu_ese_dia');
  END IF;

  v_cant := LEAST(GREATEST(COALESCE(NULLIF(p->>'cantidad', '')::int, 1), 1), 20);
  v_nombre := left(btrim(COALESCE(NULLIF(p->>'nombre', ''), v_perfil, '')), 80);
  IF length(v_nombre) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nombre', 'detalle', 'pregunta a nombre de quién');
  END IF;

  FOR v_i IN 1..v_cant LOOP
    v_unidad := jsonb_build_object('qty', 1, 'extras', '[]'::jsonb);
    FOR v_parte IN SELECT * FROM jsonb_array_elements(v_dia->'lleva') LOOP
      v_unidad := v_unidad || jsonb_build_object(v_parte->>'grupo', v_parte->>'nombre');
    END LOOP;
    v_charolas := v_charolas || jsonb_build_array(v_unidad);
  END LOOP;

  -- Extras repartidos entre las charolas (1 a la 1ª, 1 a la 2ª…).
  v_i := 0;
  -- extras puede venir como lista [{nombre, cantidad}] o como texto «Ración extra de arroz:1, Ración extra de potaje:2».
  IF jsonb_typeof(p->'extras') = 'string' THEN
    p := p || jsonb_build_object('extras', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'nombre', btrim(split_part(x, ':', 1)),
               'cantidad', COALESCE(NULLIF(regexp_replace(split_part(x, ':', 2), '\D', '', 'g'), '')::int, 1)))
        FROM unnest(string_to_array(p->>'extras', ',')) x
       WHERE btrim(split_part(x, ':', 1)) <> ''), '[]'::jsonb));
  END IF;
  FOR v_ex IN SELECT * FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'extras') = 'array' THEN p->'extras' ELSE '[]'::jsonb END) LOOP
    v_n := LEAST(GREATEST(COALESCE(NULLIF(v_ex->>'cantidad', '')::int, 1), 0), 20);
    FOR k IN 1..v_n LOOP
      v_charolas := jsonb_set(v_charolas, ARRAY[(v_i % v_cant)::text, 'extras'],
                              (v_charolas->(v_i % v_cant)->'extras') || to_jsonb(v_ex->>'nombre'));
      v_i := v_i + 1;
    END LOOP;
  END LOOP;

  v_r := encargo_web(p_account, jsonb_build_object(
    'fecha', v_fecha, 'nombre', v_nombre, 'telefono', v_tel,
    'notas', left(COALESCE(p->>'notas', ''), 300),
    'folio', 'WA-' || upper(substr(md5(random()::text), 1, 6)),
    'charolas', v_charolas));

  IF (v_r->>'ok')::boolean THEN
    UPDATE deals SET notes = replace(notes, 'Pidió por la página web', 'Pidió por WhatsApp')
     WHERE id = (v_r->>'deal_id')::uuid;
    UPDATE contacts c SET name = v_nombre, name_source = 'manual'
      FROM conversations cv
     WHERE cv.id = p_conversation AND c.id = cv.contact_id AND COALESCE(c.name_source, '') <> 'manual';
    v_r := v_r || jsonb_build_object('dia', v_dia->>'dia', 'lleva', v_dia->'lleva', 'cantidad', v_cant);
  END IF;
  RETURN v_r;
END;
$$;
REVOKE ALL ON FUNCTION public.bot_apartar(UUID, UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_apartar(UUID, UUID, JSONB) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Cifras que el bot puede decir: precio, anticipo, extras y sumas.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_precios(p_account UUID)
RETURNS JSONB LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH c AS (SELECT precio_charola::int AS p, anticipo::int AS a FROM menu_config WHERE account_id = p_account),
       ex AS (SELECT DISTINCT precio::int AS e FROM menu_items WHERE account_id = p_account AND disponible AND precio > 0),
       n AS (SELECT generate_series(1, 10) AS n),
       m AS (SELECT generate_series(0, 10) AS m),
       v AS (
         SELECT (n.n * c.p + m.m * COALESCE(ex.e, 0)) AS x FROM c, n, m LEFT JOIN ex ON true
         UNION SELECT n.n * c.a FROM c, n
         UNION SELECT m.m * ex.e FROM ex, m WHERE m.m > 0)
  SELECT jsonb_build_object(
    'precios', COALESCE((SELECT jsonb_agg(DISTINCT x::text) FROM v WHERE x > 0), '[]'::jsonb),
    'aviso', (SELECT data->>'aviso_precio' FROM bot_config WHERE account_id = p_account));
$$;
REVOKE ALL ON FUNCTION public.bot_precios(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_precios(UUID) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
