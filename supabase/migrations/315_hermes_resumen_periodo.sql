-- =====================================================================
-- 315 -- Hermes: period summary (conversations with activity + counts)
--
-- Hermes could not count or list a day's conversations: buscar_conversacion needs a query. The daily report and
-- "how did the day go" need exactly that, so this read-only function returns the conversations with any message
-- in the period plus the day's counts. Same rules as 314: SECURITY DEFINER, read-only, service_role only.
-- Assertion: supabase/staging/assertions/hermes-resumen-periodo.sql.
-- Rollback: ROLLBACK-315-hermes-resumen-periodo.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.hermes_resumen_periodo(
  p_desde timestamptz DEFAULT NULL,
  p_hasta timestamptz DEFAULT NULL,
  p_limite integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_ini timestamptz := coalesce(p_desde, ((now() AT TIME ZONE 'America/Guyana')::date + time '09:00') AT TIME ZONE 'America/Guyana');
  v_fin timestamptz := coalesce(p_hasta, now());
  v_lim integer := least(greatest(coalesce(p_limite, 200), 1), 500);
BEGIN
  RETURN (
    WITH msgs AS (
      SELECT m.conversation_id, m.sender_type
        FROM messages m
       WHERE m.created_at >= v_ini AND m.created_at < v_fin
    ),
    conv AS (
      SELECT x.conversation_id,
             coalesce(nullif(c.name, ''), c.phone) AS contacto,
             c.phone,
             count(*) FILTER (WHERE x.sender_type = 'customer') AS de_cliente,
             count(*) FILTER (WHERE x.sender_type = 'agent') AS del_bot,
             max(v.last_message_at) AS ultima
        FROM msgs x
        JOIN conversations v ON v.id = x.conversation_id
        JOIN contacts c ON c.id = v.contact_id
       GROUP BY 1, 2, 3
    ),
    ops AS (
      SELECT o.id, o.status, o.service_type, o.created_at, o.updated_at
        FROM remittance_operations o
       WHERE (o.created_at >= v_ini AND o.created_at < v_fin)
          OR (o.updated_at >= v_ini AND o.updated_at < v_fin)
    )
    SELECT jsonb_build_object(
      'desde', to_char(v_ini AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
      'hasta', to_char(v_fin AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
      'totales', jsonb_build_object(
        'conversaciones', (SELECT count(*) FROM conv),
        'mensajes_cliente', (SELECT count(*) FROM msgs WHERE sender_type = 'customer'),
        'mensajes_bot', (SELECT count(*) FROM msgs WHERE sender_type = 'agent'),
        'operaciones_creadas', (SELECT count(*) FROM ops WHERE created_at >= v_ini AND created_at < v_fin),
        'operaciones_actualizadas', (SELECT count(*) FROM ops),
        'completadas', (SELECT count(*) FROM remittance_operations WHERE status = 'completed' AND updated_at >= v_ini AND updated_at < v_fin),
        'incidencias', (SELECT count(*) FROM remittance_operations WHERE status = 'incident' AND updated_at >= v_ini AND updated_at < v_fin)),
      'conversaciones', coalesce((
        SELECT jsonb_agg(jsonb_build_object(
                 'conv', left(t.conversation_id::text, 8),
                 'contacto', t.contacto,
                 'telefono', t.phone,
                 'de_cliente', t.de_cliente,
                 'del_bot', t.del_bot,
                 'ultima_utc', to_char(t.ultima AT TIME ZONE 'UTC', 'HH24:MI'))
               ORDER BY t.ultima DESC)
          FROM (SELECT * FROM conv ORDER BY ultima DESC LIMIT v_lim) t), '[]'::jsonb)));
END;
$function$;

COMMENT ON FUNCTION public.hermes_resumen_periodo(timestamptz, timestamptz, integer) IS
  'Hermes MCP: conversations with activity in the period plus message and operation counts (read-only).';

REVOKE ALL ON FUNCTION public.hermes_resumen_periodo(timestamptz, timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hermes_resumen_periodo(timestamptz, timestamptz, integer) TO service_role;
