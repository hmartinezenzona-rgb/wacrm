-- =====================================================================
-- 111 — USD-rail amounts round DOWN, reversing 107
--
-- PURPOSE: 107 moved calculator_amount_from_basis (105) and
-- crm_calcular_monto_destino's own inline calculation (100) from floor to
-- ceil for the dollar rails (ZELLE/CLASICA/TROPICAL), reasoning that a
-- part-unit should be "delivered as a full one". That direction is wrong
-- and is reversed here.
--
-- WHY DOWN: rounding must favour the business, not the client. A deposit
-- of 75,000 GYD at 260 GYD/USD is 288.46 USD. Delivering 289 means handing
-- over 289 x 260 = 75,140 GYD of value against a 75,000 GYD deposit --
-- 140 GYD out of the business's pocket on every remittance that lands on
-- a fractional quotient. The n8n bot has always floored, and its own SQL
-- carries the same reasoning: "si de 28,000 GYD salen 107.69 dolares, se
-- entregan 107. Redondear a 108 seria entregar mas dinero del depositado."
-- The CRM is being brought in line with the bot, not the other way round.
--
-- CUP IS NOT TOUCHED: it uses basis * cup_global_rate (calculator_amount_
-- from_basis) and round() in the panel (crm_calcular_monto_destino), and
-- neither of those is a dollar-rail division -- this migration changes
-- ONLY the ceil/floor token on the USD rails, in each function, plus the
-- comment describing it. Nothing else about either function moves.
--
-- THE N8N WORKFLOW NEEDS NO CHANGE -- it already floors.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. calculator_amount_from_basis (105) -- shared by calculator_feed_
--    operation and crm_resolve_pending_entry, so fixing it here fixes
--    both the ledger feed and the pending-resolution path at once.
-- ---------------------------------------------------------------------

