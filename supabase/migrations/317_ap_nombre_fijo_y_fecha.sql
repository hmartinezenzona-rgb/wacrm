-- ============================================================
-- 317 — Nombre del cliente que no se pisa + "Para cuándo" fiable (AP)
--
-- * contacts.name_source: el webhook de WhatsApp solo cambia el nombre por
--   el de perfil si name_source <> 'manual'. En esta base la columna no
--   existía, así que el siguiente mensaje del cliente devolvía el nombre a
--   su perfil ("onlinefreedom"). Ahora existe y la solicitud la marca
--   'manual' cuando el cliente dio su nombre.
-- * La fecha "Para cuándo" se calcula aquí a partir de lo que dijo el
--   cliente (sábado, mañana, 15 de diciembre…) con la fecha de hoy en
--   Monterrey. Si no se entiende, se usa la fecha que mandó el bot.
--   (El bot mandó 2024-06-08 para "el sábado" y se descartaba.)
-- ============================================================

ALTER TABLE public.contacts ADD COLUMN IF NOT EXISTS name_source TEXT;

CREATE OR REPLACE FUNCTION public._ap_fecha_de_texto(t TEXT, hoy DATE)
RETURNS DATE
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $$
DECLARE
  s     TEXT := lower(translate(COALESCE(t, ''), 'áéíóúÁÉÍÓÚ', 'aeiouaeiou'));
  dias  TEXT[] := ARRAY['domingo','lunes','martes','miercoles','jueves','viernes','sabado'];
  meses TEXT[] := ARRAY['enero','febrero','marzo','abril','mayo','junio','julio',
                        'agosto','septiembre','octubre','noviembre','diciembre'];
  i INT;
  n INT;
  v DATE;
