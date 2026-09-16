-- =====================================================================
-- ROLLBACK-105 — reverts 105_calculator_resolve_pending.sql
--
-- Drops the pending-resolution RPC and the three shared formula helpers,
-- and restores `calculator_feed_operation` to 104's inline arithmetic so
-- the feed keeps working with 105 gone.
--
-- Entries an admin already resolved keep their figures and stay
-- `completed` — that is the correct outcome, not a leak: the numbers were
-- real and the audit row explaining them survives. Only the ability to
-- resolve NEW pending entries is removed.
--
-- The `calculator_pending_resolved` audit action stays permitted: it is
-- introduced by 104's CHECK, not this migration, and ROLLBACK-104 is what
-- removes it.
-- =====================================================================

DROP FUNCTION IF EXISTS crm_resolve_pending_entry(uuid, jsonb, text);

-- Restore 104's self-contained feed before dropping what it would call.
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

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  IF v_service = 'CUP' THEN
    v_currency := 'CUP';
    IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := v_basis * v_rates.cup_global_rate;
      v_facturado := v_amount / v_rates.cup_global_rate;
      v_invertido := (v_amount / v_rates.usdt_sell_cup) * v_rates.usdt_buy_gyd;
    END IF;
  ELSE
    v_currency := 'USD';
    IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := ceil(v_basis / v_rates.usdt_sell_gyd);
      v_facturado := v_amount * v_rates.usdt_sell_gyd;
      v_invertido := v_amount * v_rates.usdt_buy_gyd;
    END IF;
  END IF;

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

DROP FUNCTION IF EXISTS calculator_amount_from_basis(text, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS calculator_facturado(text, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS calculator_invertido(text, numeric, numeric, numeric);
