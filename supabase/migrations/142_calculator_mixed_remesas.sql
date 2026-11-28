-- =====================================================================
-- 142 — Mixed remesas: one calculator line per service
--
-- WHY
--   A mixed remesa (129: Cuban cards in CUP + Zelle in USD paid by ONE
--   deposit) had no calculator line at all: 141 leaves it unresolved,
--   because a ledger line carries one service and one formula. The user
--   asked on 2026-09-28 to fix it ("arreglemos lo de las mixtas").
--
-- WHAT
--   1. `basis_gyd` on remittance_calculator_entries: the GYD the line is
--      priced on. For a mixed remesa it is that service's share of the
--      deposit; for every other line it equals the deposit.
--   2. The completed-operation uniqueness moves from (account, operation)
--      to (account, operation, service): a mixed remesa has one live line
--      per service. Void/revive (104's trigger) already acts on every line
--      of the operation.
--   3. calculator_operation_parts(): the parts to feed.
--        no current beneficiaries -> legacy delivery_method mapping (as 141)
--        one service              -> one part on the whole deposit (as 141)
--        several services (mixed) -> one part per service:
--          CUP part  basis = sum(card CUP) / cup_global_rate
--          USD parts basis = sum(USD) x usdt_sell_gyd, except the LAST USD
--                    part, which takes the rest of the deposit so the parts
--                    add up to it exactly (its floor rounding absorbs the
--                    under-1-USD leftover, as a single-Zelle remesa does).
--          A missing or mismatched amount (or a non-positive share) makes
--          every part verified_pending with missing 'beneficiaryAmounts'.
--          Never an invented number.
--   4. calculator_feed_operation feeds every part; calculator_unfed_operations
--      calls an operation fed only when every part has a live line.
--   5. crm_resolve_pending_entry prices a line on its own basis_gyd.
--   6. crm_cierre_financiero counts DISTINCT operations in its totals and
--      per day, so a mixed remesa counts once (per service it counts in each
--      service, which is right).
--
-- UNCHANGED: the formulas, the rates, the trigger guard order, and every
-- non-mixed remesa (feed-matrix.sql, feed-from-beneficiaries.sql).
--
-- ROLLBACK: ROLLBACK-142-calculator-mixed-remesas.sql
-- =====================================================================

ALTER TABLE remittance_calculator_entries
  ADD COLUMN IF NOT EXISTS basis_gyd numeric;
ALTER TABLE remittance_calculator_entries
  DROP CONSTRAINT IF EXISTS remittance_calculator_entries_basis_gyd_chk;
ALTER TABLE remittance_calculator_entries
  ADD CONSTRAINT remittance_calculator_entries_basis_gyd_chk
  CHECK (basis_gyd IS NULL OR (basis_gyd > 0 AND basis_gyd < 1e15));

DROP INDEX IF EXISTS remittance_calculator_entries_account_operation_uk;
CREATE UNIQUE INDEX IF NOT EXISTS remittance_calculator_entries_account_operation_service_uk
  ON remittance_calculator_entries (account_id, operation_id, service)
  WHERE source = 'completed_operation';

CREATE OR REPLACE FUNCTION calculator_operation_parts(
  p_op    remittance_operations,
  p_rates calculator_rate_versions
) RETURNS TABLE (service text, basis numeric, placeholder_amount numeric, missing text[])
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
  v_total     numeric := p_op.quoted_source_amount;
  v_n_benef   integer;
  v_n_unknown integer;
  v_n_svc     integer;
  v_bad       boolean;
  v_last_usd  text;
  v_rest      numeric;
  r           record;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE calculator_service_for_operation(b.beneficiary_type) IS NULL),
         count(DISTINCT calculator_service_for_operation(b.beneficiary_type))
    INTO v_n_benef, v_n_unknown, v_n_svc
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_op.id AND b.status = 'vigente';

  -- Legacy shape and single-service remesas: exactly as 141.
  IF v_n_benef = 0 OR (v_n_unknown = 0 AND v_n_svc = 1) THEN
    service := calculator_resolve_operation_service(p_op.id, p_op.delivery_method);
    IF service IS NOT NULL THEN
      basis := v_total; placeholder_amount := v_total; missing := ARRAY[]::text[];
      RETURN NEXT;
    END IF;
    RETURN;
  END IF;

  -- A beneficiary type the calculator does not know: stay unresolved.
  IF v_n_unknown > 0 THEN
    RETURN;
  END IF;

  -- MIXED. Every amount must be known, positive and in its rail's currency.
  SELECT bool_or(b.amount IS NULL OR b.amount <= 0
                 OR b.currency IS DISTINCT FROM
                    CASE WHEN calculator_service_for_operation(b.beneficiary_type) = 'CUP' THEN 'CUP' ELSE 'USD' END)
    INTO v_bad
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_op.id AND b.status = 'vigente';

  SELECT max(calculator_service_for_operation(b.beneficiary_type))
    INTO v_last_usd
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_op.id AND b.status = 'vigente'
     AND calculator_service_for_operation(b.beneficiary_type) <> 'CUP';

  IF v_bad OR v_total IS NULL OR v_total <= 0 OR v_last_usd IS NULL
     OR p_rates.cup_global_rate IS NULL OR p_rates.usdt_sell_gyd IS NULL THEN
    FOR r IN
      SELECT calculator_service_for_operation(b.beneficiary_type) AS svc,
             sum(b.amount) FILTER (WHERE b.amount > 0) AS amt
        FROM remittance_beneficiaries b
       WHERE b.operation_id = p_op.id AND b.status = 'vigente'
       GROUP BY 1 ORDER BY 1
    LOOP
      service := r.svc; basis := NULL;
      placeholder_amount := coalesce(r.amt, v_total);
      missing := CASE WHEN v_bad OR v_last_usd IS NULL THEN ARRAY['beneficiaryAmounts'] ELSE ARRAY[]::text[] END;
      RETURN NEXT;
    END LOOP;
    RETURN;
  END IF;

  v_rest := v_total;
  FOR r IN
    SELECT calculator_service_for_operation(b.beneficiary_type) AS svc, sum(b.amount) AS amt
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_op.id AND b.status = 'vigente'
     GROUP BY 1
     ORDER BY (calculator_service_for_operation(b.beneficiary_type) = v_last_usd), 1
  LOOP
    service := r.svc; placeholder_amount := r.amt; missing := ARRAY[]::text[];
    IF r.svc = v_last_usd THEN
      basis := v_rest;
    ELSIF r.svc = 'CUP' THEN
      basis := round(r.amt / p_rates.cup_global_rate, 2);
    ELSE
      basis := round(r.amt * p_rates.usdt_sell_gyd, 2);
    END IF;
    v_rest := v_rest - basis;
    IF basis IS NULL OR basis <= 0 THEN
      -- A share that does not fit the deposit: every part goes pending.
      FOR r IN
        SELECT calculator_service_for_operation(b.beneficiary_type) AS svc, sum(b.amount) AS amt
          FROM remittance_beneficiaries b
         WHERE b.operation_id = p_op.id AND b.status = 'vigente'
         GROUP BY 1 ORDER BY 1
      LOOP
        service := r.svc; basis := NULL; placeholder_amount := r.amt;
        missing := ARRAY['beneficiaryAmounts'];
        RETURN NEXT;
      END LOOP;
      RETURN;
    END IF;
  END LOOP;

  -- Second pass: emit (the first pass only validated the shares).
  v_rest := v_total;
  FOR r IN
    SELECT calculator_service_for_operation(b.beneficiary_type) AS svc, sum(b.amount) AS amt
      FROM remittance_beneficiaries b
     WHERE b.operation_id = p_op.id AND b.status = 'vigente'
     GROUP BY 1
     ORDER BY (calculator_service_for_operation(b.beneficiary_type) = v_last_usd), 1
  LOOP
    service := r.svc; placeholder_amount := r.amt; missing := ARRAY[]::text[];
    IF r.svc = v_last_usd THEN
      basis := v_rest;
    ELSIF r.svc = 'CUP' THEN
      basis := round(r.amt / p_rates.cup_global_rate, 2);
    ELSE
      basis := round(r.amt * p_rates.usdt_sell_gyd, 2);
    END IF;
    v_rest := v_rest - basis;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE ALL ON FUNCTION calculator_operation_parts(remittance_operations, calculator_rate_versions) FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION calculator_feed_operation(p_operation_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_part      record;
  v_missing   text[];
  v_basis     numeric;
  v_amount    numeric;
  v_facturado numeric;
  v_invertido numeric;
  v_currency  text;
  v_customer  text;
  v_entry_id  uuid;
  v_first_id  uuid;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  IF v_op.quoted_source_amount IS NULL OR v_op.quoted_source_amount <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates := calculator_rates_vigentes(v_op.account_id);

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' ELSE 'USD' END;

    IF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_rates.usdt_sell_gyd);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_rates.usdt_sell_gyd);
      v_invertido := calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd);
    END IF;

    IF v_basis IS NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_missing := ARRAY['beneficiaryAmounts'];
    END IF;

    IF v_amount IS NULL OR v_amount <= 0 THEN
      v_amount := v_part.placeholder_amount;
      v_facturado := NULL;
      v_invertido := NULL;
      IF coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_missing := ARRAY['beneficiaryAmounts'];
      END IF;
    END IF;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, customer_name,
      service, amount, amount_currency, basis_gyd,
      cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id,
      facturado_gyd, invertido_gyd, retorno_gyd,
      missing_inputs, delivery_mode, actor_user_id, completed_at
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      v_rates.cup_global_rate, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd, v_rates.usdt_sell_gyd, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp())
    )
    ON CONFLICT (account_id, operation_id, service) WHERE source = 'completed_operation'
    DO UPDATE SET
      status          = EXCLUDED.status,
      entry_date      = EXCLUDED.entry_date,
      customer_name   = EXCLUDED.customer_name,
      amount          = EXCLUDED.amount,
      amount_currency = EXCLUDED.amount_currency,
      basis_gyd       = EXCLUDED.basis_gyd,
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

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$$;