BEGIN
  IF s = '' THEN RETURN NULL; END IF;
  IF s ~ 'pasado\s+manana' THEN RETURN hoy + 2; END IF;
  IF s ~ '\mmanana\M' THEN RETURN hoy + 1; END IF;
  IF s ~ '\mhoy\M' THEN RETURN hoy; END IF;
  -- "15 de diciembre"
  FOR i IN 1..12 LOOP
    IF s ~ ('\d{1,2}\s+de\s+' || meses[i]) THEN
      n := substring(s FROM ('(\d{1,2})\s+de\s+' || meses[i]))::INT;
      BEGIN
        v := make_date(extract(year FROM hoy)::INT, i, n);
        IF v < hoy THEN v := (v + interval '1 year')::DATE; END IF;
        RETURN v;
      EXCEPTION WHEN others THEN RETURN NULL;
      END;
    END IF;
  END LOOP;
  -- "el sábado", "para el lunes": el próximo (si hoy es ese día, el de la otra semana)
  FOR i IN 1..7 LOOP
    IF s ~ ('\m' || dias[i] || '\M') THEN
      n := ((i - 1) - extract(dow FROM hoy)::INT + 7) % 7;
      IF n = 0 THEN n := 7; END IF;
      RETURN hoy + n;
    END IF;
  END LOOP;
  IF s ~ '(proxima|siguiente)\s+semana|semana\s+que\s+viene' THEN RETURN hoy + 7; END IF;
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION public.cotizacion_solicitar(p_account UUID, p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_nombre   TEXT := left(trim(COALESCE(p->>'nombre', '')), 80);
  v_empresa  TEXT := left(trim(COALESCE(p->>'empresa', '')), 120);
  v_tel      TEXT := regexp_replace(COALESCE(p->>'telefono', ''), '\D', '', 'g');
  v_correo   TEXT := left(trim(COALESCE(p->>'correo', '')), 120);
  v_cuando   TEXT := left(trim(COALESCE(p->>'para_cuando', '')), 60);
  -- Fecha ya calculada (AAAA-MM-DD) por el bot a partir de "para el sábado";
  -- llena el campo "Para cuándo" de la ficha. Si no es fecha válida se ignora.
  v_fecha    DATE;
  v_hoy      DATE := (now() AT TIME ZONE 'America/Monterrey')::date;
  v_notas    TEXT := left(trim(COALESCE(p->>'notas', '')), 500);
  v_folio    TEXT := left(regexp_replace(COALESCE(p->>'folio', ''), '[^A-Za-z0-9-]', '', 'g'), 20);
  v_origen   TEXT := CASE WHEN p->>'origen' = 'whatsapp' THEN 'WhatsApp' ELSE 'la página web' END;
  v_pr       JSONB;
  v_linea    TEXT;
  v_det      TEXT;
  v_marca    TEXT;
  v_cant     TEXT;
  v_lineas   TEXT[] := '{}';
  v_recientes INT;
  v_owner    UUID;
  v_pipeline UUID;
  v_stage    UUID;
  v_contact  UUID;
  v_deal     UUID;
BEGIN
  IF length(v_nombre) < 2 AND length(v_empresa) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nombre');
  END IF;
  IF jsonb_typeof(p->'productos') <> 'array' OR jsonb_array_length(p->'productos') = 0
     OR jsonb_array_length(p->'productos') > 30 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'productos');
  END IF;

  -- Freno contra abuso: máximo 30 solicitudes por hora por cuenta.
  PERFORM pg_advisory_xact_lock(hashtext('cotizacion:' || p_account::text));
  SELECT count(*) INTO v_recientes FROM deals
   WHERE account_id = p_account AND created_at > now() - interval '1 hour';
  IF v_recientes >= 30 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'muchas');
  END IF;

  FOR v_pr IN SELECT * FROM jsonb_array_elements(p->'productos') LOOP
    v_linea := left(trim(COALESCE(v_pr->>'linea', '')), 80);
    v_det   := left(trim(COALESCE(v_pr->>'detalle', '')), 400);
    v_marca := left(trim(COALESCE(v_pr->>'marca', '')), 60);
    v_cant  := left(trim(COALESCE(v_pr->>'cantidad', '')), 40);
    IF v_linea = '' AND v_det = '' THEN CONTINUE; END IF;
    v_lineas := v_lineas || ('- ' || concat_ws(' · ',
                  NULLIF(v_cant, ''),
                  NULLIF(concat_ws(': ', NULLIF(v_linea, ''), NULLIF(v_det, '')), ''),
                  CASE WHEN v_marca <> '' THEN 'marca ' || v_marca END));
  END LOOP;
  IF array_length(v_lineas, 1) IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'productos');
  END IF;

  SELECT p2.user_id INTO v_owner FROM profiles p2
   WHERE p2.account_id = p_account AND p2.account_role = 'owner' LIMIT 1;
  SELECT pl.id INTO v_pipeline FROM pipelines pl
   WHERE pl.account_id = p_account ORDER BY (pl.name = 'Cotizaciones') DESC, pl.created_at LIMIT 1;
  SELECT s.id INTO v_stage FROM pipeline_stages s WHERE s.pipeline_id = v_pipeline ORDER BY s.position LIMIT 1;
  IF v_owner IS NULL OR v_stage IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_tablero');
  END IF;

  -- Cliente: se reconoce por su teléfono (10 dígitos de México → 52XXXXXXXXXX).
  IF length(v_tel) = 10 THEN v_tel := '52' || v_tel; END IF;
  IF length(v_tel) BETWEEN 11 AND 15 THEN
    -- Mismo cliente aunque WhatsApp lo guarde como 521 + 10 dígitos y la
    -- página como 52 + 10: se comparan los últimos 10 dígitos (México).
    SELECT id INTO v_contact FROM contacts
     WHERE account_id = p_account
       AND (phone_normalized = v_tel
            OR (length(v_tel) >= 10 AND right(phone_normalized, 10) = right(v_tel, 10)))
     ORDER BY (phone_normalized = v_tel) DESC, created_at
     LIMIT 1;
  END IF;
  IF v_contact IS NULL THEN
    INSERT INTO contacts (user_id, account_id, name, phone, email, company)
    VALUES (v_owner, p_account, COALESCE(NULLIF(v_nombre, ''), v_empresa),
            CASE WHEN length(v_tel) BETWEEN 11 AND 15 THEN '+' || v_tel ELSE '' END,
            NULLIF(v_correo, ''), NULLIF(v_empresa, ''))
    RETURNING id INTO v_contact;
    IF v_nombre <> '' THEN
      UPDATE contacts SET name_source = 'manual' WHERE id = v_contact;
    END IF;
  ELSE
    -- El cliente ya existía (p. ej. por WhatsApp, con su nombre de perfil):
    -- se guarda el nombre y la empresa que dio al pedir la cotización.
    -- name_source='manual' evita que el siguiente mensaje de WhatsApp lo
    -- regrese a su nombre de perfil.
    UPDATE contacts SET name    = COALESCE(NULLIF(v_nombre, ''), name),
                        name_source = CASE WHEN v_nombre <> '' THEN 'manual' ELSE name_source END,
                        company = COALESCE(NULLIF(v_empresa, ''), company),
                        email   = COALESCE(NULLIF(v_correo, ''), email)
     WHERE id = v_contact;
  END IF;

  IF v_empresa <> '' THEN v_lineas := v_lineas || ('Empresa: ' || v_empresa); END IF;
  IF v_correo  <> '' THEN v_lineas := v_lineas || ('Correo: ' || v_correo); END IF;
  IF v_cuando  <> '' THEN v_lineas := v_lineas || ('Para cuándo: ' || v_cuando); END IF;
  IF v_notas   <> '' THEN v_lineas := v_lineas || ('Nota: ' || v_notas); END IF;
  v_lineas := v_lineas || ('Llegó por ' || v_origen || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);

  -- Primero lo que dijo el cliente (fiable); si no se entiende, la fecha del bot.
  v_fecha := public._ap_fecha_de_texto(v_cuando, v_hoy);
  IF v_fecha IS NULL THEN
    BEGIN
      IF COALESCE(p->>'fecha', '') ~ '^\d{4}-\d{2}-\d{2}$' THEN
        v_fecha := (p->>'fecha')::date;
      END IF;
    EXCEPTION WHEN others THEN v_fecha := NULL;
    END;
  END IF;
  IF v_fecha < v_hoy OR v_fecha > v_hoy + 365 THEN v_fecha := NULL; END IF;

  INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, status, expected_close_date)
  VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
          COALESCE(NULLIF(v_empresa, ''), v_nombre)
            || CASE WHEN v_cuando ILIKE 'urgente%' THEN ' · URGENTE' ELSE '' END,
          0, 'MXN', array_to_string(v_lineas, E'\n'), 'open', v_fecha)
  RETURNING id INTO v_deal;

  RETURN jsonb_build_object('ok', true, 'deal_id', v_deal, 'folio', v_folio);
