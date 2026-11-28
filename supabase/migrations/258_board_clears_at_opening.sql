-- =====================================================================
-- 258: the operations board clears completed operations at the business opening.
--
-- Before: crm_tablero_operaciones returned completed operations with completed_at >= now() - 24 h (a rolling window), so
-- yesterday afternoon's completions stayed on the board until the next afternoon.
-- Now: completed operations show only since the last business opening, crm_tablero_corte(now()): today's opening time
-- (Guyana time) once it has passed, otherwise yesterday's. The opening time comes from cerebro_horario() (cerebro_config
-- horario_abre, default 09:00), the single source of business hours (136). Open statuses are unchanged.
-- The board body is 229's with only the completed filter replaced; signature, result columns and grants are unchanged.
--
-- ROLLBACK: ROLLBACK-258-board-clears-at-opening.sql
-- Guarded by supabase/staging/assertions/board-clears-at-opening.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_tablero_corte(p_ahora timestamptz DEFAULT now())
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT ((((p_ahora AT TIME ZONE 'America/Guyana')::date
            - CASE WHEN (p_ahora AT TIME ZONE 'America/Guyana')::time < h.abre THEN 1 ELSE 0 END)
           + h.abre) AT TIME ZONE 'America/Guyana')
    FROM cerebro_horario() h
$function$;

COMMENT ON FUNCTION public.crm_tablero_corte(timestamptz) IS
  '258. Last business opening at or before p_ahora (Guyana time, opening from cerebro_horario()); the board shows completed operations since then.';
REVOKE ALL ON FUNCTION public.crm_tablero_corte(timestamptz) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.crm_tablero_corte(timestamptz) TO service_role;

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
            OR (o.status = 'completed' AND o.completed_at >= crm_tablero_corte(now())))
  ) b
  LEFT JOIN conversations cv ON cv.id = b.conversation_id
  LEFT JOIN contacts c ON c.id = coalesce(b.contact_id, cv.contact_id)
  ORDER BY b.col_rank, b.since;
END $function$;

REVOKE ALL ON FUNCTION public.crm_tablero_operaciones() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_tablero_operaciones() TO authenticated;
