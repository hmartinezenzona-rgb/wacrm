-- =====================================================================
-- 234 -- The Finanzas "Resumen" cards come from the calculator ledger, like the "Cierre financiero" (staging first)
--
-- odd/tasks/finanzas-resumen-from-ledger.md (Part 1). Production 2026-10-08: the Resumen showed 4 operations / 130,100 GYD for today while the
-- close showed 4 / 130,060: the Resumen counted OPERATIONS and summed what customers DEPOSITED (cerebro_volumen_diario over remittance_operations),
-- the close sums FACTURADO of the ledger. On longer periods the gap is far larger: the Resumen never saw the MANUAL ledger entries the close counts
-- ("ayer" 0 vs 191,900). Owner decision: both blocks come from the SAME source.
--   * cerebro_dashboard_resumen(): same name, signature, returned columns and grants (the deployed page keeps working), but each of the five
--     periods (hoy, ayer, esta semana = Monday -> today, este mes, mes pasado; Guyana days) is read from crm_cierre_financiero(desde, hasta)->'totales':
--     operaciones = the close's operation count, volumen_gyd = the close's facturado_gyd, ticket_medio_gyd = round(facturado / operaciones), NULL
--     with no operations (the old view rounded its ticket too). The close is CALLED, not re-derived, so the statuses counted, the exclusions (void,
--     deleted, pending-rate), the Guyana day attribution and the account scoping can never drift apart.
--   * SECURITY CHANGE: the old function was SECURITY DEFINER with NO account filter (any authenticated user read the operations of every account
--     through the view). It now inherits the close's scoping, is_account_member(account_id): a member sees only the accounts they belong to; a
--     caller with no identity, or from no account, gets the five periods with zeros and a NULL ticket (the close raises nothing for them either).
--   * NOT touched: the views cerebro_volumen_diario and cerebro_resumen_volumen and the functions that read them (cerebro_volumen,
--     cerebro_dashboard_volumen_por_servicio, the dashboard widgets) keep counting operations exactly as before. cerebro_resumen_volumen is now
--     read by nobody (its only reader was this function); it stays so the rollback is a single function.
-- Pre-234 md5 (pg_get_functiondef, staging and production 2026-10-08, identical): cerebro_dashboard_resumen 84ba499d6e5e0ad876cc0ebc11b1eb28.
-- Drift noted: cerebro_resumen_volumen differs between staging (md5 of pg_get_viewdef 9f176ed9...) and production (0ba555bd...) only in how the
-- deparser prints 'ayer'::text AS text; same query. crm_cierre_financiero is identical (c903a471...). Not part of this migration.
-- Grants: unchanged (CREATE OR REPLACE keeps the ACL: postgres, authenticated, service_role). No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/resumen-from-ledger.sql. ROLLBACK: ROLLBACK-234-resumen-from-ledger.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_dashboard_resumen()
 RETURNS TABLE(orden integer, periodo text, desde date, hasta date, operaciones bigint, volumen_gyd numeric, ticket_medio_gyd numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH hoy AS (
    SELECT (now() AT TIME ZONE 'America/Guyana')::date AS d
  ),
  p AS (
    SELECT 1 AS orden, 'hoy'::text AS periodo, d AS desde, d AS hasta FROM hoy
    UNION ALL SELECT 2, 'ayer',        d - 1,                                          d - 1                                           FROM hoy
    UNION ALL SELECT 3, 'esta semana', date_trunc('week',  d)::date,                   d                                               FROM hoy
    UNION ALL SELECT 4, 'este mes',    date_trunc('month', d)::date,                   d                                               FROM hoy
    UNION ALL SELECT 5, 'mes pasado',  (date_trunc('month', d) - interval '1 month')::date,
                                       (date_trunc('month', d) - interval '1 day')::date                                               FROM hoy
  ),
  c AS MATERIALIZED (
    -- (234) One call of the close per period: the single place that decides what counts.
    SELECT p.orden, p.periodo, p.desde, p.hasta,
           public.crm_cierre_financiero(p.desde, p.hasta) -> 'totales' AS t
      FROM p
  )
  SELECT c.orden, c.periodo, c.desde, c.hasta,
         (c.t ->> 'operaciones')::bigint,
         (c.t ->> 'facturado_gyd')::numeric,
         CASE WHEN (c.t ->> 'operaciones')::numeric > 0
              THEN round((c.t ->> 'facturado_gyd')::numeric / (c.t ->> 'operaciones')::numeric) END
    FROM c
   ORDER BY c.orden;
$function$;