REVOKE ALL ON FUNCTION calculator_feed_operation(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE VIEW calculator_unfed_operations AS
  SELECT o.id            AS operation_id,
         o.account_id,
         o.completed_at,
         o.delivery_method,
         o.quoted_source_amount,
         calculator_resolve_operation_service(o.id, o.delivery_method) AS service,
         CASE
           WHEN p.n_parts = 0 THEN 'service_unresolved'
           WHEN p.n_parts > 1 THEN 'mixed_part_unfed'
           ELSE NULL
         END AS unfed_reason
    FROM remittance_operations o
   CROSS JOIN calculator_feed_state s
   CROSS JOIN LATERAL (
     SELECT count(*) AS n_parts,
            count(*) FILTER (WHERE NOT EXISTS (
              SELECT 1 FROM remittance_calculator_entries e
               WHERE e.account_id = o.account_id
                 AND e.operation_id = o.id
                 AND e.source = 'completed_operation'
                 AND e.service = part.service
                 AND e.status <> 'void')) AS n_unfed
       FROM calculator_operation_parts(o, calculator_rates_vigentes(o.account_id)) part
   ) p
   WHERE o.status = 'completed'
     AND o.completed_at >= s.feed_started_at
     AND o.quoted_source_amount > 0
     AND (p.n_parts = 0 OR p.n_unfed > 0);

COMMENT ON VIEW calculator_unfed_operations IS
  'Completed operations since feed_started_at missing a live ledger line — '
  'the recovery list for crm_feed_calculator. An operation is fed only when '
  'every part (one per service; several for a mixed remesa, 142) has a live '
  'line. unfed_reason: service_unresolved (no part could be resolved) or '
  'mixed_part_unfed. Empty is the normal state.';

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
  -- (142) A line of a MIXED remesa is priced on its own share of the
  -- deposit (basis_gyd), never on the whole deposit.
  IF v_entry.basis_gyd IS NOT NULL THEN
    v_basis := v_entry.basis_gyd;
  ELSIF EXISTS (SELECT 1 FROM remittance_calculator_entries o
                 WHERE o.account_id = v_entry.account_id
                   AND o.operation_id = v_entry.operation_id
                   AND o.source = 'completed_operation'
                   AND o.service <> v_entry.service
                   AND o.status <> 'void') THEN
    RAISE EXCEPTION 'this line belongs to a mixed remesa whose share is unknown: fix the beneficiary amounts and re-feed the operation'
      USING ERRCODE = '22023';
  ELSE
    SELECT quoted_source_amount INTO v_basis
      FROM remittance_operations WHERE id = v_entry.operation_id;
  END IF;

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
      count(DISTINCT operation_id)    AS operaciones,
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
      count(DISTINCT c.operation_id)     AS operaciones,
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
