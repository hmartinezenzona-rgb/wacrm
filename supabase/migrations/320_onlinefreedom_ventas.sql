-- ============================================================
-- 320 — Onlinefreedom: CRM de ventas de la agencia
--        (edición onlinefreedom, NO aplicar en Remesas Ya, Doña Miriam ni AP)
--
-- Va después de 302 y 310–318 (reusa su tabla catalogo, avisos, bot).
--
-- catalogo.precio                    precio de cada paquete (texto libre).
-- catalogo_publico(cuenta)           ahora incluye el precio.
-- diagnostico_solicitar(cuenta, p)   la página o el agente dejan un prospecto
--                                    en «Nuevo contacto» del tablero «Ventas».
--                                    Si el cliente ya tiene una tarjeta abierta,
--                                    se le agregan los datos nuevos.
-- of_preparar_cuenta(cuenta)         crea el tablero «Ventas» y los paquetes.
-- Estado por columna en «Ventas»: Anticipo pagado / En implementación /
--   Cliente activo → won · Perdido → lost · lo demás → open.
-- Avisos y crons apuntan a crm-onlinefreedom.vercel.app.
-- ============================================================

ALTER TABLE public.catalogo ADD COLUMN IF NOT EXISTS precio TEXT;

CREATE OR REPLACE FUNCTION public.catalogo_publico(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('nombre', c.nombre, 'descripcion', c.descripcion,
                                               'precio', c.precio, 'incluye', c.marcas)
                            ORDER BY c.orden, c.nombre), '[]'::jsonb)
    FROM catalogo c
   WHERE c.account_id = p_account AND c.disponible;
$$;
REVOKE ALL ON FUNCTION public.catalogo_publico(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.catalogo_publico(UUID) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Prospecto (de la página o del agente de WhatsApp):
-- { "origen": "web" | "whatsapp", "folio": "OF-ABC123",
--   "nombre": "Juan", "negocio": "Tacos Juan", "giro": "Restaurante o comida",
--   "ciudad": "Saltillo", "telefono": "844 123 4567", "correo": "a@b.com",
--   "reto": "Contesto tarde los mensajes", "paquete": "Pro con IA",
--   "presupuesto": "unos 5 mil", "decide": "Sí, soy el dueño",
--   "para_cuando": "Este mes", "notas": "Prefiere llamada en la tarde" }
-- Todo es opcional salvo nombre o negocio.
-- ------------------------------------------------------------
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
  v_notas    TEXT := left(trim(COALESCE(p->>'notas', '')), 500);
  v_folio    TEXT := left(regexp_replace(COALESCE(p->>'folio', ''), '[^A-Za-z0-9-]', '', 'g'), 20);
  v_origen   TEXT := CASE WHEN p->>'origen' = 'whatsapp' THEN 'WhatsApp' ELSE 'la página web' END;
  v_lineas   TEXT[] := '{}';
  v_recientes INT;
  v_owner    UUID;
  v_pipeline UUID;
  v_stage    UUID;
  v_contact  UUID;
  v_deal     UUID;
  v_existe   BOOLEAN := false;
BEGIN
  IF length(v_nombre) < 2 AND length(v_negocio) < 2 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'nombre');
  END IF;

  -- Freno contra abuso: máximo 30 prospectos por hora por cuenta.
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
  IF v_owner IS NULL OR v_stage IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'sin_tablero');
  END IF;

  -- Cliente: por teléfono (México: 52 o 521 + 10 dígitos se toman como el mismo).
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

  IF v_giro    <> '' THEN v_lineas := v_lineas || ('Giro: ' || v_giro); END IF;
  IF v_ciudad  <> '' THEN v_lineas := v_lineas || ('Ciudad: ' || v_ciudad); END IF;
  IF v_reto    <> '' THEN v_lineas := v_lineas || ('Reto: ' || v_reto); END IF;
  IF v_paquete <> '' THEN v_lineas := v_lineas || ('Paquete: ' || v_paquete); END IF;
  IF v_presup  <> '' THEN v_lineas := v_lineas || ('Presupuesto: ' || v_presup); END IF;
  IF v_decide  <> '' THEN v_lineas := v_lineas || ('Decide: ' || v_decide); END IF;
  IF v_cuando  <> '' THEN v_lineas := v_lineas || ('Para cuándo: ' || v_cuando); END IF;
  IF v_correo  <> '' THEN v_lineas := v_lineas || ('Correo: ' || v_correo); END IF;
  IF v_notas   <> '' THEN v_lineas := v_lineas || ('Nota: ' || v_notas); END IF;

  -- ¿Ya tiene una tarjeta abierta en Ventas? Se completa en vez de duplicar.
  SELECT d.id INTO v_deal FROM deals d
   WHERE d.account_id = p_account AND d.contact_id = v_contact
     AND d.pipeline_id = v_pipeline AND d.status = 'open'
   ORDER BY d.created_at DESC LIMIT 1;

  IF v_deal IS NOT NULL THEN
    v_existe := true;
    IF array_length(v_lineas, 1) IS NOT NULL THEN
      UPDATE deals
         SET notes = concat_ws(E'\n', NULLIF(notes, ''),
                               array_to_string(v_lineas, E'\n')),
             title = CASE WHEN v_negocio <> '' AND title = COALESCE(NULLIF(v_nombre, ''), title)
                          THEN v_negocio ELSE title END
       WHERE id = v_deal;
    END IF;
  ELSE
    v_lineas := v_lineas || ('Llegó por ' || v_origen || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);
    INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, status)
    VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
            COALESCE(NULLIF(v_negocio, ''), v_nombre),
            0, 'MXN', array_to_string(v_lineas, E'\n'), 'open')
    RETURNING id INTO v_deal;
  END IF;

  RETURN jsonb_build_object('ok', true, 'deal_id', v_deal, 'existente', v_existe, 'folio', v_folio);
