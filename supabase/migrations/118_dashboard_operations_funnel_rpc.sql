-- =====================================================================
-- 118 — RPC: live funnel of remittance operations by stage, for /dashboard
--
-- WHY
--   This business runs on one real sequential process (migration 040's
--   CHECK constraint): collecting_information -> awaiting_deposit ->
--   deposit_received -> deposit_verification -> ready_to_transfer ->
--   transferring -> completed (or -> incident/cancelled, off-ramps).
--   A funnel showing how many operations sit at each non-terminal
--   stage right now is the same widget type HubSpot/Salesforce/Zoho/
--   Pipedrive use for sales-pipeline stage distribution, applied to
--   the process this CRM's business actually runs — where volume is
--   sitting, not a historical conversion rate (that would need a
--   state-transition log this schema doesn't keep).
--
-- WHY ALL SIX STAGES, EVEN AT ZERO
--   A funnel's shape is the point. Grouping live rows by status alone
--   would silently drop a stage with zero operations, and the chart
--   would misrepresent the process as shorter than it is. The VALUES
--   list below is the fixed, ordered stage list; every stage returns
--   a row, LEFT JOINed against however many operations are actually
--   there.
--
-- WHY completed/cancelled ARE NOT STAGES HERE
--   They are exits, not steps in the funnel — mixing them in would
--   make "completed" (which accumulates forever) dwarf every real
--   in-flight stage and defeat the point of showing where things are
--   stuck right now.
--
-- WHY A FUNCTION, WHY NO account_id FILTER
--   Same reasoning as 055/116/117: remittance_operations has RLS with
--   no policies for authenticated, and this subsystem has no
--   account-scoped access anywhere in it (confirmed again here, not
--   assumed).
--
-- ROLLBACK
--   See ROLLBACK-118-dashboard-operations-funnel-rpc.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_dashboard_embudo_operaciones()
RETURNS TABLE (status text, operaciones bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.status, count(o.id)
    FROM (VALUES
      ('collecting_information', 1),
      ('awaiting_deposit',       2),
      ('deposit_received',       3),
      ('deposit_verification',   4),
      ('ready_to_transfer',      5),
      ('transferring',           6)
    ) AS s(status, ord)
    LEFT JOIN remittance_operations o ON o.status = s.status
   GROUP BY s.status, s.ord
   ORDER BY s.ord;
$$;

GRANT EXECUTE ON FUNCTION cerebro_dashboard_embudo_operaciones() TO authenticated;


-- =====================================================================
-- QUIEN LA USA
--   `src/app/(dashboard)/dashboard/page.tsx`, via
--   `src/lib/dashboard/queries.ts`'s `loadOperationsFunnel`, rendered by
--   `src/components/dashboard/operations-funnel.tsx`.
-- =====================================================================
