-- =====================================================================
-- 107 — Dollar rails round UP, in the panel too
--
-- PURPOSE: the same remesa was being valued two different ways.
--
--   deposit 75,000 GYD, rate 260 -> 288.46 whole units
--     panel  (100)      floor -> 288 units quoted to the client
--     ledger (104/105)  ceil  -> 289 units recorded as sold
--
-- Both cannot be right, and while they disagree the ledger records a
-- different quantity than the one actually delivered -- the one thing a
-- ledger exists to prevent.
--
-- THE RULE IS UP: a service sold in whole units rounds to the next one,
-- never down (document-rates.ts states it as owner-confirmed, and 105's
-- calculator_amount_from_basis implements it). 100's `floor`, and its
-- comment claiming to mirror the bot, is the side that was wrong.
--
-- WHAT IT COSTS, stated plainly: at 75,000 GYD and rate 260 we hand over
-- one extra unit and absorb 140 GYD instead of keeping the 120 GYD
-- remainder. That is the owner's call; it is now the same call in both
-- places.
--
-- SLICE 10 MUST FOLLOW: n8n's bot still floors when it quotes the client
-- in chat. Until that changes, the bot says 288 while the panel and the
-- ledger say 289. This closes the CRM half only.
--
-- THE FUNCTION BELOW IS 100'S, VERBATIM, WITH ONE LINE CHANGED. Nothing
-- else about it moves: the remesa-only gate, the "never overwrite a
-- non-calculated value" condition, the admin-lock checks, the idempotent
-- IS DISTINCT FROM guards and the branch that clears a stale calculation
-- are all exactly as 100 wrote them.
--
-- CUP IS NOT TOUCHED and still differs in one case: the panel stores
-- `round(deposit * rate)` while the ledger keeps the product unrounded, so
-- a fractional rate can leave them a fraction of a peso apart. Today's
-- whole rate (3) agrees exactly. Left for its own decision rather than
-- folded into a change about a different rule.
-- =====================================================================

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
            -- Whole units, rounded UP: a part-unit is delivered as a
            -- full one. Mirrors document-rates.ts deriveAmountFromDeposit
            -- and 105's calculator_amount_from_basis, so the panel and the
            -- ledger cannot disagree about one remesa. n8n's bot still
            -- floors — slice 10 closes that half.
            v_amount := ceil(v_op.quoted_source_amount / v_rate);
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
-- An operation quoted under the old rule would otherwise sit in the panel
-- showing a figure this function no longer produces. Completed and
-- cancelled operations are deliberately skipped by the function itself --
-- their amount is what was actually delivered, and rewriting a closed
-- remesa to match a rule introduced afterwards would be a lie.

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
