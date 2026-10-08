-- =====================================================================
-- 229 -- Finanzas history names the specific service; the board keeps the two orphan statuses (staging first)
--
-- odd/tasks/unified-service-names.md (H1, H2). Owner request: the Finanzas history said "Remesa" for every remittance while the
-- Calculator and the close say CUP / Zelle / Clasica...; one vocabulary, and the history filter uses the same list.
--   * cerebro_dashboard_historial gets ONE extra trailing column, servicio text: the ledger-style service of the OPERATION,
--     from calculator_resolve_operation_service(operation_id, delivery_method) (223, not re-implemented). When that is NULL: a
--     remesa whose recipients are of more than one kind (or delivery_method multiple_distribution) is 'MIXTA'; anything else
--     is upper(service_type) ('REMESA', 'TRADUCCION', 'MEXICO'). It is resolved ONCE per operation (a CTE over the distinct
--     operations of the filtered window), not per recipient row. The row grain (one row per current recipient) does not change.
--   * The p_servicio filter keeps the old service_type values (remesa, recarga, ...) so the deployed app keeps working, and
--     also accepts the ledger-style values (CUP, ZELLE, CLASICA, ...; case-insensitive): a row matches when p_servicio equals
--     its service_type OR equals its servicio. total still counts the whole filtered set.
--   * The return type changes, so the function is DROPped and created again (088 did the same). Its ACL is restored exactly as
--     088/088b left it: EXECUTE for authenticated and service_role, nothing for PUBLIC / anon (checked with has_function_privilege
--     in the assertion). The signature (date, date, text, integer, integer) and the argument defaults are unchanged, so the
--     deployed app's four- and five-argument calls still resolve and simply ignore the extra column.
--   * cerebro_historial_operaciones is NOT changed (the RPC reads delivery_method from remittance_operations itself).
--   * crm_tablero_operaciones (219): the WHERE also keeps awaiting_deposit and deposit_received (allowed by the status CHECK,
--     unused today, so they would vanish from the board), ranked with collecting_information (1) and deposit_verification (2).
--     Nothing else in the function changes.
-- Pre-229 md5 on staging (2026-10-08, pg_get_functiondef; the ROLLBACK restores exactly these): cerebro_dashboard_historial
-- 4d077dbeb2d4be9822e84293666913c2; crm_tablero_operaciones d09ded1e35123fcf13a506dbb9dc0427. The view
-- cerebro_historial_operaciones (md5 of pg_get_viewdef b744d92520d67fa9180e7fd760425904) is untouched.
-- Guarded by supabase/staging/assertions/history-service-and-board-statuses.sql. ROLLBACK: ROLLBACK-229-history-service-and-board-statuses.sql
-- =====================================================================

DROP FUNCTION IF EXISTS public.cerebro_dashboard_historial(date, date, text, integer, integer);

CREATE FUNCTION public.cerebro_dashboard_historial(
  p_desde      date    DEFAULT NULL,
  p_hasta      date    DEFAULT NULL,
  p_servicio   text    DEFAULT NULL,
  p_limite     integer DEFAULT 200,
  p_desde_fila integer DEFAULT 0
)
RETURNS TABLE (dia date, service_type text, status text, cliente text,
               telefono text, monto_gyd numeric, beneficiario text,
               tarjeta text, operation_id uuid, total bigint, servicio text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH base AS (
    SELECT h.dia, h.service_type, h.status, h.cliente, h.telefono,
           h.monto_gyd, h.beneficiario, h.tarjeta, h.operation_id
      FROM cerebro_historial_operaciones h
     WHERE (p_desde IS NULL OR h.dia >= p_desde)
       AND (p_hasta IS NULL OR h.dia <= p_hasta)
  ),
  -- (229) The ledger-style service, once per operation (not per recipient row).
  svc AS (
    SELECT o.id AS operation_id,
           coalesce(
             calculator_resolve_operation_service(o.id, o.delivery_method),
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
    SELECT b.*, s.servicio
      FROM base b
      JOIN svc s ON s.operation_id = b.operation_id
     WHERE p_servicio IS NULL
        OR b.service_type = p_servicio
        OR upper(s.servicio) = upper(p_servicio)
  )
  SELECT f.dia, f.service_type, f.status, f.cliente, f.telefono,
         f.monto_gyd, f.beneficiario, f.tarjeta, f.operation_id,
         count(*) OVER () AS total, f.servicio
    FROM filtrado f
   ORDER BY f.dia DESC, f.monto_gyd DESC, f.operation_id,
            f.tarjeta NULLS LAST, f.beneficiario NULLS LAST
   LIMIT  least(coalesce(p_limite, 200), 1000)
  OFFSET greatest(coalesce(p_desde_fila, 0), 0);
$$;

REVOKE EXECUTE ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) TO authenticated, service_role;

-- PostgREST caches function signatures.
NOTIFY pgrst, 'reload schema';

CREATE OR REPLACE FUNCTION public.crm_tablero_operaciones()
RETURNS TABLE(
  operation_id           uuid,
  conversation_id        uuid,
  contact_name           text,
  contact_phone          text,
  service_type           text,
  delivery_method        text,
  status                 text,
  quoted_source_amount   numeric,
  source_currency        text,
  created_at             timestamptz,
  completed_at           timestamptz,
  state_since            timestamptz,
  beneficiaries_complete boolean
)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
BEGIN
  SELECT p.account_id INTO v_account_id
    FROM profiles p
   WHERE p.user_id = auth.uid()
   LIMIT 1;

  IF v_account_id IS NULL OR NOT is_account_member(v_account_id, 'viewer') THEN
    RAISE EXCEPTION 'insufficient_privilege' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.conversation_id,
    c.name,
    c.phone,
    b.service_type,
    b.delivery_method,
    b.status,
    b.quoted_source_amount,
    b.source_currency,
    b.created_at,
    b.completed_at,
    b.since,
    crm_beneficiarios_completos(b.id)
  FROM (
    SELECT o.*,
           CASE
             WHEN o.status = 'completed' THEN coalesce(o.completed_at, o.status_changed_at, o.updated_at)
             ELSE coalesce(
               o.status_changed_at,
               (SELECT max(a.created_at)
                  FROM remittance_admin_audit a
                 WHERE a.table_name = 'remittance_operations'
                   AND a.row_id = o.id
                   AND a.field_name = 'status'
                   AND a.after ->> 'status' = o.status),
               o.updated_at)
           END AS since,
           CASE o.status
             WHEN 'collecting_information' THEN 1
             WHEN 'awaiting_deposit'       THEN 1
             WHEN 'deposit_verification'   THEN 2
             WHEN 'deposit_received'       THEN 2
             WHEN 'ready_to_transfer'      THEN 3
             WHEN 'transferring'           THEN 3
             WHEN 'incident'               THEN 4
             ELSE 5
           END AS col_rank
      FROM remittance_operations o
     WHERE o.account_id = v_account_id
       AND (o.status IN ('collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer', 'transferring', 'incident')
            OR (o.status = 'completed' AND o.completed_at >= now() - interval '24 hours'))
  ) b
  LEFT JOIN conversations cv ON cv.id = b.conversation_id
  LEFT JOIN contacts c ON c.id = coalesce(b.contact_id, cv.contact_id)
  ORDER BY b.col_rank, b.since;
END $function$;

REVOKE ALL ON FUNCTION public.crm_tablero_operaciones() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_tablero_operaciones() TO authenticated;
