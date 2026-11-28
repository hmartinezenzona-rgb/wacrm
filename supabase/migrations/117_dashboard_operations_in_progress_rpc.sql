-- =====================================================================
-- 117 — RPC: value of remittance operations currently in progress,
--        for the dashboard metric card that used to show open-deal value
--
-- WHY
--   The dashboard's "Open Deals Value" card summed `deals.value` where
--   `status='open'` — the retired pipelines model. Its successor sums
--   `remittance_operations.quoted_source_amount` for operations still in
--   flight: everything except `completed` and `cancelled`. Same concept
--   ("value not yet closed"), the model this business actually runs on.
--
--   Deliberately NOT "today's volume" — that would duplicate the total
--   already shown by 116's service-volume donut (which is completed-
--   today only). This card answers a different question: how much is
--   currently outstanding, regardless of when it started.
--
-- WHY A FUNCTION
--   Same reasoning as 055 and 116: `remittance_operations` has RLS with
--   no policies for `authenticated`, so a direct client read returns
--   empty, not an error. Read through a SECURITY DEFINER RPC.
--
-- WHY NO account_id FILTER
--   Matches the established precedent (055's cerebro_dashboard_resumen,
--   116's cerebro_dashboard_volumen_por_servicio) — this remittance/
--   cerebro subsystem has no account_id-scoped RLS anywhere in it; it is
--   de facto single-tenant, unlike the generic deals/conversations
--   tables. Confirmed by reading 055's function bodies before writing
--   this one, not assumed.
--
-- ROLLBACK
--   See ROLLBACK-117-dashboard-operations-in-progress-rpc.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_dashboard_operaciones_en_curso()
RETURNS TABLE (operaciones bigint, volumen_gyd numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT count(*), coalesce(sum(quoted_source_amount), 0)
    FROM remittance_operations
   WHERE status NOT IN ('completed', 'cancelled');
$$;

GRANT EXECUTE ON FUNCTION cerebro_dashboard_operaciones_en_curso() TO authenticated;


-- =====================================================================
-- QUIEN LA USA
--   `src/app/(dashboard)/dashboard/page.tsx`, via
--   `src/lib/dashboard/queries.ts`'s `loadMetrics`.
-- =====================================================================
