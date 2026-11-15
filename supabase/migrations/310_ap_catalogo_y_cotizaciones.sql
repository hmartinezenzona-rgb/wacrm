-- ============================================================
-- 310 — AP Suministros: catálogo, solicitudes de cotización y seguimiento
--        (edición ap-suministros, NO aplicar en Remesas Ya ni en Doña Miriam)
--
-- catalogo                      líneas de producto/servicio con sus marcas.
--                               Única fuente: la página, el bot y la pantalla
--                               «Catálogo» del CRM leen lo mismo.
-- catalogo_publico(cuenta)      lectura pública (anon) de lo que está prendido.
-- cotizacion_solicitar(c, p)    la página o el bot dejan una solicitud en la
--                               primera columna del tablero «Cotizaciones».
-- deals.etapa_desde             desde cuándo está la tarjeta en su columna
--                               (para avisar de cotizaciones sin respuesta).
-- ap_preparar_cuenta(cuenta)    crea el tablero y el catálogo inicial.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.catalogo (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id  UUID NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  nombre      TEXT NOT NULL CHECK (length(trim(nombre)) > 0),
  descripcion TEXT,
  marcas      TEXT,
  disponible  BOOLEAN NOT NULL DEFAULT true,
  orden       INTEGER NOT NULL DEFAULT 0,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, nombre)
);
CREATE INDEX IF NOT EXISTS idx_catalogo_account ON public.catalogo(account_id, orden);

ALTER TABLE public.catalogo ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS catalogo_select ON public.catalogo;
DROP POLICY IF EXISTS catalogo_write  ON public.catalogo;
CREATE POLICY catalogo_select ON public.catalogo FOR SELECT USING (is_account_member(account_id));
CREATE POLICY catalogo_write  ON public.catalogo FOR ALL
  USING (is_account_member(account_id, 'agent')) WITH CHECK (is_account_member(account_id, 'agent'));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.catalogo TO authenticated;
REVOKE ALL ON public.catalogo FROM anon;

CREATE OR REPLACE FUNCTION public.catalogo_publico(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', c.nombre, 'descripcion', c.descripcion, 'marcas', c.marcas)
                            ORDER BY c.orden, c.nombre), '[]'::jsonb)
    FROM catalogo c
   WHERE c.account_id = p_account AND c.disponible;
$$;
REVOKE ALL ON FUNCTION public.catalogo_publico(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.catalogo_publico(UUID) TO anon, authenticated, service_role;

-- Desde cuándo está cada tarjeta en su columna.
ALTER TABLE public.deals ADD COLUMN IF NOT EXISTS etapa_desde TIMESTAMPTZ NOT NULL DEFAULT now();
CREATE OR REPLACE FUNCTION public._deal_etapa_desde()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stage_id IS DISTINCT FROM OLD.stage_id THEN
    NEW.etapa_desde := now();
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_deal_etapa_desde ON public.deals;
CREATE TRIGGER trg_deal_etapa_desde BEFORE UPDATE OF stage_id ON public.deals
  FOR EACH ROW EXECUTE FUNCTION public._deal_etapa_desde();

-- Solicitud esperada (de la página o del bot):
-- { "folio": "AP-ABC123", "origen": "web" | "whatsapp",
--   "nombre": "Juan Pérez", "empresa": "Planta X", "telefono": "844 123 4567", "correo": "a@b.com",
--   "para_cuando": "Esta semana", "notas": "Mando foto por WhatsApp",
--   "productos": [ { "linea": "Válvulas", "detalle": "Solenoide 1/2\" 24 V", "marca": "ASCO", "cantidad": "10 pz" } ] }
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
    SELECT id INTO v_contact FROM contacts WHERE account_id = p_account AND phone_normalized = v_tel LIMIT 1;
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

-- Tablero y catálogo inicial (se corre una vez, después de crear la cuenta dueña).
CREATE OR REPLACE FUNCTION public.ap_preparar_cuenta(p_account UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_owner UUID;
  v_pipeline UUID;
BEGIN
  SELECT user_id INTO v_owner FROM profiles WHERE account_id = p_account AND account_role = 'owner' LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION 'La cuenta no tiene dueño'; END IF;

  SELECT id INTO v_pipeline FROM pipelines WHERE account_id = p_account AND name = 'Cotizaciones';
  IF v_pipeline IS NULL THEN
    INSERT INTO pipelines (user_id, account_id, name) VALUES (v_owner, p_account, 'Cotizaciones')
    RETURNING id INTO v_pipeline;
    INSERT INTO pipeline_stages (pipeline_id, name, position, color) VALUES
      (v_pipeline, 'Solicitud nueva',    0, '#1F6BFF'),
      (v_pipeline, 'Cotizando',          1, '#F59E0B'),
      (v_pipeline, 'Cotización enviada', 2, '#8B5CF6'),
      (v_pipeline, 'Ganada',             3, '#10B981'),
      (v_pipeline, 'Entregado',          4, '#64748B'),
      (v_pipeline, 'Perdida',            5, '#EF4444');
  END IF;

  INSERT INTO catalogo (account_id, nombre, descripcion, marcas, orden) VALUES
    (p_account, 'Equipos de medición', 'Multímetros, pinzas amperimétricas, manómetros y sondas; micrómetros, calibradores y relojes comparadores.', 'Fluke, Mitutoyo, Starrett, Westward', 0),
    (p_account, 'Válvulas', 'Check, solenoide, mariposa, axial, neumática, de gas y de aire.', 'ASCO, Parker, Swagelok', 1),
    (p_account, 'Mangueras, bandas y carretes', 'Manguera plana PVC, espiral de poliuretano, de hule, metálica y para aire; carretes retráctiles y bandas transportadoras.', NULL, 2),
    (p_account, 'Conexiones y tornillería', 'Conexiones de latón y acero inoxidable, tubería de acero al carbón y tornillería grado 2, 5, 8 y Allen 12.9, métrica y estándar.', 'Swagelok', 3),
    (p_account, 'Neumática, sensores y baleros', 'Cilindros neumáticos, sensores fotoeléctricos y de torque, sondas, pistones, bujías, cables y baleros.', 'Festo, SMC, SKF, Norgren, CKD, Omron', 4),
    (p_account, 'Productos especiales', 'Fuentes de poder, motores servo, contactores, relevadores, venturis, aceiteras y cámaras térmicas.', 'Schneider Electric, Allen-Bradley, Telemecanique, Eaton, FLIR', 5),
    (p_account, 'Insumos para planta y oficina', 'Loctite, trapo industrial, cintas, emplaye, esquineros, limpieza, papelería y ventiladores industriales.', 'Loctite, 3M', 6),
    (p_account, 'Maquinado CNC y fabricación', 'Piezas maquinadas, piezas metálicas y de aluminio a la medida, pailería, estructuras y racks.', NULL, 7),
    (p_account, 'Instalaciones y mantenimiento', 'Mantenimiento general, retrabajos en planta, racks, torres de enfriamiento y reparación de motores eléctricos.', NULL, 8),
    (p_account, 'Capacitaciones', 'Primeros auxilios, seguridad, brigadas, montacargas, extintores y trabajos en altura, con constancia DC-3.', NULL, 9)
  ON CONFLICT (account_id, nombre) DO NOTHING;

  RETURN jsonb_build_object('ok', true, 'pipeline_id', v_pipeline);
END;
$$;
REVOKE ALL ON FUNCTION public.ap_preparar_cuenta(UUID) FROM PUBLIC, anon, authenticated;

ALTER PUBLICATION supabase_realtime ADD TABLE public.catalogo;
NOTIFY pgrst, 'reload schema';
