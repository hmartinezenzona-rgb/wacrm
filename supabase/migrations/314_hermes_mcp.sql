-- =====================================================================
-- 314 -- Read-only queries for the Hermes MCP tools
--
-- Hermes (the admin business assistant) gets six read-only tools through MCP. The SQL lives here so the panel
-- route only calls RPCs and never composes SQL; every function is SECURITY DEFINER, read-only and returns
-- compact JSON. No writes and no customer data beyond what the admin already sees.
-- Assertion: supabase/staging/assertions/hermes-mcp.sql. Rollback: ROLLBACK-314-hermes-mcp.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.hermes_buscar_conversacion(p_consulta text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH q AS (
    SELECT btrim(coalesce(p_consulta, '')) AS txt, regexp_replace(coalesce(p_consulta, ''), '[^0-9]', '', 'g') AS nums
  )
  SELECT coalesce(jsonb_agg(x ORDER BY x->>'ultima_actividad' DESC), '[]'::jsonb)
    FROM (
      SELECT jsonb_build_object(
               'conversacion', left(v.id::text, 8),
               'conversacion_id', v.id,
               'contacto', coalesce(nullif(c.name, ''), c.phone),
               'telefono', c.phone,
               'estado', v.status,
               'asignada', v.assigned_agent_id IS NOT NULL,
               'ultimo_mensaje', left(coalesce(v.last_message_text, ''), 120),
               'ultima_actividad', to_char(v.last_message_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
             ) AS x
        FROM conversations v
        JOIN contacts c ON c.id = v.contact_id
        CROSS JOIN q
       WHERE v.deleted_at IS NULL
         AND q.txt <> ''
         AND (
              (length(q.nums) >= 6 AND regexp_replace(c.phone, '[^0-9]', '', 'g') LIKE '%' || q.nums || '%')
           OR lower(coalesce(c.name, '')) LIKE '%' || lower(q.txt) || '%'
           OR v.id::text LIKE lower(q.txt) || '%'
         )
       LIMIT 10
    ) t;
$function$;

COMMENT ON FUNCTION public.hermes_buscar_conversacion(text) IS 'Hermes MCP: find conversations by phone digits, name or id prefix (max 10).';

CREATE OR REPLACE FUNCTION public.hermes_leer_mensajes(p_conv text, p_limite integer DEFAULT 50, p_desde timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_conv uuid;
  v_lim int := least(greatest(coalesce(p_limite, 50), 1), 200);
BEGIN
  SELECT v.id INTO v_conv
    FROM conversations v
   WHERE v.id::text LIKE btrim(coalesce(p_conv, '')) || '%'
   ORDER BY v.updated_at DESC
   LIMIT 1;
  IF v_conv IS NULL THEN
    RETURN jsonb_build_object('error', 'conversacion no encontrada');
  END IF;

  RETURN jsonb_build_object(
    'conversacion', left(v_conv::text, 8),
    'mensajes', (
      SELECT coalesce(jsonb_agg(jsonb_build_object(
               'remite', m.sender_type,
               'tipo', m.content_type,
               'hora_utc', to_char(m.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
               'texto', left(CASE WHEN m.content_type = 'text' THEN coalesce(m.content_text, '')
                                  ELSE '[' || m.content_type || ']' END, 800)
             ) ORDER BY m.created_at), '[]'::jsonb)
        FROM (
          SELECT * FROM messages m2
           WHERE m2.conversation_id = v_conv
             AND (p_desde IS NULL OR m2.created_at >= p_desde)
           ORDER BY m2.created_at DESC
           LIMIT v_lim
        ) m
    ));
END;
$function$;

COMMENT ON FUNCTION public.hermes_leer_mensajes(text, integer, timestamptz) IS 'Hermes MCP: last messages of a conversation (id prefix), oldest first.';

CREATE OR REPLACE FUNCTION public.hermes_listar_operaciones(p_conv text DEFAULT NULL, p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH c AS (
    SELECT v.id
      FROM conversations v
     WHERE nullif(btrim(coalesce(p_conv, '')), '') IS NOT NULL
       AND v.id::text LIKE btrim(p_conv) || '%'
     LIMIT 1
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'operacion', left(o.id::text, 8),
           'conversacion', left(o.conversation_id::text, 8),
           'servicio', o.service_type,
           'estado', o.status,
           'origen_gyd', o.quoted_source_amount,
           'creada', to_char(o.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
           'actualizada', to_char(o.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
         ) ORDER BY o.created_at DESC), '[]'::jsonb)
    FROM remittance_operations o
   WHERE (nullif(btrim(coalesce(p_conv, '')), '') IS NULL OR o.conversation_id = (SELECT id FROM c))
     AND (p_desde IS NULL OR o.updated_at >= p_desde)
     AND (p_hasta IS NULL OR o.updated_at <= p_hasta)
   LIMIT 200;
$function$;

COMMENT ON FUNCTION public.hermes_listar_operaciones(text, timestamptz, timestamptz) IS 'Hermes MCP: operations by conversation and/or period (max 200).';

CREATE OR REPLACE FUNCTION public.hermes_ver_calculadora(p_desde date DEFAULT NULL, p_hasta date DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH r AS (
    SELECT * FROM remittance_calculator_entries e
     WHERE e.deleted_at IS NULL
       AND (p_desde IS NULL OR e.entry_date >= p_desde)
       AND (p_hasta IS NULL OR e.entry_date <= p_hasta)
  )
  SELECT jsonb_build_object(
    'lineas', coalesce((SELECT jsonb_agg(jsonb_build_object(
                 'fecha', e.entry_date, 'servicio', e.service, 'estado', e.status,
                 'cliente', left(coalesce(e.customer_name, ''), 60),
                 'monto', e.amount, 'moneda', e.amount_currency,
                 'facturado_gyd', e.facturado_gyd, 'retorno_gyd', e.retorno_gyd)
               ORDER BY e.entry_date DESC, e.created_at DESC)
               FROM (SELECT * FROM r ORDER BY entry_date DESC, created_at DESC LIMIT 300) e), '[]'::jsonb),
    'totales', (SELECT jsonb_build_object(
                 'lineas', count(*),
                 'facturado_gyd', coalesce(sum(facturado_gyd), 0),
                 'retorno_gyd', coalesce(sum(retorno_gyd), 0))
               FROM r)
  );
$function$;

COMMENT ON FUNCTION public.hermes_ver_calculadora(date, date) IS 'Hermes MCP: calculator lines and totals for a period (max 300 lines).';

CREATE OR REPLACE FUNCTION public.hermes_alertas(p_desde timestamptz DEFAULT NULL, p_hasta timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  WITH d AS (SELECT coalesce(p_desde, now() - interval '1 day') AS d_ini,
                    coalesce(p_hasta, now()) AS d_fin)
  SELECT jsonb_build_object(
    'ingesta_perdida', (SELECT coalesce(jsonb_agg(jsonb_build_object('conv', left(i.conversation_id::text, 8),
                          'hora_utc', to_char(i.message_created_at AT TIME ZONE 'UTC', 'HH24:MI')) ORDER BY i.message_created_at), '[]'::jsonb)
                        FROM cerebro_ingesta_perdida i, d
                       WHERE i.message_created_at BETWEEN d.d_ini AND d.d_fin),
    'promesas_sin_escritura', (SELECT coalesce(jsonb_agg(jsonb_build_object('conv', left(p.conversation_id::text, 8),
                          'hora_utc', to_char(p.message_created_at AT TIME ZONE 'UTC', 'HH24:MI')) ORDER BY p.message_created_at), '[]'::jsonb)
                        FROM cerebro_promesas_sin_escritura p, d
                       WHERE p.message_created_at BETWEEN d.d_ini AND d.d_fin),
    'chats_atascados', (SELECT coalesce(jsonb_agg(jsonb_build_object('conv', left(n.conversation_id::text, 8),
                          'hora_utc', to_char(n.created_at AT TIME ZONE 'UTC', 'HH24:MI')) ORDER BY n.created_at), '[]'::jsonb)
                        FROM notifications n, d
                       WHERE n.type = 'chat_atascado' AND n.created_at BETWEEN d.d_ini AND d.d_fin),
    'outbox', (SELECT jsonb_build_object(
                 'pending', count(*) FILTER (WHERE status = 'pending'),
                 'failed', count(*) FILTER (WHERE status = 'failed'),
                 'sent', count(*) FILTER (WHERE status = 'sent'))
               FROM webhook_outbox)
  );
$function$;

COMMENT ON FUNCTION public.hermes_alertas(timestamptz, timestamptz) IS 'Hermes MCP: risk alerts (ingestion, promises, stuck chats, outbox health) for a period.';

CREATE OR REPLACE FUNCTION public.hermes_tasas()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
  SELECT jsonb_build_object(
    'tasas', (SELECT coalesce(jsonb_agg(jsonb_build_object('moneda', moneda, 'valor', tasa_cup,
                        'fecha', to_char(fecha, 'YYYY-MM-DD')) ORDER BY moneda), '[]'::jsonb)
                FROM (SELECT DISTINCT ON (moneda) * FROM tasas ORDER BY moneda, fecha DESC, actualizada_at DESC) t),
    'arq', cerebro_tasa_usd_mxn_estado(),
    'minimos', (SELECT coalesce(jsonb_object_agg(clave, valor), '{}'::jsonb)
                  FROM cerebro_config WHERE clave LIKE 'minimo_%')
  );
$function$;

COMMENT ON FUNCTION public.hermes_tasas() IS 'Hermes MCP: published rates, ARQ USD-MXN state and configured minimums.';

REVOKE ALL ON FUNCTION public.hermes_buscar_conversacion(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hermes_leer_mensajes(text, integer, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hermes_listar_operaciones(text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hermes_ver_calculadora(date, date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hermes_alertas(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.hermes_tasas() FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION public.hermes_buscar_conversacion(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.hermes_leer_mensajes(text, integer, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.hermes_listar_operaciones(text, timestamptz, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.hermes_ver_calculadora(date, date) TO service_role;
GRANT EXECUTE ON FUNCTION public.hermes_alertas(timestamptz, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION public.hermes_tasas() TO service_role;
