-- ============================================================
-- 301 — La página web lee el menú y deja encargos en el tablero
--        (edición dona-miriam, NO aplicar en Remesas Ya)
--
-- sitio_datos(cuenta)          lo que la página necesita al abrir: el menú
--                              prendido (menu_publico) + cuántas charolas
--                              van apartadas por día.
-- encargo_web(cuenta, pedido)  recibe el encargo armado en la página,
--                              lo valida contra el menú y el cupo, calcula
--                              el total aquí (no se confía en el precio que
--                              manda el navegador), crea/usa el cliente y
--                              deja la tarjeta en la primera columna del
--                              tablero «Encargos».
--
-- Las dos son SECURITY DEFINER y las puede llamar `anon` (la página no
-- tiene sesión). Por eso validan todo lo que reciben.
-- ============================================================

-- Charolas apartadas por día, sin contar las canceladas.
CREATE OR REPLACE FUNCTION public._charolas_por_dia(p_account UUID, p_desde DATE, p_hasta DATE)
RETURNS TABLE(fecha DATE, charolas INTEGER)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT d.expected_close_date,
         SUM(COALESCE(NULLIF(substring(d.title FROM '^(\d+) charola'), '')::int, 1))::int
    FROM deals d
    JOIN pipeline_stages s ON s.id = d.stage_id
   WHERE d.account_id = p_account
     AND d.expected_close_date BETWEEN p_desde AND p_hasta
     AND s.name NOT ILIKE '%cancel%'
     AND COALESCE(d.status, 'open') <> 'lost'
   GROUP BY d.expected_close_date;
