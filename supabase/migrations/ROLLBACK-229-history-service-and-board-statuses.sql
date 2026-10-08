-- ROLLBACK of 229_history_service_and_board_statuses.sql: restores cerebro_dashboard_historial (088/088b: no servicio column, the
-- filter matches service_type only) and crm_tablero_operaciones (219: awaiting_deposit / deposit_received are filtered out again)
-- exactly. Pre-229 md5 (pg_get_functiondef, staging 2026-10-08; restoring must give the same): cerebro_dashboard_historial
-- 4d077dbeb2d4be9822e84293666913c2; crm_tablero_operaciones d09ded1e35123fcf13a506dbb9dc0427. Nothing is lost: 229 stores no data.
-- Run it only after the app that reads `servicio` is rolled back too, or the history cell falls back to the service_type name
-- (the app tolerates the missing column) but its ledger-style filter values match nothing.

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
               tarjeta text, operation_id uuid, total bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH filtrado AS (
    SELECT h.dia, h.service_type, h.status, h.cliente, h.telefono,
           h.monto_gyd, h.beneficiario, h.tarjeta, h.operation_id
      FROM cerebro_historial_operaciones h
     WHERE (p_desde IS NULL OR h.dia >= p_desde)
       AND (p_hasta IS NULL OR h.dia <= p_hasta)
       AND (p_servicio IS NULL OR h.service_type = p_servicio)
  )
  SELECT f.dia, f.service_type, f.status, f.cliente, f.telefono,
         f.monto_gyd, f.beneficiario, f.tarjeta, f.operation_id,
         count(*) OVER () AS total
    FROM filtrado f
   ORDER BY f.dia DESC, f.monto_gyd DESC, f.operation_id,
            f.tarjeta NULLS LAST, f.beneficiario NULLS LAST
   LIMIT  least(coalesce(p_limite, 200), 1000)
  OFFSET greatest(coalesce(p_desde_fila, 0), 0);
$$;

REVOKE EXECUTE ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerebro_dashboard_historial(date, date, text, integer, integer) TO authenticated, service_role;

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
             WHEN 'deposit_verification'   THEN 2
             WHEN 'ready_to_transfer'      THEN 3
             WHEN 'transferring'           THEN 3
             WHEN 'incident'               THEN 4
             ELSE 5
           END AS col_rank
      FROM remittance_operations o
     WHERE o.account_id = v_account_id
       AND (o.status IN ('collecting_information', 'deposit_verification', 'ready_to_transfer', 'transferring', 'incident')
            OR (o.status = 'completed' AND o.completed_at >= now() - interval '24 hours'))
  ) b
  LEFT JOIN conversations cv ON cv.id = b.conversation_id
  LEFT JOIN contacts c ON c.id = coalesce(b.contact_id, cv.contact_id)
  ORDER BY b.col_rank, b.since;
END $function$;

REVOKE ALL ON FUNCTION public.crm_tablero_operaciones() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_tablero_operaciones() TO authenticated;

NOTIFY pgrst, 'reload schema';
