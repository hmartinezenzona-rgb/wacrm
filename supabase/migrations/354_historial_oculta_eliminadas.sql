-- 354 — The operations history hides operations deleted from the panel.
--
-- Redefines crm_historial_operaciones and crm_historial_estados (351) with the same signatures, SECURITY DEFINER,
-- search_path and grants. Only the `base` CTE changes: an operation is excluded when its status is 'cancelled' AND the
-- latest remittance_admin_audit row for it (table_name 'remittance_operations', row_id = operation id) whose
-- after->>'status' = 'cancelled' has action 'human_operation_deleted' (written by crm_eliminar_operacion). Other cancelled
-- operations (human_correction, merges, bot cancellations) keep showing. The exclusion sits in `base`, before the service /
-- search filters, so rows, `total`, pagination and the per-group counts stay consistent.

CREATE OR REPLACE FUNCTION public.crm_historial_operaciones(
    p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_servicio text DEFAULT NULL::text,
    p_estado text DEFAULT NULL::text, p_buscar text DEFAULT NULL::text,
    p_limite integer DEFAULT 50, p_desde_fila integer DEFAULT 0)
 RETURNS TABLE(dia date, service_type text, status text, cliente text, telefono text, monto_gyd numeric, beneficiario text,
               tarjeta text, operation_id uuid, total bigint, servicio text, conversation_id uuid,
               operacion_at timestamp with time zone, estado_grupo text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH q AS (
    SELECT nullif(btrim(coalesce(p_buscar, '')), '') AS t,
           CASE WHEN btrim(coalesce(p_buscar, '')) ~ '^[0-9+()./\s-]+$' THEN nullif(regexp_replace(p_buscar, '\D', '', 'g'), '') END AS d,
           CASE WHEN btrim(coalesce(p_estado, '')) IN ('', 'all') THEN NULL ELSE btrim(p_estado) END AS g
  ),
  base AS (
    SELECT h.dia, h.service_type, h.status, h.cliente, h.telefono,
           h.monto_gyd, h.beneficiario, h.tarjeta, h.operation_id
      FROM cerebro_historial_operaciones h, q
     WHERE (p_desde IS NULL OR h.dia >= p_desde)
       AND (p_hasta IS NULL OR h.dia <= p_hasta)
       AND NOT (h.status = 'cancelled'
                AND coalesce((SELECT a.action
                                FROM remittance_admin_audit a
                               WHERE a.table_name = 'remittance_operations'
                                 AND a.row_id = h.operation_id
                                 AND a.after ->> 'status' = 'cancelled'
                               ORDER BY a.created_at DESC, a.id DESC
                               LIMIT 1), '') = 'human_operation_deleted')
       AND (q.g IS NULL OR crm_historial_estado_grupo(h.status) = q.g)
  ),
  svc AS (
    SELECT o.id AS operation_id, o.conversation_id,
           COALESCE(o.completed_at, o.updated_at) AS operacion_at,
           coalesce(
             CASE WHEN o.service_type = 'mexico' THEN 'MEXICO'
                  ELSE calculator_resolve_operation_service(o.id, o.delivery_method) END,
             CASE WHEN o.service_type = 'remesa'
                   AND (lower(coalesce(o.delivery_method, '')) = 'multiple_distribution'
                        OR (SELECT count(DISTINCT b.beneficiary_type)
                              FROM remittance_beneficiaries b
                             WHERE b.operation_id = o.id AND b.status = 'vigente') > 1)
                  THEN 'MIXTA'
                  ELSE upper(o.service_type)
             END) AS servicio
      FROM remittance_operations o
     WHERE o.id IN (SELECT DISTINCT x.operation_id FROM base x)
  ),
  filtrado AS (
    SELECT b.*, s.servicio, s.conversation_id, s.operacion_at
      FROM base b
      JOIN svc s ON s.operation_id = b.operation_id, q
     WHERE (p_servicio IS NULL OR b.service_type = p_servicio OR upper(s.servicio) = upper(p_servicio))
       AND (q.t IS NULL
            OR strpos(lower(coalesce(b.cliente, '')), lower(q.t)) > 0
            OR (q.d IS NOT NULL AND strpos(regexp_replace(coalesce(b.telefono, ''), '\D', '', 'g'), q.d) > 0)
            OR left(b.operation_id::text, length(q.t)) = lower(q.t))
  )
  SELECT f.dia, f.service_type, f.status, f.cliente, f.telefono,
         f.monto_gyd, f.beneficiario, f.tarjeta, f.operation_id,
         count(*) OVER () AS total, f.servicio, f.conversation_id, f.operacion_at,
         crm_historial_estado_grupo(f.status) AS estado_grupo
    FROM filtrado f
   ORDER BY f.dia DESC, f.operacion_at DESC, f.monto_gyd DESC, f.operation_id,
            f.tarjeta NULLS LAST, f.beneficiario NULLS LAST
   LIMIT  least(greatest(coalesce(p_limite, 50), 1), 200)
  OFFSET greatest(coalesce(p_desde_fila, 0), 0);
$function$;

CREATE OR REPLACE FUNCTION public.crm_historial_estados(
    p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date, p_servicio text DEFAULT NULL::text,
    p_buscar text DEFAULT NULL::text)
 RETURNS TABLE(grupo text, cantidad bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH q AS (
    SELECT nullif(btrim(coalesce(p_buscar, '')), '') AS t,
           CASE WHEN btrim(coalesce(p_buscar, '')) ~ '^[0-9+()./\s-]+$' THEN nullif(regexp_replace(p_buscar, '\D', '', 'g'), '') END AS d
  ),
  base AS (
    SELECT h.service_type, h.status, h.cliente, h.telefono, h.operation_id
      FROM cerebro_historial_operaciones h
     WHERE (p_desde IS NULL OR h.dia >= p_desde)
       AND (p_hasta IS NULL OR h.dia <= p_hasta)
       AND NOT (h.status = 'cancelled'
                AND coalesce((SELECT a.action
                                FROM remittance_admin_audit a
                               WHERE a.table_name = 'remittance_operations'
                                 AND a.row_id = h.operation_id
                                 AND a.after ->> 'status' = 'cancelled'
                               ORDER BY a.created_at DESC, a.id DESC
                               LIMIT 1), '') = 'human_operation_deleted')
  ),
  svc AS (
    SELECT o.id AS operation_id,
           coalesce(
             CASE WHEN o.service_type = 'mexico' THEN 'MEXICO'
                  ELSE calculator_resolve_operation_service(o.id, o.delivery_method) END,
             CASE WHEN o.service_type = 'remesa'
                   AND (lower(coalesce(o.delivery_method, '')) = 'multiple_distribution'
                        OR (SELECT count(DISTINCT b.beneficiary_type)
                              FROM remittance_beneficiaries b
                             WHERE b.operation_id = o.id AND b.status = 'vigente') > 1)
                  THEN 'MIXTA'
                  ELSE upper(o.service_type)
             END) AS servicio
      FROM remittance_operations o
     WHERE o.id IN (SELECT DISTINCT x.operation_id FROM base x)
  ),
  filtrado AS (
    SELECT b.status
      FROM base b
      JOIN svc s ON s.operation_id = b.operation_id, q
     WHERE (p_servicio IS NULL OR b.service_type = p_servicio OR upper(s.servicio) = upper(p_servicio))
       AND (q.t IS NULL
            OR strpos(lower(coalesce(b.cliente, '')), lower(q.t)) > 0
            OR (q.d IS NOT NULL AND strpos(regexp_replace(coalesce(b.telefono, ''), '\D', '', 'g'), q.d) > 0)
            OR left(b.operation_id::text, length(q.t)) = lower(q.t))
  )
  SELECT g.grupo, count(f.status) AS cantidad
    FROM (VALUES ('completed'), ('in_progress'), ('incident'), ('cancelled')) AS g(grupo)
    LEFT JOIN filtrado f ON crm_historial_estado_grupo(f.status) = g.grupo
   GROUP BY g.grupo
   ORDER BY array_position(ARRAY['completed', 'in_progress', 'incident', 'cancelled'], g.grupo);
$function$;

REVOKE ALL ON FUNCTION public.crm_historial_operaciones(date, date, text, text, text, integer, integer) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_historial_operaciones(date, date, text, text, text, integer, integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.crm_historial_estados(date, date, text, text) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crm_historial_estados(date, date, text, text) TO authenticated, service_role;
