-- ============================================================
-- 325 — La ficha guarda datos extra del agente (p.extra = {"Etiqueta": "valor"}),
--        por ejemplo las respuestas de la entrevista por chat. Cada uno queda
--        como una línea «Etiqueta: valor» en las notas de la tarjeta y se
--        actualiza por etiqueta, igual que los campos fijos. Desde WhatsApp,
--        un dato extra basta para crear la tarjeta.
-- ============================================================
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
  v_titulo   TEXT;
  v_extra    RECORD;
  v_hay_extra BOOLEAN := COALESCE(jsonb_typeof(p->'extra') = 'object' AND p->'extra' <> '{}'::jsonb, false);
BEGIN
  -- Desde WhatsApp basta con el teléfono y algún dato (el agente guarda
  -- poco a poco); desde la página se pide nombre o negocio.
  IF length(v_nombre) < 2 AND length(v_negocio) < 2
     AND NOT (p->>'origen' = 'whatsapp' AND length(regexp_replace(COALESCE(p->>'telefono', ''), '\D', '', 'g')) >= 10
              AND (v_giro <> '' OR v_ciudad <> '' OR v_reto <> '' OR v_paquete <> '' OR v_llamada <> '' OR v_hay_extra)) THEN
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
    VALUES (v_owner, p_account, COALESCE(NULLIF(v_nombre, ''), NULLIF(v_negocio, ''), 'Cliente de WhatsApp'),
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
  -- Datos extra del agente (entrevista y lo que defina cada negocio): «Etiqueta: valor».
  IF v_hay_extra THEN
    FOR v_extra IN SELECT key, value FROM jsonb_each_text(p->'extra') LOOP
      IF btrim(COALESCE(v_extra.value, '')) <> '' AND v_extra.key ~ '^[^:\n]{1,40}$' THEN
        v_lineas := v_lineas || (btrim(v_extra.key) || ': ' || left(regexp_replace(btrim(v_extra.value), '\s*\n\s*', ' · ', 'g'), 500));
      END IF;
    END LOOP;
  END IF;

  -- Título de la tarjeta: el negocio; si no hay, «Giro · Nombre».
  v_titulo := COALESCE(NULLIF(v_negocio, ''),
                CASE WHEN v_giro <> '' THEN upper(left(v_giro, 1)) || substr(v_giro, 2)
                       || CASE WHEN v_nombre <> '' THEN ' · ' || split_part(v_nombre, ' ', 1) ELSE '' END END,
                NULLIF(v_nombre, ''), 'Cliente de WhatsApp');

  SELECT d.id, d.stage_id INTO v_deal, v_deal_stage FROM deals d
   WHERE d.account_id = p_account AND d.contact_id = v_contact
     AND d.pipeline_id = v_pipeline AND d.status = 'open'
   ORDER BY d.created_at DESC LIMIT 1;

  IF v_deal IS NOT NULL THEN
    v_existe := true;
    UPDATE deals
       SET notes = public._of_fusionar_notas(notes, v_lineas)
     WHERE id = v_deal;
  ELSE
    v_lineas := v_lineas || ('Llegó por ' || v_origen || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);
    INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, status)
    VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
            v_titulo,
            0, 'MXN', array_to_string(v_lineas, E'\n'), 'open')
    RETURNING id, stage_id INTO v_deal, v_deal_stage;
  END IF;

  -- Título automático (salvo que alguien lo haya renombrado a mano):
  -- negocio; si no, «Giro · Nombre»; si no, nombre; si no, «Cliente de WhatsApp».
  UPDATE deals d
     SET title = COALESCE(
           NULLIF(c.company, ''),
           (SELECT upper(left(g, 1)) || substr(g, 2)
                   || CASE WHEN c.name_source = 'manual' AND c.name <> '' THEN ' · ' || split_part(c.name, ' ', 1) ELSE '' END
              FROM (SELECT btrim(substr(l, 6)) g FROM unnest(string_to_array(d.notes, E'\n')) l WHERE l ILIKE 'Giro:%' LIMIT 1) z),
           CASE WHEN c.name_source = 'manual' THEN NULLIF(c.name, '') END,
           'Cliente de WhatsApp')
    FROM contacts c
   WHERE d.id = v_deal AND c.id = d.contact_id
     AND (d.title = 'Cliente de WhatsApp' OR d.title LIKE '% · %' OR d.title = c.name
          OR d.title = c.company OR d.title ILIKE (SELECT btrim(substr(l, 6)) FROM unnest(string_to_array(d.notes, E'\n')) l WHERE l ILIKE 'Giro:%' LIMIT 1)
          OR v_negocio <> '');

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

NOTIFY pgrst, 'reload schema';
