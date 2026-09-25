-- =====================================================================
-- 121 — RPC: financial close for /resumen (crm_cierre_financiero)
--
-- WHY
--   `/resumen` today only shows volume (operation count, GYD in) pulled
--   from `remittance_operations` in 5 fixed periods, computed in the
--   viewer's browser timezone. The money side of the business — what was
--   billed, invested and earned — lives in `remittance_calculator_entries`
--   (fed on completion, migration 104) and only ever surfaces on
--   `/dashboard` in 3 fixed buckets, also computed client-side. This RPC
--   is the single source of truth for a financial close over any
--   day/week/month/custom range: totals, a per-service breakdown, a
--   per-day breakdown and the full auditable detail, all computed
--   server-side in one call.
--
-- BUSINESS DAY, NOT entry_date
--   `entry_date` is the UTC date of `completed_at` and follows nobody's
--   real clock. A close needs the day this business actually experienced
--   it, so every grouping and every range filter uses:
--     coalesce((completed_at AT TIME ZONE 'America/Guyana')::date, entry_date)
--   `entry_date` is the fallback for a `verified_pending` row, which may
--   carry no `completed_at` at all. It is used AS IS: casting it to
--   timestamptz and converting to Guyana would turn midnight UTC into
--   20:00 of the PREVIOUS Guyana day (caught by the assertions). Guyana has run one
--   fixed UTC-4 offset with no DST since 1992, so this is a stable
--   conversion, not a moving target. An operation completed at 20:30
--   Guyana (00:30 UTC the next calendar day) counts on the Guyana day it
--   actually happened, not the UTC day.
--
-- VALIDATION (SQLSTATE 22023 — invalid_parameter_value)
--   Both bounds are required, `p_desde` must not be after `p_hasta`, and
--   the range is capped at 366 days (one leap year) so a close never
--   silently scans an unbounded slice of the ledger.
--
-- SCOPE: source = 'completed_operation' ONLY
--   Manual ledger entries (source = 'manual') are the calculator
--   document's own bookkeeping, not a structured operation this close can
--   audit back to a conversation/customer — same boundary `/dashboard`'s
--   `loadLedgerProfit` already draws.
--
-- ACCOUNT SCOPING — same minimum role as 106's ledger SELECT policy
--   106 grants read access to the ledger via
--   `is_account_member(account_id)` — no explicit `min_role`, so it
--   defaults to `'viewer'` (001's `is_account_member`). This RPC applies
--   the identical per-row check, `is_account_member(e.account_id)`, so a
--   caller who is not at least a viewer on an entry's account never sees
--   that row: not its totals, not its breakdowns, not its detail. There
--   is no `p_account_id` parameter — scoping is row-level, exactly like
--   the policy it mirrors, so a caller belonging to more than one account
--   would see every account they belong to in one close. Today's schema
--   has no multi-account membership in practice, but the RPC does not
--   assume that.
--
-- TOTALS vs DETAIL vs EXCLUDED
--   `totales` and `por_servicio`/`por_dia` count `status = 'completed'`
--   rows only — the same rule `/dashboard`'s `loadLedgerProfit` already
--   applies. A `void` or `verified_pending` row never moves a total, but
--   both are still visible, in `excluidas`, so nothing silently
--   disappears from the audit trail. `por_dia` always returns one row per
--   calendar day in `[p_desde, p_hasta]` (via `generate_series`), zeroed
--   when a day has no completed entry, so the caller never has to fill
--   gaps itself.
--
-- actor_name — resolved from `profiles.full_name`
--   `remittance_calculator_entries.actor_user_id` references
--   `auth.users(id)`, which carries no display name. `profiles.user_id`
--   is this codebase's existing 1:1 mapping from an auth user to a
--   display name (`full_name`, falling back to `email` — the exact
--   pattern `src/lib/account/members.ts` and migration 027's
--   `v_actor_name` already use). A `NULL actor_user_id` (no operator
--   recorded) or a user with no profile row resolves to a `null`
--   `actor_name`, never an error.
--
-- WHY SECURITY DEFINER, WHY NO client-side RLS reliance
--   `remittance_calculator_entries` has RLS with only a SELECT policy
--   (106) — a plain client query already works for a member's own
--   account, but this RPC additionally aggregates across the whole
--   requested range server-side (totals, per-service, per-day, and the
--   generated day series) in one round trip instead of the client pulling
--   every row and reducing it in the browser. SECURITY DEFINER plus the
--   explicit `is_account_member` filter keeps the same account boundary
--   RLS would have enforced, just evaluated once inside the function.
--
-- ROLLBACK
--   See ROLLBACK-121-financial-close-rpc.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_cierre_financiero(
  p_desde date,
  p_hasta date
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result jsonb;
BEGIN
  IF p_desde IS NULL OR p_hasta IS NULL THEN
    RAISE EXCEPTION 'crm_cierre_financiero: p_desde and p_hasta are required'
      USING ERRCODE = '22023';
  END IF;

  IF p_desde > p_hasta THEN
    RAISE EXCEPTION 'crm_cierre_financiero: p_desde (%) must not be after p_hasta (%)',
      p_desde, p_hasta
      USING ERRCODE = '22023';
  END IF;

  -- Inclusive day count = (p_hasta - p_desde) + 1; capped at 366 (a leap
  -- year), so the cap on the raw difference is 365.
  IF (p_hasta - p_desde) > 365 THEN
    RAISE EXCEPTION 'crm_cierre_financiero: range must not exceed 366 days (requested % days)',
      (p_hasta - p_desde) + 1
      USING ERRCODE = '22023';
  END IF;

  WITH scoped AS (
    -- Every completed-operation ledger row this caller is allowed to see,
    -- with its Guyana business day precomputed once.
    SELECT
      e.*,
      coalesce((e.completed_at AT TIME ZONE 'America/Guyana')::date,
               e.entry_date) AS dia
    FROM remittance_calculator_entries e
    WHERE e.source = 'completed_operation'
      AND is_account_member(e.account_id)
  ),
  in_range AS (
    SELECT * FROM scoped WHERE dia BETWEEN p_desde AND p_hasta
  ),
  completed AS (
    SELECT * FROM in_range WHERE status = 'completed'
  ),
  totales AS (
    SELECT
      count(*)                        AS operaciones,
      coalesce(sum(facturado_gyd), 0) AS facturado_gyd,
      coalesce(sum(invertido_gyd), 0) AS invertido_gyd,
      coalesce(sum(retorno_gyd), 0)   AS retorno_gyd
    FROM completed
  ),
  por_servicio AS (
    SELECT
      service,
      count(*)                        AS operaciones,
      coalesce(sum(facturado_gyd), 0) AS facturado_gyd,
      coalesce(sum(invertido_gyd), 0) AS invertido_gyd,
      coalesce(sum(retorno_gyd), 0)   AS retorno_gyd
    FROM completed
    GROUP BY service
  ),
  dias AS (
    -- Every calendar day in the range, so por_dia never has a gap.
    SELECT gs::date AS dia FROM generate_series(p_desde, p_hasta, interval '1 day') gs
  ),
  por_dia AS (
    SELECT
      d.dia,
      count(c.id)                        AS operaciones,
      coalesce(sum(c.facturado_gyd), 0)  AS facturado_gyd,
      coalesce(sum(c.invertido_gyd), 0)  AS invertido_gyd,
      coalesce(sum(c.retorno_gyd), 0)    AS retorno_gyd
    FROM dias d
    LEFT JOIN completed c ON c.dia = d.dia
    GROUP BY d.dia
  ),
  detalle AS (
    SELECT
      c.id, c.operation_id, c.dia, c.completed_at, c.customer_name, c.service,
      c.amount, c.amount_currency, c.cup_rate, c.cup_global_rate,
      c.usdt_buy_gyd, c.usdt_sell_gyd, c.rate_version_id,
      c.facturado_gyd, c.invertido_gyd, c.retorno_gyd,
      c.delivery_mode, c.actor_user_id,
      coalesce(nullif(p.full_name, ''), p.email) AS actor_name
    FROM completed c
    LEFT JOIN profiles p ON p.user_id = c.actor_user_id
  ),
  excluidas AS (
    -- Voided and pending-rate rows never touch a total but must stay
    -- visible: a voided figure for the audit trail, a pending one to show
    -- what is still waiting on a rate.
    SELECT
      c.id, c.operation_id, c.dia, c.completed_at, c.customer_name, c.service,
      c.amount, c.amount_currency, c.cup_rate, c.cup_global_rate,
      c.usdt_buy_gyd, c.usdt_sell_gyd, c.rate_version_id,
      c.facturado_gyd, c.invertido_gyd, c.retorno_gyd,
      c.delivery_mode, c.actor_user_id,
      coalesce(nullif(p.full_name, ''), p.email) AS actor_name,
      c.status, c.void_reason, c.voided_at, c.missing_inputs
    FROM in_range c
    LEFT JOIN profiles p ON p.user_id = c.actor_user_id
    WHERE c.status IN ('void', 'verified_pending')
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'zona',  'America/Guyana',

    'totales', (
      SELECT jsonb_build_object(
        'operaciones',    t.operaciones,
        'facturado_gyd',  t.facturado_gyd,
        'invertido_gyd',  t.invertido_gyd,
        'retorno_gyd',    t.retorno_gyd
      )
      FROM totales t
    ),

    'por_servicio', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'service',        s.service,
          'operaciones',    s.operaciones,
          'facturado_gyd',  s.facturado_gyd,
          'invertido_gyd',  s.invertido_gyd,
          'retorno_gyd',    s.retorno_gyd
        )
        ORDER BY s.facturado_gyd DESC
      )
      FROM por_servicio s
    ), '[]'::jsonb),

    'por_dia', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'dia',            d.dia,
          'operaciones',    d.operaciones,
          'facturado_gyd',  d.facturado_gyd,
          'invertido_gyd',  d.invertido_gyd,
          'retorno_gyd',    d.retorno_gyd
        )
        ORDER BY d.dia ASC
      )
      FROM por_dia d
    ), '[]'::jsonb),

    'detalle', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',              e.id,
          'operation_id',    e.operation_id,
          'dia',             e.dia,
          'completed_at',    e.completed_at,
          'customer_name',   e.customer_name,
          'service',         e.service,
          'amount',          e.amount,
          'amount_currency', e.amount_currency,
          'cup_rate',        e.cup_rate,
          'cup_global_rate', e.cup_global_rate,
          'usdt_buy_gyd',    e.usdt_buy_gyd,
          'usdt_sell_gyd',   e.usdt_sell_gyd,
          'rate_version_id', e.rate_version_id,
          'facturado_gyd',   e.facturado_gyd,
          'invertido_gyd',   e.invertido_gyd,
          'retorno_gyd',     e.retorno_gyd,
          'delivery_mode',   e.delivery_mode,
          'actor_user_id',   e.actor_user_id,
          'actor_name',      e.actor_name
        )
        ORDER BY e.completed_at ASC
      )
      FROM detalle e
    ), '[]'::jsonb),

    'excluidas', coalesce((
      SELECT jsonb_agg(
        jsonb_build_object(
          'id',              e.id,
          'operation_id',    e.operation_id,
          'dia',             e.dia,
          'completed_at',    e.completed_at,
          'customer_name',   e.customer_name,
          'service',         e.service,
          'amount',          e.amount,
          'amount_currency', e.amount_currency,
          'cup_rate',        e.cup_rate,
          'cup_global_rate', e.cup_global_rate,
          'usdt_buy_gyd',    e.usdt_buy_gyd,
          'usdt_sell_gyd',   e.usdt_sell_gyd,
          'rate_version_id', e.rate_version_id,
          'facturado_gyd',   e.facturado_gyd,
          'invertido_gyd',   e.invertido_gyd,
          'retorno_gyd',     e.retorno_gyd,
          'delivery_mode',   e.delivery_mode,
          'actor_user_id',   e.actor_user_id,
          'actor_name',      e.actor_name,
          'status',          e.status,
          'void_reason',     e.void_reason,
          'voided_at',       e.voided_at,
          'missing_inputs',  e.missing_inputs
        )
        ORDER BY e.completed_at ASC
      )
      FROM excluidas e
    ), '[]'::jsonb)
  ) INTO v_result;

  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.crm_cierre_financiero(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_cierre_financiero(date, date) TO authenticated;

COMMENT ON FUNCTION public.crm_cierre_financiero(date, date) IS
  'Financial close for /resumen: totals, per-service and per-day '
  'breakdowns, and the full auditable detail (plus voided/pending rows '
  'kept out of the totals) for every completed-operation ledger entry in '
  '[p_desde, p_hasta] Guyana business days, scoped to the caller''s '
  'account membership. See migration 121 for the full design rationale.';


-- =====================================================================
-- QUIEN LA USA
--   Not wired yet. `/resumen`'s financial close reads this RPC starting
--   with this feature's T2 (TS read model + data loader) and T3 (UI).
-- =====================================================================
