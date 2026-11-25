-- ============================================================
-- 336 — Menú y pedidos configurables por negocio (CRM base).
--
-- Antes (300/301) el menú era solo de Doña Miriam: grupos fijos
-- (arroz/carne/vianda/potaje/extra) y la palabra «charola» escrita en
-- las funciones. Ahora cada negocio define en negocio_config.data.pedido:
--
--   "pedido": {
--     "uno": "charola", "varios": "charolas",
--     "grupos": [
--       {"id": "arroz", "nombre": "Arroz", "tipo": "uno"},       -- escoge 1, obligatorio
--       {"id": "potaje", "nombre": "Potaje", "tipo": "opcional"}, -- escoge 1 o nada
--       {"id": "extra", "nombre": "Extras", "tipo": "extra"}      -- se cobran aparte
--     ]
--   }
--
-- Si un negocio no lo tiene, se usa lo de Doña Miriam (así no se rompe
-- su página). Además:
--   menu_items.agotado_hasta  «se acabó solo hoy»: el plato vuelve solo
--                             al día siguiente. «Hasta que yo diga»
--                             sigue siendo disponible = false.
--   menu_items.foto_url       foto del plato (opcional).
--
-- Requiere 300 y 301. Se puede correr más de una vez.
-- ============================================================

-- 1) Grupos libres: cualquier clave corta en minúsculas.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname FROM pg_constraint
     WHERE conrelid = 'public.menu_items'::regclass AND contype = 'c'
       AND pg_get_constraintdef(oid) ILIKE '%grupo%'
  LOOP
    EXECUTE format('ALTER TABLE public.menu_items DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;
ALTER TABLE public.menu_items
  ADD CONSTRAINT menu_items_grupo_clave CHECK (grupo ~ '^[a-z0-9_]{1,30}$');

ALTER TABLE public.menu_items ADD COLUMN IF NOT EXISTS agotado_hasta DATE;
ALTER TABLE public.menu_items ADD COLUMN IF NOT EXISTS foto_url TEXT;

-- 2) Cómo es un pedido en este negocio (con valores de Doña Miriam si falta).
CREATE OR REPLACE FUNCTION public._pedido_cfg(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'uno',    COALESCE(NULLIF(trim(n.data #>> '{pedido,uno}'), ''), 'charola'),
    'varios', COALESCE(NULLIF(trim(n.data #>> '{pedido,varios}'), ''), 'charolas'),
    'grupos', CASE
      WHEN jsonb_typeof(n.data #> '{pedido,grupos}') = 'array'
       AND jsonb_array_length(n.data #> '{pedido,grupos}') > 0
      THEN n.data #> '{pedido,grupos}'
      ELSE '[{"id":"arroz","nombre":"Arroz","tipo":"uno"},
             {"id":"carne","nombre":"Carne","tipo":"uno"},
             {"id":"vianda","nombre":"Vianda","tipo":"uno"},
             {"id":"potaje","nombre":"Potaje","tipo":"opcional"},
             {"id":"extra","nombre":"Extras","tipo":"extra"}]'::jsonb
    END)
  FROM (SELECT p_account AS a) x
  LEFT JOIN negocio_config n ON n.account_id = x.a;
$$;
REVOKE ALL ON FUNCTION public._pedido_cfg(UUID) FROM PUBLIC, anon, authenticated;

-- 3) Lo que ve la página: sin lo apagado ni lo agotado hoy, con los grupos y palabras.
CREATE OR REPLACE FUNCTION public.menu_publico(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'precio_charola', c.precio_charola,
    'anticipo',       c.anticipo,
    'cupo_diario',    c.cupo_diario,
    'dias_entrega',   to_jsonb(c.dias_entrega),
    'dias_antes',     c.dias_antes,
    'fechas_cerradas',to_jsonb(c.fechas_cerradas),
    'aviso',          c.aviso,
    'pedido',         _pedido_cfg(c.account_id),
    'items', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('grupo', i.grupo, 'nombre', i.nombre, 'precio', i.precio,
                                          'dias', i.dias, 'foto', i.foto_url)
                       ORDER BY i.grupo, i.orden, i.nombre)
        FROM menu_items i
       WHERE i.account_id = c.account_id AND i.disponible
         AND (i.agotado_hasta IS NULL OR i.agotado_hasta < (now() AT TIME ZONE 'America/Monterrey')::date)
    ), '[]'::jsonb)
  )
  FROM menu_config c
  WHERE c.account_id = p_account;
$$;
REVOKE ALL ON FUNCTION public.menu_publico(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.menu_publico(UUID) TO anon, authenticated, service_role;

-- 4) Cupo: el número al inicio del título («3 charolas · Ana», «2 órdenes · Luis»).
CREATE OR REPLACE FUNCTION public._charolas_por_dia(p_account UUID, p_desde DATE, p_hasta DATE)
RETURNS TABLE(fecha DATE, charolas INTEGER)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT d.expected_close_date,
         SUM(COALESCE(NULLIF(substring(d.title FROM '^(\d+) '), '')::int, 1))::int
    FROM deals d
    JOIN pipeline_stages s ON s.id = d.stage_id
   WHERE d.account_id = p_account
     AND d.expected_close_date BETWEEN p_desde AND p_hasta
     AND s.name NOT ILIKE '%cancel%'
     AND COALESCE(d.status, 'open') <> 'lost'
   GROUP BY d.expected_close_date;
$$;
REVOKE ALL ON FUNCTION public._charolas_por_dia(UUID, DATE, DATE) FROM PUBLIC, anon, authenticated;

-- 5) Encargo desde la página, con los grupos del negocio.
-- Pedido esperado (las claves de cada unidad son los id de los grupos):
-- { "folio": "DM-ABC123", "fecha": "2026-11-13", "nombre": "Ana", "telefono": "844 123 4567",
--   "notas": "sin cebolla",
--   "charolas": [ { "qty": 2, "arroz": "Congrí", "carne": "Ropa vieja", "vianda": "Tostones",
--                   "extras": ["Ración extra de arroz"] } ] }
-- («pedidos» también se acepta en lugar de «charolas»; «extras» es la
-- lista de los grupos de tipo extra.)
CREATE OR REPLACE FUNCTION public.encargo_web(p_account UUID, p JSONB)
RETURNS JSONB
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  c          menu_config%ROWTYPE;
  v_cfg      JSONB := _pedido_cfg(p_account);
  v_uno      TEXT;
  v_varios   TEXT;
  v_uno_may      TEXT;
  v_unidades JSONB := COALESCE(p->'pedidos', p->'charolas');
  v_hoy      DATE := (now() AT TIME ZONE 'America/Monterrey')::date;
  v_fecha    DATE;
  v_dow      INT;
  v_nombre   TEXT := left(trim(COALESCE(p->>'nombre', '')), 80);
  v_tel      TEXT := regexp_replace(COALESCE(p->>'telefono', ''), '\D', '', 'g');
  v_notas    TEXT := left(trim(COALESCE(p->>'notas', '')), 300);
  v_folio    TEXT := left(regexp_replace(COALESCE(p->>'folio', ''), '[^A-Za-z0-9-]', '', 'g'), 20);
  v_ch       JSONB;
  v_g        JSONB;
  v_qty      INT;
  v_total    NUMERIC := 0;
  v_n        INT := 0;
  v_ocupado  INT;
  v_lineas   TEXT[] := '{}';
  v_partes   TEXT[];
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
  v_uno := v_cfg->>'uno';
  v_varios := v_cfg->>'varios';
  v_uno_may := upper(left(v_uno, 1)) || substr(v_uno, 2);

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
  IF jsonb_typeof(v_unidades) IS DISTINCT FROM 'array' OR jsonb_array_length(v_unidades) = 0
     OR jsonb_array_length(v_unidades) > 20 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'charolas');
  END IF;

  FOR v_ch IN SELECT * FROM jsonb_array_elements(v_unidades) LOOP
    v_qty := COALESCE(NULLIF(v_ch->>'qty', '')::int, 1);
    IF v_qty < 1 OR v_qty > 20 THEN
      RETURN jsonb_build_object('ok', false, 'error', 'charolas');
    END IF;
    v_partes := '{}';
    -- Grupos «uno» (obligatorio) y «opcional»: una opción que exista, esté
    -- prendida, no agotada ese día y se ofrezca ese día de la semana.
    FOR v_g IN SELECT * FROM jsonb_array_elements(v_cfg->'grupos') LOOP
      CONTINUE WHEN COALESCE(v_g->>'tipo', 'uno') = 'extra';
      v_op := NULLIF(trim(COALESCE(v_ch->>(v_g->>'id'), '')), '');
      IF v_op IS NULL THEN
        IF COALESCE(v_g->>'tipo', 'uno') = 'uno' THEN
          RETURN jsonb_build_object('ok', false, 'error', 'falta_' || (v_g->>'id'));
        END IF;
        CONTINUE;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM menu_items i
                      WHERE i.account_id = p_account AND i.grupo = v_g->>'id' AND i.nombre = v_op
                        AND i.disponible AND (i.agotado_hasta IS NULL OR i.agotado_hasta < v_fecha)
                        AND (i.dias IS NULL OR v_dow = ANY (i.dias))) THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_hay', 'plato', v_op);
      END IF;
      v_partes := v_partes || v_op;
    END LOOP;
    v_total := v_total + v_qty * c.precio_charola;

    -- Extras: de cualquier grupo de tipo «extra», con su precio.
    FOR v_ex IN SELECT jsonb_array_elements_text(COALESCE(v_ch->'extras', '[]'::jsonb)) LOOP
      SELECT i.precio INTO v_precio FROM menu_items i
       WHERE i.account_id = p_account AND i.nombre = v_ex AND i.disponible
         AND i.grupo IN (SELECT g->>'id' FROM jsonb_array_elements(v_cfg->'grupos') g WHERE g->>'tipo' = 'extra')
         AND (i.agotado_hasta IS NULL OR i.agotado_hasta < v_fecha)
         AND (i.dias IS NULL OR v_dow = ANY (i.dias))
       LIMIT 1;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'error', 'no_hay', 'plato', v_ex);
      END IF;
      v_total := v_total + v_qty * COALESCE(v_precio, 0);
    END LOOP;

    FOR k IN 1..v_qty LOOP
      v_i := v_i + 1;
      v_lineas := v_lineas || (v_uno_may || ' ' || v_i || ': ' || array_to_string(v_partes, ', '));
      FOR v_ex IN SELECT jsonb_array_elements_text(COALESCE(v_ch->'extras', '[]'::jsonb)) LOOP
        v_lineas := v_lineas || ('Extra: ' || v_ex);
      END LOOP;
    END LOOP;
    v_n := v_n + v_qty;
  END LOOP;

  PERFORM pg_advisory_xact_lock(hashtext('encargo_web:' || p_account::text));
  SELECT COALESCE(SUM(charolas), 0) INTO v_ocupado FROM _charolas_por_dia(p_account, v_fecha, v_fecha);
  IF v_ocupado + v_n > c.cupo_diario THEN
    RETURN jsonb_build_object('ok', false, 'error', 'cupo', 'quedan', GREATEST(c.cupo_diario - v_ocupado, 0));
  END IF;

  SELECT p2.user_id INTO v_owner FROM profiles p2
   WHERE p2.account_id = p_account AND p2.account_role = 'owner' LIMIT 1;
  SELECT pl.id INTO v_pipeline FROM pipelines pl
   WHERE pl.account_id = p_account ORDER BY (pl.name = 'Encargos') DESC, pl.created_at LIMIT 1;
  SELECT s.id INTO v_stage FROM pipeline_stages s WHERE s.pipeline_id = v_pipeline ORDER BY s.position LIMIT 1;
  IF v_owner IS NULL OR v_stage IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_tablero');
  END IF;

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
  IF c.anticipo > 0 THEN
    v_lineas := v_lineas || ('Anticipo: $' || (v_n * c.anticipo)::text);
  END IF;
  v_lineas := v_lineas
    || ('Pidió por la página web' || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);

  INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, expected_close_date, status)
  VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
          v_n || ' ' || CASE WHEN v_n = 1 THEN v_uno ELSE v_varios END || ' · ' || v_nombre,
          v_total, 'MXN', array_to_string(v_lineas, E'\n'), v_fecha, 'open')
  RETURNING id INTO v_deal;

  RETURN jsonb_build_object('ok', true, 'deal_id', v_deal, 'folio', v_folio, 'total', v_total,
                            'anticipo', v_n * c.anticipo, 'quedan', c.cupo_diario - v_ocupado - v_n);
END;
$$;
REVOKE ALL ON FUNCTION public.encargo_web(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.encargo_web(UUID, JSONB) TO anon, authenticated, service_role;

NOTIFY pgrst, 'reload schema';
