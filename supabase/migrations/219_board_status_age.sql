-- =====================================================================
-- 219 -- The operations board shows the real time in the CURRENT status (staging first)
--
-- odd/tasks/board-status-age.md (T2). crm_tablero_operaciones() (214) had no status-changed time to read: it used the
-- latest HUMAN audit row, else updated_at, and updated_at moves on every edit. An operation stuck for hours in
-- deposit_verification, then touched by an unrelated edit (or whose status the bot changed, which is not audited),
-- showed "2 min".
--
-- 1. remittance_operations.status_changed_at: when the operation entered its current status, whoever changed it.
-- 2. trg_zz_status_changed_at (BEFORE INSERT OR UPDATE OF status) stamps clock_timestamp() on insert and when the
--    status really changes. It touches no other column (not updated_at, not version, not the status).
--    ORDER: BEFORE triggers fire alphabetically. remittance_operations_completion_guard (trg_admin_guard_operations_status)
--    can REWRITE NEW.status (a suppressed automation completion/revert puts OLD.status back), and trg_remittance_operations_touch
--    sets completed_at. The "zz" name fires after all of them, so it compares the FINAL status and a suppressed change never
--    moves the stamp.
-- 3. One-time backfill with 214's best derivation (completed -> completed_at; else the latest audit row of the current
--    status; else updated_at). The user triggers are disabled for that one UPDATE so updated_at/version/notifications do
--    not move; this runs in one transaction.
--    The column stays NULLABLE on purpose: the trigger fills every insert and status change, but an explicit
--    UPDATE ... SET status_changed_at = NULL by some writer would otherwise fail a bot write; the RPC falls back to
--    214's derivation for a NULL, so a NULL is harmless, a NOT NULL violation would not be.
-- 4. crm_tablero_operaciones(): same signature, shape, SECURITY DEFINER, search_path, authorization and grants; only
--    state_since changes: completed -> coalesce(completed_at, status_changed_at, updated_at) (the completion time,
--    also when backdated, as 214 did); otherwise coalesce(status_changed_at, <214's audit row>, updated_at).
-- =====================================================================
ALTER TABLE public.remittance_operations ADD COLUMN IF NOT EXISTS status_changed_at timestamptz;

CREATE OR REPLACE FUNCTION public.remittance_operations_stamp_status_changed_at()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.status_changed_at := clock_timestamp();
  END IF;
  RETURN NEW;
END $function$;

DROP TRIGGER IF EXISTS trg_zz_status_changed_at ON public.remittance_operations;
CREATE TRIGGER trg_zz_status_changed_at
  BEFORE INSERT OR UPDATE OF status ON public.remittance_operations
  FOR EACH ROW EXECUTE FUNCTION public.remittance_operations_stamp_status_changed_at();

-- Backfill (rows that have no stamp yet), without firing the table's user triggers.
ALTER TABLE public.remittance_operations DISABLE TRIGGER USER;
UPDATE public.remittance_operations o
   SET status_changed_at = CASE
         WHEN o.status = 'completed' THEN coalesce(o.completed_at, o.updated_at)
         ELSE coalesce(
           (SELECT max(a.created_at)
              FROM public.remittance_admin_audit a
             WHERE a.table_name = 'remittance_operations'
               AND a.row_id = o.id
               AND a.field_name = 'status'
               AND a.after ->> 'status' = o.status),
           o.updated_at)
       END
 WHERE o.status_changed_at IS NULL;
ALTER TABLE public.remittance_operations ENABLE TRIGGER USER;

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
