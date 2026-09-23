-- =====================================================================
-- 116 — RPC: today's remittance volume by service_type for /dashboard
--
-- WHY
--   PR #44 removed the pipeline-stage donut from /dashboard (the
--   pipelines management UI it depended on no longer exists — deals no
--   longer track a live panel-completed operation, per migration 114).
--   Its replacement shows today's real remittance volume broken down by
--   `service_type` instead — financial, informative, not a resurrection
--   of the pipelines feature.
--
-- WHY A FUNCTION AND NOT A DIRECT VIEW SELECT FROM THE CLIENT
--   Same reasoning as 055's header: `remittance_operations` (and views
--   built on it, including `cerebro_volumen_diario` from 053/114) has
--   RLS enabled with NO policies for `authenticated`. A direct client
--   `SELECT` returns empty, not an error — the CRM must read through a
--   `SECURITY DEFINER` RPC, exactly like every other `cerebro_dashboard_*`
--   function.
--
-- WHAT THIS ADDS
--   `cerebro_dashboard_volumen_por_servicio()` — no arguments, returns
--   today's rows (`dia = current_date`) from `cerebro_volumen_diario`,
--   ordered by volume descending. No new aggregation logic: the view
--   already has the exact shape needed, this just exposes today's slice
--   of it safely to `authenticated`.
--
-- ROLLBACK
--   See ROLLBACK-116-dashboard-service-volume-rpc.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION cerebro_dashboard_volumen_por_servicio()
RETURNS TABLE (service_type text, operaciones bigint, volumen_gyd numeric,
               ticket_medio_gyd numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT service_type, operaciones, volumen_gyd, ticket_medio_gyd
    FROM cerebro_volumen_diario
   WHERE dia = current_date
   ORDER BY volumen_gyd DESC;
$$;

GRANT EXECUTE ON FUNCTION cerebro_dashboard_volumen_por_servicio() TO authenticated;


-- =====================================================================
-- QUIEN LA USA
--   `src/app/(dashboard)/dashboard/page.tsx`, via
--   `src/lib/dashboard/queries.ts`'s `loadServiceVolume`, rendered by
--   `src/components/dashboard/service-volume-donut.tsx`.
-- =====================================================================
