-- ============================================================
-- 321 — Onlinefreedom: agente de ventas v2 (ideas de respond.io)
--        (edición onlinefreedom, va después de 320)
--
-- diagnostico_solicitar  ahora ACTUALIZA la ficha por etiqueta (Giro:,
--                        Reto:…) en vez de repetir todo; guarda el nombre
--                        de la persona; con dia_llamada mueve la tarjeta
--                        de «Nuevo contacto» a «Diagnóstico agendado».
-- bot_ficha              lo que ya sabemos del cliente (para no volver a
--                        preguntarlo): nombre, negocio, columna, datos.
-- bot_nota_interna       nota para Julio en la ficha del cliente
--                        (resumen, interés, siguiente paso).
-- bot_cerrar             cierra el chat con resumen, categoría y cómo se
--                        sintió el cliente; queda como nota del cliente.
-- Seguimiento            si el cliente deja una pregunta sin contestar:
--                        1 h → «¿sigues por ahí?»; 20 h → despedida y
--                        cierre. bot_seguimientos / bot_seguimiento_hecho.
-- Un mensaje nuevo del cliente reabre el chat y reinicia el seguimiento.
-- ============================================================

ALTER TABLE public.conversations
  ADD COLUMN IF NOT EXISTS cierre_resumen     TEXT,
  ADD COLUMN IF NOT EXISTS cierre_categoria   TEXT,
  ADD COLUMN IF NOT EXISTS cierre_sentimiento TEXT,
  ADD COLUMN IF NOT EXISTS cerrada_en         TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS seguimiento_n      INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS seguimiento_en     TIMESTAMPTZ;

-- ------------------------------------------------------------
-- Ficha: reemplaza líneas «Etiqueta: …» por las nuevas.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._of_fusionar_notas(p_actual TEXT, p_nuevas TEXT[])
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_lineas TEXT[] := COALESCE(string_to_array(NULLIF(p_actual, ''), E'\n'), '{}');
  v_n TEXT;
  v_et TEXT;
  i INT;
  v_hecho BOOLEAN;
BEGIN
  FOREACH v_n IN ARRAY COALESCE(p_nuevas, '{}') LOOP
    v_et := lower(split_part(v_n, ':', 1));
    v_hecho := false;
    IF v_et = 'nota' THEN
      -- Las notas se suman, salvo que ya esté la misma.
      IF NOT (v_n = ANY (v_lineas)) THEN
        v_lineas := v_lineas || v_n;
      END IF;
      CONTINUE;
    END IF;
    FOR i IN 1 .. COALESCE(array_length(v_lineas, 1), 0) LOOP
      IF lower(split_part(v_lineas[i], ':', 1)) = v_et THEN
        v_lineas[i] := v_n;
        v_hecho := true;
        EXIT;
      END IF;
    END LOOP;
    IF NOT v_hecho THEN
      -- Antes de «Llegó por …» para que quede al final.
      i := array_position(v_lineas, (SELECT l FROM unnest(v_lineas) l WHERE l ILIKE 'Llegó por %' LIMIT 1));
      IF i IS NULL THEN
        v_lineas := v_lineas || v_n;
      ELSE
        v_lineas := v_lineas[1:i-1] || v_n || v_lineas[i:];
      END IF;
    END IF;
  END LOOP;
  RETURN array_to_string(v_lineas, E'\n');
END;
$$;

