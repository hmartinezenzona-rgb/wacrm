-- =====================================================================
-- ROLLBACK-111 — reverts 111_usd_amount_rounds_down.sql
--
-- Restores 105's and 107's ceil bodies byte for byte, so the dollar rails
-- (ZELLE/CLASICA/TROPICAL) go back to rounding UP in both
-- calculator_amount_from_basis (the shared ledger/pending-resolution
-- helper) and crm_calcular_monto_destino (the panel's own RPC).
--
-- CUP IS NOT TOUCHED, exactly as 111 did not touch it.
--
-- Amounts already recomputed by 111 are NOT restored to their old ceil
-- values: nothing records what they were. Any open operation keeps its
-- rounded-down figure until its next recalculation, which will then round
-- up again.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. calculator_amount_from_basis — back to 105's ceil.
-- ---------------------------------------------------------------------

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
                  ELSE ceil(p_basis / p_usdt_sell_gyd) END
         END;
$function$;

-- ---------------------------------------------------------------------
-- 2. crm_calcular_monto_destino — back to 107's ceil, verbatim.
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

REVOKE ALL ON FUNCTION crm_calcular_monto_destino(uuid) FROM PUBLIC, anon, authenticated;
