-- ============================================================
-- 315 — cotizacion_solicitar reconoce al mismo cliente de WhatsApp (AP)
--
-- Si alguien escribe primero por WhatsApp (contacto 521 + 10 dígitos) y
-- luego pide cotización en la página (52 + 10), antes se creaba un cliente
-- duplicado y la ficha no se ligaba a su chat. Ahora se compara por los
-- últimos 10 dígitos. Solo cambia esa búsqueda; el resto es igual que 310.
-- ============================================================

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
  ELSE
    UPDATE contacts SET company = COALESCE(company, NULLIF(v_empresa, '')),
                        email   = COALESCE(email, NULLIF(v_correo, ''))
     WHERE id = v_contact;
  END IF;

  IF v_empresa <> '' THEN v_lineas := v_lineas || ('Empresa: ' || v_empresa); END IF;
  IF v_correo  <> '' THEN v_lineas := v_lineas || ('Correo: ' || v_correo); END IF;
  IF v_cuando  <> '' THEN v_lineas := v_lineas || ('Para cuándo: ' || v_cuando); END IF;
  IF v_notas   <> '' THEN v_lineas := v_lineas || ('Nota: ' || v_notas); END IF;
  v_lineas := v_lineas || ('Llegó por ' || v_origen || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);

  INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, status)
  VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
          COALESCE(NULLIF(v_empresa, ''), v_nombre)
            || CASE WHEN v_cuando ILIKE 'urgente%' THEN ' · URGENTE' ELSE '' END,
          0, 'MXN', array_to_string(v_lineas, E'\n'), 'open')
  RETURNING id INTO v_deal;

  RETURN jsonb_build_object('ok', true, 'deal_id', v_deal, 'folio', v_folio);
END;
$$;

REVOKE ALL ON FUNCTION public.cotizacion_solicitar(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.cotizacion_solicitar(UUID, JSONB) TO anon, authenticated, service_role;
