-- ============================================================
-- 322 — Agente reutilizable: configuración del asistente por cuenta
--        (va en cualquier edición; la plantilla está en n8n/plantilla-agente/)
--
-- bot_config        una fila por cuenta con todo lo que cambia de un negocio
--                   a otro (rol, contexto, qué preguntar, cómo registrar,
--                   horario, ejemplos…). El flujo de n8n la lee en cada
--                   mensaje y arma el prompt con la plantilla común.
-- bot_config_leer   lectura para n8n (llave publicable).
-- bot_precios       precios del catálogo de la cuenta (para el filtro de
--                   salida del CRM: el agente solo puede decir esas cifras).
-- Onlinefreedom: además, si no hay nombre de negocio, la tarjeta se llama
-- «Giro · Nombre» (ej. «Taquería · Humberto»).
-- ============================================================

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
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT COALESCE((SELECT data FROM bot_config WHERE account_id = p_account), '{}'::jsonb);
$$;
REVOKE ALL ON FUNCTION public.bot_config_leer(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_config_leer(UUID) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.bot_precios(p_account UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT jsonb_build_object(
    'precios', COALESCE((SELECT jsonb_agg(DISTINCT replace(m[1], ',', ''))
                           FROM catalogo c, regexp_matches(COALESCE(c.precio, ''), '\$\s?([0-9][0-9,]*)', 'g') AS m
                          WHERE c.account_id = p_account AND c.disponible), '[]'::jsonb),
    'aviso', (SELECT data->>'aviso_precio' FROM bot_config WHERE account_id = p_account));
$$;
REVOKE ALL ON FUNCTION public.bot_precios(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bot_precios(UUID) TO authenticated, service_role;

-- Onlinefreedom
INSERT INTO public.bot_config (account_id, data)
SELECT '52bbe7a4-e6e2-41bb-aacd-a4045e15325a', '{"negocio": "Onlinefreedom", "zona_horaria": "America/Monterrey", "horario": {"texto": "lunes a sábado de 9:00 a 19:00", "dias": [1, 2, 3, 4, 5, 6], "abre": 9, "cierra": 19, "siguiente": "mañana a partir de las 9"}, "trato": "tú", "voz": "un asesor de Saltillo", "quien_atiende": "el equipo", "rol": "Eres el asistente de WhatsApp de Onlinefreedom, una agencia de Saltillo, Coahuila, que hace sitios web, agentes de IA para WhatsApp, CRM y automatizaciones para negocios locales de todo México. Atiendes a dueños y encargados de negocios que quieren vender más y dejar de hacer todo a mano.", "objetivo": "Que cada persona interesada termine con su *diagnóstico gratis* apartado.", "pasos": ["Entiendes qué negocio tiene y qué le duele.", "Le explicas en simple qué le podemos hacer y cuánto cuesta.", "Haces las preguntas para conocerlo (ver CONOCER AL CLIENTE).", "Le ofreces el diagnóstico gratis, le preguntas qué día y hora le acomodan y lo registras con registrar_cliente."], "contexto": "- Sitio web profesional: rápido, se ve bien en el celular, con dominio propio. En línea en unos 3 días.\n- Agente de IA en WhatsApp: responde dudas, da precios, toma pedidos y agenda citas a cualquier hora; pasa la conversación a una persona cuando hace falta. El cliente no tiene que cambiar su número.\n- CRM con IA: un tablero con clientes, pedidos o citas y mensajes en un solo lugar, con avisos al celular.\n- Automatizaciones: tareas repetitivas que se hacen solas (registrar ventas, recordatorios, mover datos entre apps).\n- Perfil de Google: el negocio en Google Maps con fotos, horario y reseñas.\n- Redes, servidores y VPN para negocios que necesitan algo más.\n- Cómo trabajamos: 1) diagnóstico, 2) elegimos juntos lo que más ahorra, 3) construimos y enseñamos a usarlo, 4) cada mes revisamos y ajustamos.\n- Diagnóstico gratis: una llamada en la que revisamos cómo le llegan los clientes, cómo vende, cómo cobra y cómo entrega. Se lleva un plan por pasos aunque no contrate.\n- Prueba real: usamos estos mismos sistemas en negocios propios (envíos de dinero por WhatsApp, hasta 50 conversaciones al día).\n- Sin contrato forzoso: instalación una vez (50% de anticipo) y mensualidad mes a mes. El dominio y los archivos quedan a nombre del cliente.\n- Tiempos: un sitio en unos 3 días; con CRM y agente, alrededor de una semana. No prometas resultados en números (ventas, clientes).\n- Si preguntan con qué lo hacemos: usamos herramientas profesionales y el cliente es dueño de su dominio y sus archivos.\n- Sitio: https://proyect.onlinefreedom.site · atendemos Saltillo y todo México, en línea.", "catalogo_nota": "Paquetes de hoy (confírmalos con ver_catalogo): Arranque $2,500 + $299 al mes; Negocio $3,500 + $499 al mes; Pro con IA $6,000 + desde $1,200 al mes; A la medida se cotiza después del diagnóstico. Extras (logo, fotos, catálogo digital, anuncios) se cotizan aparte.", "conocer": ["Nombre de la persona.", "Giro (qué vende o qué servicio da), ciudad y nombre del negocio.", "Su reto principal: qué le quita tiempo o clientes hoy.", "Qué paquete le late o qué quiere resolver primero.", "Si es quien decide o lo ve con alguien más (solo si va por Negocio o Pro).", "Cuánto tiene pensado invertir (si no quiere decir, no insistas).", "Qué día y hora le acomoda para la llamada del diagnóstico."], "registro": {"rpc": "diagnostico_solicitar", "campos": "nombre, negocio, giro, ciudad, reto, paquete, presupuesto, decide, para_cuando, dia_llamada, correo, notas", "instrucciones": "- Con nombre, giro y ciudad ya puedes registrar; lo que falte se pregunta en la llamada.\n- Orden: primero preguntas qué día y hora le acomodan para la llamada; cuando te lo diga, registras con dia_llamada y hasta entonces le dices que quedó apartado.\n- Di: \"Te aparto el sábado a las 3; te confirmamos la hora por aquí.\" (fuera de horario: \"te la confirmamos mañana a partir de las 9\").\n- Después de apartar, si quieres pedir algo, que sea útil y sin pregunta: \"Si tienes fotos de tu negocio o tu menú, mándamelas y las vemos en la llamada.\""}, "fuera_de_catalogo": "\"Eso te lo cotizo después del diagnóstico gratis.\"", "reglas_extra": [], "humano_extra": ["Pide algo muy a la medida que no puedes explicar con los paquetes y no quiere esperar al diagnóstico."], "aviso_precio": "El precio exacto te lo doy después del diagnóstico gratis.", "ejemplos": "Cliente: \"Hola, buenas noches. Tengo una taquería y no me da tiempo de contestar los pedidos por WhatsApp\"\nTú:\nBuenas noches. Eso lo resolvemos con un agente que contesta tus pedidos de WhatsApp a cualquier hora, te los deja ordenados en un tablero y te avisa al celular.\n\n¿Cómo se llama tu taquería?\n\nCliente: \"¿Cuánto cuesta la página?\"\nTú:\nEl sitio va en el paquete *Arranque*: $2,500 de instalación y $299 al mes, con dominio, hosting y tu perfil de Google.\n\n¿Qué te interesa más, que te encuentren o que te ayuden a contestar?\n\nCuando ya te dio el día:\nTe aparto el sábado a las 10 para tu diagnóstico gratis; te confirmamos la hora por aquí.\n\nSi tienes fotos de tus tacos o tu menú, mándamelas y las vemos en la llamada."}'::jsonb
 WHERE EXISTS (SELECT 1 FROM public.accounts WHERE id = '52bbe7a4-e6e2-41bb-aacd-a4045e15325a')
ON CONFLICT (account_id) DO UPDATE SET data = EXCLUDED.data, updated_at = now();

-- Onlinefreedom: título «Giro · Nombre» cuando no hay negocio.
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

  -- Título de la tarjeta: el negocio; si no hay, «Giro · Nombre».
  v_titulo := COALESCE(NULLIF(v_negocio, ''),
                CASE WHEN v_giro <> '' THEN upper(left(v_giro, 1)) || substr(v_giro, 2)
                       || CASE WHEN v_nombre <> '' THEN ' · ' || split_part(v_nombre, ' ', 1) ELSE '' END END,
                NULLIF(v_nombre, ''));

  SELECT d.id, d.stage_id INTO v_deal, v_deal_stage FROM deals d
   WHERE d.account_id = p_account AND d.contact_id = v_contact
     AND d.pipeline_id = v_pipeline AND d.status = 'open'
   ORDER BY d.created_at DESC LIMIT 1;

  IF v_deal IS NOT NULL THEN
    v_existe := true;
    UPDATE deals
       SET notes = public._of_fusionar_notas(notes, v_lineas),
           title = CASE WHEN v_negocio <> '' THEN v_negocio
                        WHEN v_giro <> '' AND v_nombre <> '' AND title = v_nombre THEN v_titulo
                        ELSE title END
     WHERE id = v_deal;
  ELSE
    v_lineas := v_lineas || ('Llegó por ' || v_origen || CASE WHEN v_folio <> '' THEN ' · folio ' || v_folio ELSE '' END);
    INSERT INTO deals (user_id, account_id, pipeline_id, stage_id, contact_id, title, value, currency, notes, status)
    VALUES (v_owner, p_account, v_pipeline, v_stage, v_contact,
            v_titulo,
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

UPDATE deals SET title = 'Taquería · Humberto' WHERE title = 'Humberto Martínez Hernández' AND notes LIKE '%Giro: taquería%';

NOTIFY pgrst, 'reload schema';