CREATE OR REPLACE FUNCTION public.diagnostico_solicitar(p_account UUID, p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_nombre   TEXT := left(trim(COALESCE(p->>'nombre', '')), 80);
  v_negocio  TEXT := left(trim(COALESCE(p->>'negocio', p->>'empresa', '')), 120);
  v_giro     TEXT := left(trim(COALESCE(p->>'giro', '')), 80);
  v_ciudad   TEXT := left(trim(COALESCE(p->>'ciudad', '')), 80);
  v_tel      TEXT := regexp_replace(COALESCE(p->>'telefono', ''), '\D', '', 'g');
  v_correo   TEXT := left(trim(COALESCE(p->>'correo', '')), 120);
  v_reto     TEXT := left(trim(COALESCE(p->>'reto', '')), 500);
  v_paquete  TEXT := left(trim(COALESCE(p->>'paquete', '')), 60);
  v_presup   TEXT := left(trim(COALESCE(p->>'presupuesto', '')), 120);
  v_decide   TEXT := left(trim(COALESCE(p->>'decide', '')), 120);
  v_cuando   TEXT := left(trim(COALESCE(p->>'para_cuando', '')), 80);
  v_llamada  TEXT := left(trim(COALESCE(p->>'dia_llamada', '')), 120);
  v_notas    TEXT := left(trim(COALESCE(p->>'notas', '')), 500);
  v_folio    TEXT := left(regexp_replace(COALESCE(p->>'folio', ''), '[^A-Za-z0-9-]', '', 'g'), 20);
  v_origen   TEXT := CASE WHEN p->>'origen' = 'whatsapp' THEN 'WhatsApp' ELSE 'la página web' END;
  v_lineas   TEXT[] := '{}';
  v_recientes INT;
  v_owner    UUID;
  v_pipeline UUID;
  v_stage    UUID;
  v_agendado UUID;
  v_contact  UUID;
  v_deal     UUID;
  v_deal_stage UUID;
  v_existe   BOOLEAN := false;
  v_movida   BOOLEAN := false;
BEGIN
  IF length(v_nombre) < 2 AND length(v_negocio) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nombre');
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('diagnostico:' || p_account::text));
  SELECT count(*) INTO v_recientes FROM deals
   WHERE account_id = p_account AND created_at > now() - interval '1 hour';
  IF v_recientes >= 30 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'muchas');
  END IF;

  SELECT p2.user_id INTO v_owner FROM profiles p2
   WHERE p2.account_id = p_account AND p2.account_role = 'owner' LIMIT 1;
  SELECT pl.id INTO v_pipeline FROM pipelines pl
   WHERE pl.account_id = p_account ORDER BY (pl.name = 'Ventas') DESC, pl.created_at LIMIT 1;
  SELECT s.id INTO v_stage FROM pipeline_stages s WHERE s.pipeline_id = v_pipeline ORDER BY s.position LIMIT 1;
  SELECT s.id INTO v_agendado FROM pipeline_stages s
   WHERE s.pipeline_id = v_pipeline AND s.name ILIKE 'diagn%stico agendado%' LIMIT 1;
  IF v_owner IS NULL OR v_stage IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_tablero');
  END IF;

  IF length(v_tel) = 10 THEN v_tel := '52' || v_tel; END IF;
  IF length(v_tel) BETWEEN 11 AND 15 THEN
    SELECT id INTO v_contact FROM contacts
     WHERE account_id = p_account
       AND (phone_normalized = v_tel OR right(phone_normalized, 10) = right(v_tel, 10))
     ORDER BY (phone_normalized = v_tel) DESC, created_at
     LIMIT 1;
  END IF;
  IF v_contact IS NULL THEN
    INSERT INTO contacts (user_id, account_id, name, phone, email, company)
    VALUES (v_owner, p_account, COALESCE(NULLIF(v_nombre, ''), v_negocio),
            CASE WHEN length(v_tel) BETWEEN 11 AND 15 THEN '+' || v_tel ELSE '' END,
            NULLIF(v_correo, ''), NULLIF(v_negocio, ''))
    RETURNING id INTO v_contact;
    IF v_nombre <> '' THEN
      UPDATE contacts SET name_source = 'manual' WHERE id = v_contact;
    END IF;
  ELSE
    UPDATE contacts SET name        = COALESCE(NULLIF(v_nombre, ''), name),
                        name_source = CASE WHEN v_nombre <> '' THEN 'manual' ELSE name_source END,
                        company     = COALESCE(NULLIF(v_negocio, ''), company),
                        email       = COALESCE(NULLIF(v_correo, ''), email)
     WHERE id = v_contact;
  END IF;

  IF v_nombre  <> '' THEN v_lineas := v_lineas || ('Contacto: ' || v_nombre); END IF;
  IF v_giro    <> '' THEN v_lineas := v_lineas || ('Giro: ' || v_giro); END IF;
  IF v_ciudad  <> '' THEN v_lineas := v_lineas || ('Ciudad: ' || v_ciudad); END IF;
  IF v_reto    <> '' THEN v_lineas := v_lineas || ('Reto: ' || v_reto); END IF;
  IF v_paquete <> '' THEN v_lineas := v_lineas || ('Paquete: ' || v_paquete); END IF;
  IF v_presup  <> '' THEN v_lineas := v_lineas || ('Presupuesto: ' || v_presup); END IF;
  IF v_decide  <> '' THEN v_lineas := v_lineas || ('Decide: ' || v_decide); END IF;
  IF v_cuando  <> '' THEN v_lineas := v_lineas || ('Para cuándo: ' || v_cuando); END IF;
  IF v_llamada <> '' THEN v_lineas := v_lineas || ('Llamada: ' || v_llamada || ' (por confirmar)'); END IF;
  IF v_correo  <> '' THEN v_lineas := v_lineas || ('Correo: ' || v_correo); END IF;
  IF v_notas   <> '' THEN v_lineas := v_lineas || ('Nota: ' || v_notas); END IF;

  SELECT d.id, d.stage_id INTO v_deal, v_deal_stage FROM deals d
   WHERE d.account_id = p_account AND d.contact_id = v_contact
     AND d.pipeline_id = v_pipeline AND d.status = 'open'
   ORDER BY d.created_at DESC LIMIT 1;

  IF v_deal IS NOT NULL THEN
    v_existe := true;
    UPDATE deals
       SET notes = public._of_fusionar_notas(notes, v_lineas),
           title = CASE WHEN v_negocio <> '' AND title = COALESCE(NULLIF(v_nombre, ''), title)
                        THEN v_negocio ELSE title END
     WHERE id = v_deal;
  ELSE
    v_lineas := v_lineas || ('Llegó por ' || v_origen || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);
    INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, status)
    VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
            COALESCE(NULLIF(v_negocio, ''), v_nombre),
            0, 'MXN', array_to_string(v_lineas, E'\n'), 'open')
    RETURNING id, stage_id INTO v_deal, v_deal_stage;
  END IF;

  -- Pidió día para la llamada y sigue en la primera columna → «Diagnóstico agendado».
  IF v_llamada <> '' AND v_agendado IS NOT NULL AND v_deal_stage = v_stage THEN
    UPDATE deals SET stage_id = v_agendado WHERE id = v_deal;
    v_movida := true;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deal_id', v_deal, 'existente', v_existe,
                            'movida_a_agendado', v_movida, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.diagnostico_solicitar(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.diagnostico_solicitar(UUID, JSONB) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Lo que ya sabemos del cliente de este chat.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_ficha(p_account UUID, p_conversation UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'nombre', CASE WHEN c.name_source = 'manual' THEN c.name ELSE '' END,
    'nombre_perfil', c.name,
    'negocio', COALESCE(c.company, ''),
    'correo', COALESCE(c.email, ''),
    'columna', COALESCE((SELECT s.name FROM pipeline_stages s WHERE s.id = d.stage_id), ''),
    'datos', COALESCE(d.notes, ''),
    'tiene_ficha', d.id IS NOT NULL,
    'humano', COALESCE(v.ai_autoreply_disabled, false))
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
-- Nota interna en el cliente (la ve Julio en Clientes y en Mensajes).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_nota_interna(p_account UUID, p_conversation UUID, p_texto TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_contact UUID;
  v_owner UUID;
  v_texto TEXT := left(btrim(COALESCE(p_texto, '')), 1500);
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

-- ------------------------------------------------------------
-- Cerrar con resumen, categoría y sentimiento.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_cerrar(p_account UUID, p_conversation UUID, p_resumen TEXT,
                                             p_categoria TEXT DEFAULT NULL, p_sentimiento TEXT DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
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

-- ------------------------------------------------------------
-- El cliente vuelve a escribir: reabre y reinicia el seguimiento.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._of_cliente_escribio()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.sender_type = 'customer' THEN
    UPDATE conversations
       SET status = CASE WHEN status = 'closed' THEN 'open' ELSE status END,
           seguimiento_n = 0, seguimiento_en = NULL
     WHERE id = NEW.conversation_id AND (status = 'closed' OR seguimiento_n > 0);
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._of_cliente_escribio() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS trg_of_cliente_escribio ON public.messages;
CREATE TRIGGER trg_of_cliente_escribio AFTER INSERT ON public.messages
  FOR EACH ROW EXECUTE FUNCTION public._of_cliente_escribio();

-- ------------------------------------------------------------
-- Seguimientos pendientes. Solo chats abiertos, con el asistente
-- encendido, cuyo último mensaje es nuestro y termina en pregunta,
-- y dentro de la ventana de 24 h de WhatsApp.
--   paso 1: 1 h sin respuesta · paso 2: 20 h sin respuesta.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.bot_seguimientos(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH ult AS (
    SELECT v.id, v.seguimiento_n, c.phone,
           CASE WHEN c.name_source = 'manual' THEN split_part(c.name, ' ', 1) ELSE '' END AS nombre,
           (SELECT m.sender_type FROM messages m WHERE m.conversation_id = v.id ORDER BY m.created_at DESC LIMIT 1) AS quien,
           (SELECT m.content_text FROM messages m WHERE m.conversation_id = v.id ORDER BY m.created_at DESC LIMIT 1) AS texto,
           (SELECT max(m.created_at) FROM messages m WHERE m.conversation_id = v.id) AS ultimo_en,
           (SELECT max(m.created_at) FROM messages m WHERE m.conversation_id = v.id AND m.sender_type = 'customer') AS cliente_en
      FROM conversations v
      JOIN contacts c ON c.id = v.contact_id
     WHERE v.account_id = p_account AND v.status = 'open'
       AND NOT COALESCE(v.ai_autoreply_disabled, false) AND v.deleted_at IS NULL
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object('conversation_id', id, 'telefono', phone, 'nombre', nombre,
                                               'paso', seguimiento_n + 1)), '[]'::jsonb)
    FROM ult
   WHERE quien <> 'customer' AND btrim(COALESCE(texto, '')) ~ '\?\s*$'
     AND cliente_en > now() - interval '23 hours'
     AND ((seguimiento_n = 0 AND ultimo_en < now() - interval '1 hour')
       OR (seguimiento_n = 1 AND cliente_en < now() - interval '20 hours'));
$$;
REVOKE ALL ON FUNCTION public.bot_seguimientos(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_seguimientos(UUID) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bot_seguimiento_hecho(p_account UUID, p_conversation UUID, p_paso INT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  UPDATE conversations SET seguimiento_n = GREATEST(seguimiento_n, p_paso), seguimiento_en = now()
   WHERE id = p_conversation AND account_id = p_account;
  IF p_paso >= 2 THEN
    PERFORM public.bot_cerrar(p_account, p_conversation,
      'El cliente dejó de contestar; se le mandaron dos seguimientos.', 'sin respuesta', 'neutral');
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION public.bot_seguimiento_hecho(UUID, UUID, INT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_seguimiento_hecho(UUID, UUID, INT) TO anon, authenticated, service_role;

-- Arreglar la ficha de la prueba de Julio (quedó repetida).
UPDATE deals SET notes = public._of_fusionar_notas(
         (SELECT string_agg(l, E'\n') FROM unnest(string_to_array(notes, E'\n')) WITH ORDINALITY t(l, n)
           WHERE l ILIKE 'Llegó por %'),
         ARRAY(SELECT l FROM unnest(string_to_array(notes, E'\n')) WITH ORDINALITY t(l, n)
                WHERE l NOT ILIKE 'Llegó por %' ORDER BY n))
 WHERE notes LIKE '%OF-N350AL%';

NOTIFY pgrst, 'reload schema';
