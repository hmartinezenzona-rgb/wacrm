-- =====================================================================
-- 141 — Calculator feed resolves the service from the beneficiaries
--
-- PURPOSE: a completed remesa can carry a NULL or STALE
-- `remittance_operations.delivery_method` — that column is set only by the
-- legacy notes trigger (042, with an arbitrary LIMIT 1); the add-beneficiary
-- RPC (123) and the reparto RPCs (127/129) never touch it. 104's
-- `calculator_feed_operation` reads that column alone, so a remesa whose
-- beneficiaries were added or reassigned after the column was last set
-- either gets no ledger entry at all (NULL) or the WRONG one (stale), and
-- `calculator_unfed_operations` filtered on the very same stale mapping, so
-- the miss was invisible. Same root cause as the panel caption bug fixed by
-- per-beneficiary-delivery-proof P1 (commit 2761685).
--
-- Evidence (prod, read-only, 2026-09-28): operation 53d4e1f0 (23,400 GYD, 2
-- Zelle beneficiaries, source=admin_addition, completed) has delivery_method
-- NULL and was silently unfed.
--
-- THE FIX: a resolver looks at the operation's CURRENT ('vigente')
-- beneficiaries first.
--   - Zero current beneficiaries -> unchanged: the delivery_method mapping
--     (calculator_service_for_operation, verbatim, 104) exactly as before.
--     This keeps every legacy remesa (no beneficiary rows at all) behaving
--     identically.
--   - One or more current beneficiaries, all the SAME beneficiary_type ->
--     that type's service, via the SAME calculator_service_for_operation
--     map (the beneficiary_type vocabulary — cuban_card / zelle / clasica /
--     tropical / multiple_distribution, 042/123 — is byte-for-byte the
--     delivery_method vocabulary 104 already maps, so no second map is
--     introduced).
--   - Current beneficiaries of DIFFERENT types (e.g. one cuban_card + one
--     zelle) -> unresolved (NULL), same as today's "no service" outcome,
--     but now VISIBLE (see below) instead of silently absent. Pricing a
--     split service is slice 10's concern (104's own comment), not this
--     one.
--
-- `calculator_feed_operation` and `calculator_unfed_operations` both call
-- the resolver instead of `calculator_service_for_operation` directly.
-- NEITHER THE FORMULAS NOR THE RATES MOVE: calculator_amount_from_basis /
-- calculator_facturado / calculator_invertido (105, floor fixed by 111) are
-- untouched, and `calculator_feed_operation`'s pricing body is byte-for-byte
-- what 105 last defined — only the one line computing v_service changes.
-- `feed-matrix.sql` proves that parity by passing unmodified after this.
--
-- calculator_unfed_operations: previously filtered out any row whose
-- (delivery_method-only) service was NULL, which is exactly what made the
-- miss silent. That filter is dropped in favour of the resolver, and a new
-- `unfed_reason` column names why: 'service_unresolved' when the resolver
-- returns NULL (mixed beneficiaries, or an unmapped/NULL delivery_method
-- with no beneficiaries at all). The `quoted_source_amount > 0` bound stays
-- exactly as 104 wrote it — this slice only widens the service-NULL case
-- the task named; an operation with no usable deposit is a separate,
-- unaddressed gap and stays out of scope here. The existing columns
-- (operation_id, account_id, completed_at, delivery_method,
-- quoted_source_amount, service) are kept byte-for-byte — `unfed_reason` is
-- additive. `grep -rn calculator_unfed_operations src/` found no reader in
-- the panel code, so there is nothing else to keep compatible with.
--
-- GUARD ORDER / TRIGGER: 096's guard 12a (BEFORE trigger on status) and the
-- 104 AFTER-trigger firing order are untouched — this migration does not
-- redefine remittance_operations_calculator_feed or its trigger at all.
--
-- delivery_method SYNC (SKIPPED, deliberately): the approach doc offered an
-- optional trigger to keep remittance_operations.delivery_method in sync
-- from remittance_beneficiaries. Skipped here — 096's guard 12a already
-- suppresses an AUTOMATION write to delivery_method once a human has locked
-- it (admin_locked_fields -> 'delivery_method'), and both crm_agregar_
-- beneficiario (123) and the reparto RPCs (127/129) lock 'beneficiaries',
-- not 'delivery_method', so a sync trigger would need its own care around
-- that lock, plus wacrm.origin handling (the reparto RPCs already juggle
-- that flag for their own beneficiaries-lock write) to avoid tripping the
-- automation-suppressed audit path for a legitimate system-derived sync.
-- None of that is exercised by this task's acceptance criteria (the feed
-- now reads the beneficiaries directly, so a synced column buys nothing for
-- F1), and the resolver already makes the stale column irrelevant to
-- pricing. Revisit only if something else starts depending on
-- delivery_method reflecting reality.
--
-- ROLLBACK: see ROLLBACK-141-calculator-feed-from-beneficiaries.sql
-- STAGING ASSERTION: supabase/staging/assertions/feed-from-beneficiaries.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The resolver
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION calculator_resolve_operation_service(
  p_operation_id  uuid,
  p_delivery_method text
) RETURNS text
LANGUAGE sql
STABLE
AS $$
  SELECT CASE
           WHEN NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) THEN calculator_service_for_operation(p_delivery_method)
           WHEN (
             SELECT count(DISTINCT b.beneficiary_type)
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) = 1 THEN calculator_service_for_operation((
             SELECT b.beneficiary_type
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
              LIMIT 1
           ))
           ELSE NULL
         END;
$$;