END;
$$;
REVOKE ALL ON FUNCTION public.diagnostico_solicitar(UUID, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.diagnostico_solicitar(UUID, JSONB) TO anon, authenticated, service_role;

-- ------------------------------------------------------------
-- Estado por columna (amplía la de 312 al tablero «Ventas»).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._ap_estado_por_columna()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_columna TEXT;
  v_tablero TEXT;
BEGIN
  SELECT s.name, p.name INTO v_columna, v_tablero
    FROM pipeline_stages s
    JOIN pipelines p ON p.id = s.pipeline_id
   WHERE s.id = NEW.stage_id AND p.name IN ('Cotizaciones', 'Ventas');
  IF v_columna IS NULL THEN
    RETURN NEW;
  END IF;
  IF v_tablero = 'Ventas' THEN
    NEW.status := CASE
      WHEN v_columna ILIKE 'anticipo%' OR v_columna ILIKE 'en implementaci%' OR v_columna ILIKE 'cliente activo%' THEN 'won'
      WHEN v_columna ILIKE 'perdid%' THEN 'lost'
      ELSE 'open'
    END;
  ELSE
    NEW.status := CASE
      WHEN v_columna ILIKE 'ganad%' OR v_columna ILIKE 'entregad%' THEN 'won'
      WHEN v_columna ILIKE 'perdid%' THEN 'lost'
      ELSE 'open'
    END;
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._ap_estado_por_columna() FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Tablero «Ventas» y paquetes (una vez, después de crear la cuenta dueña).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.of_preparar_cuenta(p_account UUID)
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

  SELECT id INTO v_pipeline FROM pipelines WHERE account_id = p_account AND name = 'Ventas';
  IF v_pipeline IS NULL THEN
    INSERT INTO pipelines (user_id, account_id, name) VALUES (v_owner, p_account, 'Ventas')
    RETURNING id INTO v_pipeline;
    INSERT INTO pipeline_stages (pipeline_id, name, position, color) VALUES
      (v_pipeline, 'Nuevo contacto',       0, '#22C55E'),
      (v_pipeline, 'Diagnóstico agendado', 1, '#0EA5E9'),
      (v_pipeline, 'Diagnóstico hecho',    2, '#6366F1'),
      (v_pipeline, 'Propuesta enviada',    3, '#F59E0B'),
      (v_pipeline, 'Anticipo pagado',      4, '#10B981'),
      (v_pipeline, 'En implementación',    5, '#14B8A6'),
      (v_pipeline, 'Cliente activo',       6, '#64748B'),
      (v_pipeline, 'Perdido',              7, '#EF4444');
  END IF;

  INSERT INTO catalogo (account_id, nombre, descripcion, precio, marcas, orden) VALUES
    (p_account, 'Arranque', 'Para que te encuentren.', '$2,500 instalación + $299 al mes',
     'Sitio web con el diseño de tu giro; Dominio a tu nombre y hosting; Perfil de Google creado u optimizado; Botón de WhatsApp y de llamada; Cambios pequeños cada mes', 0),
    (p_account, 'Negocio', 'Para que no se te escape nadie.', '$3,500 instalación + $499 al mes',
     'Todo lo del paquete Arranque; CRM adaptado a tu giro: pedidos, citas o cotizaciones; Avisos al celular cuando entra algo nuevo; Petición de reseñas automática después de cada venta; Reporte mensual con tus números', 1),
    (p_account, 'Pro con IA', 'Para que te atiendan aunque no estés.', '$6,000 instalación + desde $1,200 al mes',
     'Todo lo del paquete Negocio; Agente de IA en tu WhatsApp conectado al CRM; Reconoce a tus clientes de siempre; Recordatorios y mensajes a clientes que dejaron de comprar; 4 publicaciones al mes en tu perfil de Google; Consumo de WhatsApp e IA incluido con tope', 2),
    (p_account, 'A la medida', 'Automatizaciones entre tus sistemas, integraciones, redes, servidores y VPN.', 'Se cotiza según el diagnóstico', NULL, 3),
    (p_account, 'Diagnóstico gratis', 'Llamada para entender cómo funciona el negocio: captación, ventas, cobro y entrega. Se entrega un plan por pasos.', 'Gratis', NULL, 4)
  ON CONFLICT (account_id, nombre) DO NOTHING;

  UPDATE accounts SET default_currency = 'MXN' WHERE id = p_account;
  RETURN jsonb_build_object('ok', true, 'pipeline_id', v_pipeline);
END;
$$;
REVOKE ALL ON FUNCTION public.of_preparar_cuenta(UUID) FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------
-- Avisos a la app de Onlinefreedom.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._avisar_encargo_nuevo()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  PERFORM net.http_post(
    url := 'https://crm-onlinefreedom.vercel.app/api/avisos/evento',
    body := jsonb_build_object('tipo', 'nuevo', 'deal_id', NEW.id),
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public._avisar_encargo_nuevo() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.bot_pasar_a_humano(
  p_account uuid,
  p_conversation uuid,
  p_motivo text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  v_motivo text := left(btrim(COALESCE(p_motivo, '')), 300);
  v_id uuid;
BEGIN
  UPDATE conversations
     SET ai_autoreply_disabled = true,
         ai_handoff_summary    = NULLIF(v_motivo, ''),
         humano_pedido_en      = now(),
         humano_avisado_en     = NULL
   WHERE id = p_conversation
     AND account_id = p_account
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'conversacion_no_encontrada');
  END IF;

  BEGIN
    PERFORM net.http_post(
      url := 'https://crm-onlinefreedom.vercel.app/api/avisos/evento',
      body := jsonb_build_object('tipo', 'humano', 'conversation_id', v_id),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  EXCEPTION WHEN others THEN
    NULL;
  END;

  RETURN jsonb_build_object('ok', true);
END;
$$;
REVOKE ALL ON FUNCTION public.bot_pasar_a_humano(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_pasar_a_humano(uuid, uuid, text) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public._ap_reintentar_avisos_humano()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT id FROM conversations
     WHERE humano_avisado_en IS NULL
       AND humano_pedido_en >= now() - interval '15 minutes'
       AND humano_pedido_en <= now() - interval '20 seconds'
  LOOP
    PERFORM net.http_post(
      url := 'https://crm-onlinefreedom.vercel.app/api/avisos/evento',
      body := jsonb_build_object('tipo', 'humano', 'conversation_id', r.id),
      headers := '{"Content-Type": "application/json"}'::jsonb
    );
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public._ap_reintentar_avisos_humano() FROM PUBLIC, anon, authenticated;

-- Seguimiento: lun–sáb 9 am Saltillo (15:00 UTC), propuestas enviadas sin respuesta.
DO $$
BEGIN
  PERFORM cron.unschedule('ap-seguimiento-cotizaciones')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ap-seguimiento-cotizaciones');
  PERFORM cron.unschedule('of-seguimiento-ventas')
    WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'of-seguimiento-ventas');
  PERFORM cron.schedule(
    'of-seguimiento-ventas',
    '0 15 * * 1-6',
    $job$SELECT net.http_post(
      url := 'https://crm-onlinefreedom.vercel.app/api/avisos/resumen',
      body := '{}'::jsonb,
      headers := '{"Content-Type": "application/json"}'::jsonb
    )$job$
  );
END $$;

NOTIFY pgrst, 'reload schema';