$$;
REVOKE ALL ON FUNCTION public._charolas_por_dia(UUID, DATE, DATE) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.sitio_datos(p_account UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_menu JSONB := menu_publico(p_account);
  v_hoy  DATE  := (now() AT TIME ZONE 'America/Monterrey')::date;
BEGIN
  IF v_menu IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN v_menu || jsonb_build_object(
    'hoy', v_hoy,
    'ocupado', COALESCE((
      SELECT jsonb_object_agg(fecha::text, charolas)
        FROM _charolas_por_dia(p_account, v_hoy, v_hoy + 30)
    ), '{}'::jsonb)
  );
END;
$$;
REVOKE ALL ON FUNCTION public.sitio_datos(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.sitio_datos(UUID) TO anon, authenticated, service_role;

-- Pedido esperado:
-- { "folio": "DM-ABC123", "fecha": "2026-11-13", "nombre": "Ana", "telefono": "844 123 4567",
--   "notas": "sin cebolla",
--   "charolas": [ { "qty": 2, "arroz": "Congrí", "carne": "Ropa vieja", "vianda": "Tostones",
--                   "potaje": "Frijoles negros", "extras": ["Ración extra de arroz"] } ] }
CREATE OR REPLACE FUNCTION public.encargo_web(p_account UUID, p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  c          menu_config%ROWTYPE;
  v_hoy      DATE := (now() AT TIME ZONE 'America/Monterrey')::date;
  v_fecha    DATE;
  v_dow      INT;
  v_nombre   TEXT := left(trim(COALESCE(p->>'nombre', '')), 80);
  v_tel      TEXT := regexp_replace(COALESCE(p->>'telefono', ''), '\D', '', 'g');
  v_notas    TEXT := left(trim(COALESCE(p->>'notas', '')), 300);
  v_folio    TEXT := left(regexp_replace(COALESCE(p->>'folio', ''), '[^A-Za-z0-9-]', '', 'g'), 20);
  v_ch       JSONB;
  v_qty      INT;
  v_total    NUMERIC := 0;
  v_n        INT := 0;
  v_ocupado  INT;
  v_lineas   TEXT[] := '{}';
  v_partes   TEXT[];
  v_g        TEXT;
  v_op       TEXT;
  v_ex       TEXT;
  v_precio   NUMERIC;
  v_i        INT := 0;
  v_owner    UUID;
  v_pipeline UUID;
  v_stage    UUID;
  v_contact  UUID;
  v_deal     UUID;
BEGIN
  SELECT * INTO c FROM menu_config WHERE account_id = p_account;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_menu');
  END IF;

  -- Fecha válida: con anticipación, día de entrega y no cerrado.
  BEGIN
    v_fecha := (p->>'fecha')::date;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fecha');
  END;
  v_dow := extract(dow FROM v_fecha)::int;
  IF v_fecha IS NULL OR v_fecha < v_hoy + c.dias_antes OR v_fecha > v_hoy + 60
     OR NOT (v_dow = ANY (c.dias_entrega)) OR v_fecha = ANY (c.fechas_cerradas) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'fecha');
  END IF;
  IF length(v_nombre) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nombre');
  END IF;
  IF jsonb_typeof(p->'charolas') <> 'array' OR jsonb_array_length(p->'charolas') = 0
     OR jsonb_array_length(p->'charolas') > 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'charolas');
  END IF;

  -- Cada charola: opciones que existen, están prendidas y se ofrecen ese día.
  FOR v_ch IN SELECT * FROM jsonb_array_elements(p->'charolas') LOOP
    v_qty := COALESCE(NULLIF(v_ch->>'qty', '')::int, 1);
    IF v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'charolas');
    END IF;
    v_partes := '{}';
    FOREACH v_g IN ARRAY ARRAY['arroz','carne','vianda','potaje'] LOOP
      v_op := NULLIF(trim(COALESCE(v_ch->>v_g, '')), '');
      IF v_op IS NULL THEN
        IF v_g <> 'potaje' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'falta_' || v_g);
        END IF;
        CONTINUE;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM menu_items i
                      WHERE i.account_id = p_account AND i.grupo = v_g AND i.nombre = v_op
                        AND i.disponible AND (i.dias IS NULL OR v_dow = ANY (i.dias))) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_hay', 'plato', v_op);
      END IF;
      v_partes := v_partes || v_op;
    END LOOP;
    v_total := v_total + v_qty * c.precio_charola;
    FOR v_ex IN SELECT jsonb_array_elements_text(COALESCE(v_ch->'extras', '[]'::jsonb)) LOOP
      SELECT i.precio INTO v_precio FROM menu_items i
       WHERE i.account_id = p_account AND i.grupo = 'extra' AND i.nombre = v_ex AND i.disponible
         AND (i.dias IS NULL OR v_dow = ANY (i.dias));
      IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_hay', 'plato', v_ex);
      END IF;
      v_total := v_total + v_qty * COALESCE(v_precio, 0);
    END LOOP;
    FOR k IN 1..v_qty LOOP
      v_i := v_i + 1;
      v_lineas := v_lineas || ('Charola ' || v_i || ': ' || array_to_string(v_partes, ', '));
      FOR v_ex IN SELECT jsonb_array_elements_text(COALESCE(v_ch->'extras', '[]'::jsonb)) LOOP
        v_lineas := v_lineas || ('Extra: ' || v_ex);
      END LOOP;
    END LOOP;
    v_n := v_n + v_qty;
  END LOOP;

  -- Cupo del día (se bloquea la cuenta para que dos encargos a la vez no se pasen).
  PERFORM pg_advisory_xact_lock(hashtext('encargo_web:' || p_account::text));
  SELECT COALESCE(SUM(charolas), 0) INTO v_ocupado FROM _charolas_por_dia(p_account, v_fecha, v_fecha);
  IF v_ocupado + v_n > c.cupo_diario THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cupo', 'quedan', GREATEST(c.cupo_diario - v_ocupado, 0));
  END IF;

  -- Tablero «Encargos» y su primera columna; las tarjetas quedan a nombre de la dueña.
  SELECT p2.user_id INTO v_owner FROM profiles p2
   WHERE p2.account_id = p_account AND p2.account_role = 'owner' LIMIT 1;
  SELECT pl.id INTO v_pipeline FROM pipelines pl
   WHERE pl.account_id = p_account ORDER BY (pl.name = 'Encargos') DESC, pl.created_at LIMIT 1;
  SELECT s.id INTO v_stage FROM pipeline_stages s WHERE s.pipeline_id = v_pipeline ORDER BY s.position LIMIT 1;
  IF v_owner IS NULL OR v_stage IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_tablero');
  END IF;

  -- Cliente: se reconoce por su teléfono (10 dígitos de México → 52XXXXXXXXXX).
  IF length(v_tel) = 10 THEN v_tel := '52' || v_tel; END IF;
  IF length(v_tel) BETWEEN 11 AND 15 THEN
    SELECT id INTO v_contact FROM contacts WHERE account_id = p_account AND phone_normalized = v_tel LIMIT 1;
    IF v_contact IS NULL THEN
      INSERT INTO contacts (user_id, account_id, name, phone)
      VALUES (v_owner, p_account, v_nombre, '+' || v_tel) RETURNING id INTO v_contact;
    END IF;
  ELSE
    INSERT INTO contacts (user_id, account_id, name, phone)
    VALUES (v_owner, p_account, v_nombre, '') RETURNING id INTO v_contact;
  END IF;

  IF v_notas <> '' THEN v_lineas := v_lineas || ('Nota: ' || v_notas); END IF;
  v_lineas := v_lineas
    || ('Anticipo: $' || (v_n * c.anticipo)::text)
    || ('Pidió por la página web' || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);

  INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, expected_close_date, status)
  VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
          v_n || CASE WHEN v_n = 1 THEN ' charola · ' ELSE ' charolas · ' END || v_nombre,
          v_total, 'MXN', array_to_string(v_lineas, E'\n'), v_fecha, 'open')
  RETURNING id INTO v_deal;

  RETURN jsonb_build_object('ok', true, 'deal_id', v_deal, 'folio', v_folio, 'total', v_total,
                            'anticipo', v_n * c.anticipo, 'quedan', c.cupo_diario - v_ocupado - v_n);
END;
$$;
REVOKE ALL ON FUNCTION public.encargo_web(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.encargo_web(UUID, JSONB) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
