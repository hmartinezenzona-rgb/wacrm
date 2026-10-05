-- =====================================================================
-- 214 -- Read-only operations board: crm_tablero_operaciones() (staging first)
--
-- odd/tasks/operations-board-readonly.md (T1). One page (/tablero) shows every chat's live operations by status, like
-- the old deals kanban did, but read-only: the panel inside each chat stays the only place to act.
--
-- remittance_operations has RLS with no policies, so the client reads it through SECURITY DEFINER RPCs. This one takes
-- no argument: it resolves the caller's account from their profile and returns that account's operations only.
--
-- ROWS: status IN (collecting_information, deposit_verification, ready_to_transfer, transferring, incident), plus
-- completed ones with completed_at >= now() - 24 h. Cancelled operations are never returned.
--
-- state_since (when the operation entered its CURRENT status). There is no status-changed column, and the admin audit
-- (remittance_admin_audit) records only human status changes, not the bot's. So, best available first:
--   1. completed  -> completed_at;
--   2. the latest audit row (field_name 'status') whose after->>'status' is the current status;
--   3. otherwise updated_at. The touch trigger moves it on EVERY edit, so this fallback can under-state the age of an
--      operation that was edited after it changed status; it is the best signal left.
--
-- AUTHORIZATION: same 42501 as crm_operaciones_de_conversacion. A caller without a profile (no account), or no
-- session, is refused; the account is the caller's own, so another account's rows are unreachable.
--
-- Existing functions are not redefined; crm_beneficiarios_completos is only called.
-- =====================================================================
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
             WHEN o.status = 'completed' THEN coalesce(o.completed_at, o.updated_at)
             ELSE coalesce(
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