COMMENT ON FUNCTION calculator_resolve_operation_service(uuid, text) IS
  'Resolves a calculator service from an operation''s CURRENT (vigente) '
  'beneficiaries first — one shared beneficiary_type maps through '
  'calculator_service_for_operation; mixed types are unresolved (NULL). '
  'Only with zero current beneficiaries does it fall back to the legacy '
  'delivery_method mapping. Used by calculator_feed_operation and '
  'calculator_unfed_operations so the stale delivery_method column can '
  'never override a real current beneficiary.';

-- ---------------------------------------------------------------------
-- 2. calculator_feed_operation — one line changed: how v_service is
--    resolved. Every other line is 105's definition, verbatim.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION calculator_feed_operation(p_operation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_service   text;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  v_service := calculator_resolve_operation_service(v_op.id, v_op.delivery_method);
  IF v_service IS NULL THEN
    RETURN NULL;
  END IF;

  v_basis := v_op.quoted_source_amount;
  IF v_basis IS NULL OR v_basis <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates   := calculator_rates_vigentes(v_op.account_id);
  v_missing := calculator_missing_rates(v_service, v_rates);
  v_currency := CASE WHEN v_service = 'CUP' THEN 'CUP' ELSE 'USD' END;

  IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
    v_amount    := calculator_amount_from_basis(v_service, v_basis, v_rates.cup_global_rate, v_rates.usdt_sell_gyd);
    v_facturado := calculator_facturado(v_service, v_amount, v_rates.cup_global_rate, v_rates.usdt_sell_gyd);
    v_invertido := calculator_invertido(v_service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd);
  END IF;

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  -- With a rate missing there is no unit count either, so a pending entry
  -- records the deposit itself — the one figure that is certainly known,
  -- and > 0 as 095's CHECK requires.
  IF v_amount IS NULL THEN
    v_amount := v_basis;
  END IF;

  INSERT INTO remittance_calculator_entries (
    account_id, source, status, operation_id, entry_date, customer_name,
    service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
    facturado_gyd, invertido_gyd, retorno_gyd,
    missing_inputs, delivery_mode, actor_user_id, completed_at
  ) VALUES (
    v_op.account_id, 'completed_operation',
    CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
    v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
    v_service, v_amount, v_currency,
    v_rates.cup_global_rate, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd, v_rates.usdt_sell_gyd, v_rates.id,
    v_facturado, v_invertido,
    CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
    nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
    coalesce(v_op.completed_at, clock_timestamp())
  )
  ON CONFLICT (account_id, operation_id) WHERE source = 'completed_operation'
  DO UPDATE SET
    status          = EXCLUDED.status,
    entry_date      = EXCLUDED.entry_date,
    customer_name   = EXCLUDED.customer_name,
    service         = EXCLUDED.service,
    amount          = EXCLUDED.amount,
    amount_currency = EXCLUDED.amount_currency,
    cup_global_rate = EXCLUDED.cup_global_rate,
    cup_rate        = EXCLUDED.cup_rate,
    usdt_buy_gyd    = EXCLUDED.usdt_buy_gyd,
    usdt_sell_gyd   = EXCLUDED.usdt_sell_gyd,
    rate_version_id = EXCLUDED.rate_version_id,
    facturado_gyd   = EXCLUDED.facturado_gyd,
    invertido_gyd   = EXCLUDED.invertido_gyd,
    retorno_gyd     = EXCLUDED.retorno_gyd,
    missing_inputs  = EXCLUDED.missing_inputs,
    delivery_mode   = EXCLUDED.delivery_mode,
    actor_user_id   = EXCLUDED.actor_user_id,
    completed_at    = EXCLUDED.completed_at,
    voided_at       = NULL,
    void_reason     = NULL
  WHERE remittance_calculator_entries.status = 'void'
  RETURNING id INTO v_entry_id;

  RETURN v_entry_id;
END;
$$;

REVOKE ALL ON FUNCTION calculator_feed_operation(uuid) FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. calculator_unfed_operations — resolver-based service, no longer
--    filtered to NULL-service rows, plus a reason column.
-- ---------------------------------------------------------------------

CREATE OR REPLACE VIEW calculator_unfed_operations AS
  SELECT o.id            AS operation_id,
         o.account_id,
         o.completed_at,
         o.delivery_method,
         o.quoted_source_amount,
         calculator_resolve_operation_service(o.id, o.delivery_method) AS service,
         CASE
           WHEN calculator_resolve_operation_service(o.id, o.delivery_method) IS NULL
             THEN 'service_unresolved'
           ELSE NULL
         END AS unfed_reason
    FROM remittance_operations o
   CROSS JOIN calculator_feed_state s
   WHERE o.status = 'completed'
     AND o.completed_at >= s.feed_started_at
     AND o.quoted_source_amount > 0
     AND NOT EXISTS (
           SELECT 1 FROM remittance_calculator_entries e
            WHERE e.account_id = o.account_id
              AND e.operation_id = o.id
              AND e.source = 'completed_operation'
              AND e.status <> 'void'
         );

COMMENT ON VIEW calculator_unfed_operations IS
  'Completed operations since feed_started_at that should have a live '
  'ledger entry and do not — the recovery list for crm_feed_calculator. '
  'Unlike 104''s original definition, this lists an operation even when '
  'its service cannot be resolved (unfed_reason = service_unresolved), so '
  'the gap is visible instead of silently excluded. Empty is the normal '
  'state.';

REVOKE ALL ON FUNCTION calculator_resolve_operation_service(uuid, text) FROM PUBLIC, anon;