END;
$$;

REVOKE ALL ON FUNCTION public.cotizacion_solicitar(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cotizacion_solicitar(UUID, JSONB) TO anon, authenticated, service_role;

-- Si una persona del equipo renombra al cliente en el CRM (sesión iniciada),
-- ese nombre también queda fijo frente al nombre de perfil de WhatsApp.
CREATE OR REPLACE FUNCTION public._ap_nombre_manual()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.name IS DISTINCT FROM OLD.name AND auth.uid() IS NOT NULL THEN
    NEW.name_source := 'manual';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ap_nombre_manual ON public.contacts;
CREATE TRIGGER ap_nombre_manual BEFORE UPDATE OF name ON public.contacts
  FOR EACH ROW EXECUTE FUNCTION public._ap_nombre_manual();

-- Corrige al cliente de la prueba actual: se queda con el nombre que dio.
UPDATE public.contacts c
   SET name = 'Humberto Martínez Hernández', name_source = 'manual'
 WHERE c.account_id = '39beb051-96d0-4ee8-9d2f-f26a7ab4d9a7'
   AND right(c.phone_normalized, 10) = '9624017470';
UPDATE public.deals d
   SET expected_close_date = public._ap_fecha_de_texto('sábado', (now() AT TIME ZONE 'America/Monterrey')::date)
 WHERE d.account_id = '39beb051-96d0-4ee8-9d2f-f26a7ab4d9a7'
   AND d.notes LIKE '%AP-DE6SOC%';
