-- =====================================================================
-- 105 — Resolving a pending ledger entry, on one shared set of formulas
--
-- PURPOSE: 104 parks an entry as `verified_pending` when a rate it needed
-- was unset, naming the missing fields. Nothing could un-park it. This adds
-- that path: an admin supplies the rates that entry should have been priced
-- at, and it becomes a real, counted entry.
--
-- DELIBERATELY NOT AUTOMATIC (design decision 10): setting the global rates
-- later does NOT resolve old pending entries. The rate that applies to a
-- remesa is the rate agreed when it was delivered, which nobody but a human
-- can supply after the fact. Silently repricing yesterday's remesas at
-- today's rate would put invented numbers in a ledger.
--
-- WHY THE FORMULAS MOVE HERE: 104 spelled the money math out inline in
-- `calculator_feed_operation`. With a second caller it would have been
-- written twice, which is how two paths quietly start disagreeing about
-- what a remesa earned. The four formulas now live in two small functions
-- that both callers share, still mirroring formulas.ts 1:1, and
-- `calculator_feed_operation` is re-created here to call them. Its
-- behaviour is unchanged — `assertions/feed-matrix.sql` still passes
-- untouched, which is the point of running it again after this.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The formulas, in one place
-- ---------------------------------------------------------------------

-- How many service units a GYD deposit buys.
-- Mirrors document-rates.ts `deriveAmountFromDeposit`: CUP converts at the
-- global rate; the dollar rails are sold in whole units and always round UP
-- (a client who deposits 98.11 units' worth receives 99, never 98).
CREATE OR REPLACE FUNCTION calculator_amount_from_basis(
  p_service         text,
  p_basis           numeric,
  p_cup_global_rate numeric,
  p_usdt_sell_gyd   numeric
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN p_basis IS NULL OR p_basis <= 0 THEN NULL
           WHEN p_service = 'CUP' THEN
             CASE WHEN p_cup_global_rate IS NULL THEN NULL
                  ELSE p_basis * p_cup_global_rate END
           ELSE
             CASE WHEN p_usdt_sell_gyd IS NULL OR p_usdt_sell_gyd = 0 THEN NULL
                  ELSE ceil(p_basis / p_usdt_sell_gyd) END
         END;
$$;

-- What we billed, in GYD. Mirrors formulas.ts `calculateEntry`.
CREATE OR REPLACE FUNCTION calculator_facturado(
  p_service         text,
  p_amount          numeric,
  p_cup_global_rate numeric,
  p_usdt_sell_gyd   numeric
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN p_amount IS NULL THEN NULL
           WHEN p_service = 'CUP' THEN
             CASE WHEN p_cup_global_rate IS NULL OR p_cup_global_rate = 0 THEN NULL
                  ELSE p_amount / p_cup_global_rate END
           ELSE
             CASE WHEN p_usdt_sell_gyd IS NULL THEN NULL
                  ELSE p_amount * p_usdt_sell_gyd END
         END;
$$;

-- What it cost us, in GYD. `p_cup_rate` is the CUP formula's per-entry rate
-- (the snapshot of usdt_sell_cup); `p_usdt_buy_gyd` is formulas.ts costGyd.
CREATE OR REPLACE FUNCTION calculator_invertido(
  p_service      text,
  p_amount       numeric,
  p_cup_rate     numeric,
  p_usdt_buy_gyd numeric
) RETURNS numeric
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN p_amount IS NULL OR p_usdt_buy_gyd IS NULL THEN NULL
           WHEN p_service = 'CUP' THEN
             CASE WHEN p_cup_rate IS NULL OR p_cup_rate = 0 THEN NULL
                  ELSE (p_amount / p_cup_rate) * p_usdt_buy_gyd END
           ELSE p_amount * p_usdt_buy_gyd
         END;
$$;

COMMENT ON FUNCTION calculator_amount_from_basis(text, numeric, numeric, numeric) IS
  'Service units bought by a GYD deposit. Mirrors document-rates.ts deriveAmountFromDeposit.';
COMMENT ON FUNCTION calculator_facturado(text, numeric, numeric, numeric) IS
  'Billed GYD for an entry. Mirrors formulas.ts calculateEntry.';
COMMENT ON FUNCTION calculator_invertido(text, numeric, numeric, numeric) IS
  'Cost in GYD for an entry. Mirrors formulas.ts calculateEntry.';

-- ---------------------------------------------------------------------
-- 2. 104's feed, re-expressed on those functions (behaviour unchanged)
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
-- 3. crm_resolve_pending_entry
-- ---------------------------------------------------------------------

-- p_rates carries the rates this entry should have been priced at, keyed
-- exactly like crm_set_calculator_rates. Only fields the entry is MISSING
-- are taken: a rate already snapshotted at completion is the historical
-- fact and is never overwritten here.
--
-- p_reason is mandatory. A pending entry becomes real money in the totals,
-- and the audit trail has to say on whose word.
CREATE OR REPLACE FUNCTION crm_resolve_pending_entry(
  p_entry_id uuid,
  p_rates    jsonb,
  p_reason   text
) RETURNS remittance_calculator_entries
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_entry     remittance_calculator_entries;
  v_before    jsonb;
  v_basis     numeric;
  v_cup_glob  numeric;
  v_cup_rate  numeric;
  v_buy       numeric;
  v_sell      numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_missing   text[];
  v_key       text;
  v_value     numeric;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to resolve ledger entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.status <> 'verified_pending' THEN
    RAISE EXCEPTION 'only a pending entry can be resolved' USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(p_rates -> v_key) <> 'number' THEN
      RAISE EXCEPTION 'rate % must be a number', v_key USING ERRCODE = '22023';
    END IF;
    v_value := (p_rates ->> v_key)::numeric;
    IF v_value <= 0 OR v_value >= 1e9 THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  v_before := to_jsonb(v_entry);

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  v_sell     := coalesce(v_entry.usdt_sell_gyd,   (p_rates ->> 'usdt_sell_gyd')::numeric);

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN 'usdtSellGyd' END
    ], NULL);
  END IF;

  IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
    RAISE EXCEPTION 'still missing required rate(s): %', array_to_string(v_missing, ', ')
      USING ERRCODE = '22023';
  END IF;

  -- The deposit is re-read from the operation rather than trusted from the
  -- pending row, whose `amount` column held the deposit as a placeholder.
  SELECT quoted_source_amount INTO v_basis
    FROM remittance_operations WHERE id = v_entry.operation_id;

  v_amount    := calculator_amount_from_basis(v_entry.service, v_basis, v_cup_glob, v_sell);
  v_facturado := calculator_facturado(v_entry.service, v_amount, v_cup_glob, v_sell);
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
  END IF;

  UPDATE remittance_calculator_entries
     SET status          = 'completed',
         amount          = v_amount,
         cup_global_rate = v_cup_glob,
         cup_rate        = v_cup_rate,
         usdt_buy_gyd    = v_buy,
         usdt_sell_gyd   = v_sell,
         facturado_gyd   = v_facturado,
         invertido_gyd   = v_invertido,
         retorno_gyd     = v_facturado - v_invertido,
         missing_inputs  = NULL
   WHERE id = p_entry_id
   RETURNING * INTO v_entry;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
          'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
          v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$$;

REVOKE ALL ON FUNCTION crm_resolve_pending_entry(uuid, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION crm_resolve_pending_entry(uuid, jsonb, text) TO authenticated;

COMMENT ON FUNCTION crm_resolve_pending_entry(uuid, jsonb, text) IS
  'Admin+ only. Supplies the rates a pending entry was missing, reprices it '
  'from the operation''s deposit and marks it completed. Never overwrites a '
  'rate the entry already snapshotted. Audited with a mandatory reason.';
