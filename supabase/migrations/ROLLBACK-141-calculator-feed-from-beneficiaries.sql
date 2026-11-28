-- =====================================================================
-- ROLLBACK-141 — reverts 141_calculator_feed_from_beneficiaries.sql
--
-- Restores calculator_feed_operation and calculator_unfed_operations to
-- their exact pre-141 definitions (105 and 104 respectively — neither was
-- touched by any migration in between, verified against staging with
-- pg_get_functiondef / pg_get_viewdef before writing 141), and drops the
-- resolver.
--
-- Any ledger entry 141 fed from a beneficiary-resolved service (rather than
-- delivery_method) keeps its figures — completed rows are append-only
-- (104's remittance_calculator_entries_lock_completed) and this rollback
-- does not touch remittance_calculator_entries at all.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. calculator_unfed_operations — back to 104's definition. 141 added a
--    trailing column (unfed_reason); Postgres refuses a CREATE OR REPLACE
--    VIEW that drops a column, so this drops the view first.
-- ---------------------------------------------------------------------

DROP VIEW IF EXISTS calculator_unfed_operations;

CREATE VIEW calculator_unfed_operations AS
  SELECT o.id            AS operation_id,
         o.account_id,
         o.completed_at,
         o.delivery_method,
         o.quoted_source_amount,
         calculator_service_for_operation(o.delivery_method) AS service
    FROM remittance_operations o
   CROSS JOIN calculator_feed_state s
   WHERE o.status = 'completed'
     AND o.completed_at >= s.feed_started_at
     AND calculator_service_for_operation(o.delivery_method) IS NOT NULL
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
  'Empty is the normal state.';

-- ---------------------------------------------------------------------
-- 2. calculator_feed_operation — back to 105's definition (v_service from
--    calculator_service_for_operation(delivery_method) directly)
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

  v_service := calculator_service_for_operation(v_op.delivery_method);
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
-- 3. Drop the resolver last (both functions above stop referencing it
--    once the CREATE OR REPLACE calls above land).
-- ---------------------------------------------------------------------

DROP FUNCTION IF EXISTS calculator_resolve_operation_service(uuid, text);
