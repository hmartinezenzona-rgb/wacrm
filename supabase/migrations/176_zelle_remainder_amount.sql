-- =====================================================================
-- 176 — a Zelle kept next to a card reparto gets the remainder of the remesa
--
-- 175 keeps the customer's Zelle vigente when a card reparto arrives (Kenia,
-- 2026-09-29: 150 USD = 100 Zelle + 30 + 20 USD Clasica), but the Zelle block
-- in the notes carries only the holder and the account: the "100 por Zelle"
-- lives in the chat, not in any field, so the panel and the calculator had no
-- amount for it.
--
-- Every other figure is stored, so the Zelle amount is derived, not guessed:
--   total GYD   = the deposit (quoted_source_amount) or, before the deposit,
--                 the bot's quote (cerebro_cotizacion_vigente, 171)
--   left        = total - CUP shares / CUP rate - USD shares x USD rate
--   Zelle (USD) = floor(left / USD rate)       -- whole dollars, business rounding
-- It is written only when exactly ONE vigente Zelle has no amount (or a
-- previously calculated one), every other vigente share has an amount, and
-- something is left; amount_origin = 'calculated', so a later change of the
-- deposit or the reparto recalculates it and a human amount is never touched.
-- crm_calcular_monto_destino (157's body, unchanged otherwise) calls it, so it
-- runs on the same triggers: a new deposit, a new reparto, a corrected share.
--
-- Guarded by supabase/staging/assertions/zelle-remainder-amount.sql
-- ROLLBACK: ROLLBACK-176-zelle-remainder-amount.sql (157's body, prosrc md5 0c5b4e17...)
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_monto_resto_zelle(p_operation_id uuid)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_op    remittance_operations%ROWTYPE;
  v_total numeric;
  v_usd   numeric := crm_tasa_vigente('usd');
  v_cup   numeric := crm_tasa_vigente('gyd');
  v_zelle uuid;
  v_resto numeric;
  v_monto numeric;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.admin_locked_fields ? 'beneficiaries' OR NOT (v_usd > 0 AND v_cup > 0) THEN RETURN NULL; END IF;

  v_total := CASE WHEN coalesce(v_op.quoted_source_amount, 0) > 0 THEN v_op.quoted_source_amount
                  ELSE cerebro_cotizacion_vigente(v_op.conversation_id) END;
  IF v_total IS NULL OR v_total <= 0 THEN RETURN NULL; END IF;

  -- Exactly one vigente Zelle without a human amount; every other vigente share priced.
  IF (SELECT count(*) FROM remittance_beneficiaries
       WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle'
         AND (amount IS NULL OR amount_origin = 'calculated')) <> 1
     OR (SELECT count(*) FROM remittance_beneficiaries
          WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle') <> 1
     OR EXISTS (SELECT 1 FROM remittance_beneficiaries
                 WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'zelle'
                   AND (amount IS NULL OR currency NOT IN ('CUP', 'USD'))) THEN
    RETURN NULL;
  END IF;

  SELECT id INTO v_zelle FROM remittance_beneficiaries
   WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type = 'zelle';

  SELECT v_total - coalesce(sum(CASE WHEN currency = 'CUP' THEN amount / v_cup ELSE amount * v_usd END), 0)
    INTO v_resto
    FROM remittance_beneficiaries
   WHERE operation_id = p_operation_id AND status = 'vigente' AND beneficiary_type <> 'zelle';

  v_monto := floor(v_resto / v_usd);
  IF v_monto <= 0 THEN v_monto := NULL; END IF;

  UPDATE remittance_beneficiaries
     SET amount = v_monto,
         currency = CASE WHEN v_monto IS NULL THEN NULL ELSE 'USD' END,
         amount_origin = CASE WHEN v_monto IS NULL THEN NULL ELSE 'calculated' END
   WHERE id = v_zelle
     AND (amount IS DISTINCT FROM v_monto OR (v_monto IS NOT NULL AND amount_origin IS DISTINCT FROM 'calculated'));
  RETURN v_monto;
END $$;

REVOKE ALL ON FUNCTION public.crm_monto_resto_zelle(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.crm_calcular_monto_destino(p_operation_id uuid)
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

        IF v_ben.beneficiary_type IN ('zelle', 'clasica', 'tropical') THEN
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

      -- (176) Several beneficiaries, one of them a Zelle without its amount (kept by
      -- 175 next to a card reparto): the Zelle gets what is left of the remesa.
      IF v_vigente_count > 1 AND NOT (v_op.admin_locked_fields ? 'beneficiaries') THEN
        PERFORM crm_monto_resto_zelle(p_operation_id);
      END IF;
    END IF;

    PERFORM set_config('wacrm.calc_destino', 'off', true);
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('wacrm.calc_destino', 'off', true);
    RAISE;
  END;
END $$;
