-- =====================================================================
-- 322 -- Hermes: one meaning for "completada"
--
-- `hermes_resumen_periodo` counted completed operations by `updated_at`, while
-- `hermes_cuadre_finanzas` counts them by `completed_at`. Since `updated_at`
-- moves with any later edit, an operation completed weeks ago but touched in
-- the window counted as completed in the window: the same week read as 147 in
-- one answer and 77 in the other, and every decision built on it was unsound.
--
-- Completed operations now count by `completed_at`, the moment they actually
-- completed. Incidents count by the moment they entered the status
-- (`status_changed_at`), falling back to `updated_at` for older rows.
--
-- Assertion: supabase/staging/assertions/hermes-resumen-completadas.sql.
-- Rollback: ROLLBACK-322-hermes-resumen-completadas.sql.
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
        'completadas', (SELECT count(*) FROM remittance_operations WHERE status = 'completed' AND completed_at >= v_ini AND completed_at < v_fin),
        'incidencias', (SELECT count(*) FROM remittance_operations WHERE status = 'incident' AND coalesce(status_changed_at, updated_at) >= v_ini AND coalesce(status_changed_at, updated_at) < v_fin)),
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
$function$;;

COMMENT ON FUNCTION public.hermes_resumen_periodo(timestamptz, timestamptz, integer) IS
  'Hermes MCP: conversations with activity in the period plus message and operation counts (read-only). Completed operations count by completed_at.';

REVOKE ALL ON FUNCTION public.hermes_resumen_periodo(timestamptz, timestamptz, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.hermes_resumen_periodo(timestamptz, timestamptz, integer) TO service_role;
