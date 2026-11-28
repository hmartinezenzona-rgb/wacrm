-- =====================================================================
-- 295 -- calculator_unfed_operations lists only an operation that truly lacks a line
--
-- 2026-10-24: operation 8dd1740c (México, 100 USD) appeared in this view with unfed_reason =
-- service_unresolved although it had a live CLASICA entry since completion (2026-10-23 15:05).
-- calculator_operation_parts returned ZERO parts for it (294 fixed the cause: an unknown Mexico
-- recipient type), and the view treated n_parts = 0 as "unfed" without looking at the ledger.
-- "No part" means the feed cannot decide a service, not that the operation has no line.
--
-- Now the no-part case is listed only when the operation has no live ledger entry at all. The
-- mixed case (n_parts > 1, some part without a line) is unchanged, and so is the rule that a
-- deleted entry counts as fed (226).
--
-- Assertion: supabase/staging/assertions/unfed-no-live-entry.sql.
-- Rollback: ROLLBACK-295-unfed-requires-missing-entry.sql (restores the 226 body).
-- =====================================================================

CREATE OR REPLACE VIEW public.calculator_unfed_operations AS
SELECT o.id AS operation_id,
    o.account_id,
    o.completed_at,
    o.delivery_method,
    o.quoted_source_amount,
    calculator_resolve_operation_service(o.id, o.delivery_method) AS service,
        CASE
            WHEN (p.n_parts = 0) THEN 'service_unresolved'::text
            WHEN (p.n_parts > 1) THEN 'mixed_part_unfed'::text
            ELSE NULL::text
        END AS unfed_reason
   FROM ((remittance_operations o
     CROSS JOIN calculator_feed_state s)
     CROSS JOIN LATERAL ( SELECT count(*) AS n_parts,
            count(*) FILTER (WHERE (NOT (EXISTS ( SELECT 1
                   FROM remittance_calculator_entries e
                  WHERE ((e.account_id = o.account_id) AND (e.operation_id = o.id) AND (e.source = 'completed_operation'::text) AND (e.service = part.service) AND ((e.status <> 'void'::text) OR (e.deleted_at IS NOT NULL))))))) AS n_unfed
           FROM calculator_operation_parts(o.*, calculator_rates_vigentes(o.account_id)) part(service, basis, placeholder_amount, missing)) p)
  WHERE ((o.status = 'completed'::text) AND (o.completed_at >= s.feed_started_at) AND (o.quoted_source_amount > (0)::numeric)
     AND (((p.n_parts > 0) AND (p.n_unfed > 0))
          OR ((p.n_parts = 0) AND NOT (EXISTS ( SELECT 1
                   FROM remittance_calculator_entries e
                  WHERE ((e.account_id = o.account_id) AND (e.operation_id = o.id) AND (e.source = 'completed_operation'::text) AND ((e.status <> 'void'::text) OR (e.deleted_at IS NOT NULL))))))));

COMMENT ON VIEW public.calculator_unfed_operations IS
  'Completed operations since feed_started_at missing a live ledger line — '
  'the recovery list for crm_feed_calculator. An operation is fed only when '
  'every part (one per service; several for a mixed remesa, 142) has a live '
  'line; when no part can be resolved (294) it is listed only if it has no '
  'live entry at all. unfed_reason: service_unresolved (no part could be '
  'resolved and no line exists) or mixed_part_unfed. Empty is the normal state.';