-- How many service units a GYD deposit buys.
-- Mirrors document-rates.ts `deriveAmountFromDeposit`: CUP converts at the
-- global rate; the dollar rails are sold in whole units and always round
-- DOWN, in the business's favour -- a client who deposits 98.11 units'
-- worth receives 98, never 99 (which would deliver more value than was
-- actually deposited).
CREATE OR REPLACE FUNCTION public.calculator_amount_from_basis(p_service text, p_basis numeric, p_cup_global_rate numeric, p_usdt_sell_gyd numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE
           WHEN p_basis IS NULL OR p_basis <= 0 THEN NULL
           WHEN p_service = 'CUP' THEN
             CASE WHEN p_cup_global_rate IS NULL THEN NULL
                  ELSE p_basis * p_cup_global_rate END
           ELSE
             CASE WHEN p_usdt_sell_gyd IS NULL OR p_usdt_sell_gyd = 0 THEN NULL
                  ELSE floor(p_basis / p_usdt_sell_gyd) END
         END;
$function$;

-- ---------------------------------------------------------------------
-- 2. crm_calcular_monto_destino (107) -- the panel's own RPC, which
--    carries its own ceil independent of the helper above. VERBATIM from
--    107, with ONLY the rounding line and the comment describing it
--    changed. The remesa-only gate, the "never overwrite a non-calculated
--    value" condition, the admin-lock checks, the idempotent IS DISTINCT
--    FROM guards and the stale-calculation clearing branch are all
--    exactly as 107 wrote them.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION crm_calcular_monto_destino(p_operation_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op            remittance_operations%ROWTYPE;
  v_found         boolean := true;
  v_vigente_count integer;
  v_ben           remittance_beneficiaries%ROWTYPE;
  v_rate          numeric;
  v_amount        numeric;
  v_currency      text;
  v_computable    boolean := false;
BEGIN
  -- Recursion guard: the UPDATEs below re-fire this migration's own AFTER
  -- triggers. If a calculation is already running higher up the call stack,
  -- do nothing here — the flag belongs to that outer invocation, so this
  -- nested call must not touch (and must not reset) it.
  IF current_setting('wacrm.calc_destino', true) = 'on' THEN
    RETURN;
  END IF;

  PERFORM set_config('wacrm.calc_destino', 'on', true);

  BEGIN
    SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
    IF NOT FOUND THEN
      v_found := false;
    END IF;

    -- Eligible at all: exists, is a remesa, is still open, its destination
    -- amount isn't human-locked, and it either has no destination amount
    -- yet or the one it has is this function's own prior calculation (never
    -- a pre-existing/manual value).
    IF v_found
       AND v_op.service_type = 'remesa'
       AND v_op.status NOT IN ('completed', 'cancelled')
       AND NOT (v_op.admin_locked_fields ? 'quoted_destination_amount')
       AND (v_op.quoted_destination_amount IS NULL
            OR coalesce(v_op.quoted_destination_origin, '') = 'calculated')
    THEN
      SELECT count(*) INTO v_vigente_count
        FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente';

      IF v_vigente_count = 1
         AND coalesce(v_op.quoted_source_amount, 0) > 0
         AND upper(coalesce(v_op.source_currency, 'GYD')) = 'GYD'
      THEN
        SELECT * INTO v_ben
          FROM remittance_beneficiaries
         WHERE operation_id = p_operation_id AND status = 'vigente';

        IF v_ben.beneficiary_type = 'zelle' THEN
          v_rate := crm_tasa_vigente('usd');
          IF v_rate > 0 THEN
            -- Whole units, rounded DOWN, in the business's favour: a
            -- part-unit is never delivered as a full one, because that
            -- hands over more value than the deposit covers (75,000 GYD
            -- at 260 is 288.46 USD; delivering 289 gives away 140 GYD).
            -- Mirrors document-rates.ts deriveAmountFromDeposit and 111's
            -- calculator_amount_from_basis, so the panel and the ledger
            -- cannot disagree about one remesa. n8n's bot has always
            -- floored — this brings the panel in line with it.
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_ben.beneficiary_type = 'cuban_card' THEN
          v_rate := crm_tasa_vigente('gyd');
          IF v_rate > 0 THEN
            v_amount := round(v_op.quoted_source_amount * v_rate);
            v_currency := 'CUP';
            v_computable := true;
          END IF;
        END IF;
      END IF;

      IF v_computable THEN
        UPDATE remittance_operations
           SET quoted_destination_amount = v_amount,
               destination_currency = v_currency,
               quoted_destination_rate = v_rate,
               quoted_destination_origin = 'calculated'
         WHERE id = p_operation_id
           AND (quoted_destination_amount IS DISTINCT FROM v_amount
                OR destination_currency IS DISTINCT FROM v_currency
                OR quoted_destination_rate IS DISTINCT FROM v_rate
                OR quoted_destination_origin IS DISTINCT FROM 'calculated');

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries')
           AND (v_ben.amount IS NULL OR v_ben.amount_origin = 'calculated')
        THEN
          UPDATE remittance_beneficiaries
             SET amount = v_amount,
                 currency = v_currency,
                 amount_origin = 'calculated'
           WHERE id = v_ben.id
             AND (amount IS DISTINCT FROM v_amount
                  OR currency IS DISTINCT FROM v_currency
                  OR amount_origin IS DISTINCT FROM 'calculated');
        END IF;
      ELSIF v_op.quoted_destination_origin = 'calculated' THEN
        -- No longer computable (e.g. a second beneficiary showed up, or the
        -- rate disappeared) but the current value was this function's own
        -- stale calculation — clear it rather than leave a number nothing
        -- can now reproduce. destination_currency is left untouched: it is
        -- not exclusively this migration's field to clear.
        UPDATE remittance_operations
           SET quoted_destination_amount = NULL,
               quoted_destination_rate = NULL,
               quoted_destination_origin = NULL
         WHERE id = p_operation_id;

        IF NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
          UPDATE remittance_beneficiaries
             SET amount = NULL,
                 currency = NULL,
                 amount_origin = NULL
           WHERE operation_id = p_operation_id
             AND status = 'vigente'
             AND amount_origin = 'calculated';
        END IF;
      END IF;
    END IF;

    PERFORM set_config('wacrm.calc_destino', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('wacrm.calc_destino', 'off', true);
    RAISE;
  END;
END $$;


-- ---------------------------------------------------------------------
-- One-time recompute of open dollar-rail operations
-- ---------------------------------------------------------------------
-- Same reasoning, and the same block, as 107 used when it moved the rule
-- the other way: an operation quoted under the outgoing rule would
-- otherwise sit in the panel showing a figure this function no longer
-- produces. Staging has none open right now, but production will at
-- cutover, and a stale quote there is a dollar of real money.
--
-- Completed and cancelled operations are deliberately skipped -- their
-- amount is what was actually delivered, and rewriting a closed remesa to
-- match a rule introduced afterwards would be a lie. That also means any
-- remesa already delivered at the rounded-up figure keeps it: the ledger
-- records what happened, not what today's rule would have produced.

DO $recompute$
DECLARE
  v_id uuid;
BEGIN
  FOR v_id IN
    SELECT id FROM remittance_operations
     WHERE status NOT IN ('completed', 'cancelled')
       AND quoted_destination_origin = 'calculated'
       AND destination_currency = 'USD'
  LOOP
    PERFORM crm_calcular_monto_destino(v_id);
  END LOOP;
END;
$recompute$;

REVOKE ALL ON FUNCTION crm_calcular_monto_destino(uuid) FROM PUBLIC, anon, authenticated;
