-- =====================================================================
-- 224 -- An operation with no recipient is quoted from its rail (staging first)
--
-- odd/tasks/panel-minimal-edit.md (T2c). Staging 2026-10-07 (operation 094eb6d6): crm_cambiar_servicio(op, 'zelle')
-- retires the card; crm_calcular_monto_destino (100/157/188/215/217) only quoted an operation with exactly ONE
-- vigente recipient, so the 26,000 GYD Zelle had no destination amount (and switching back to CUP, the card gone,
-- left none either).
-- 1. crm_calcular_monto_destino: with NO vigente recipient and a rail in delivery_method (cuban_card, zelle,
--    clasica, tropical, efectivo_usd), the same branch prices it: v_rail is the lone recipient's type or, with none,
--    the operation's delivery_method. Same helpers and rounding as the one-recipient case (Zelle through
--    cerebro_zelle_cotizar_op, USD single rate, cash rate, CUP rate; whole USD rounded down). Recipient amounts are
--    still written only when there is exactly one recipient. Unchanged: several recipients, manual locks, closed
--    operations, non-GYD sources, services other than remesa, no rail.
-- 2. trg_zz_recalc_destino_operations also fires on UPDATE OF delivery_method, service_type: the bot's
--    cerebro_marcar_destino_usd and the panel set the rail without touching the deposit. (A call from
--    crm_cambiar_servicio is not enough on its own: the bot path never calls it.)
-- Signature, SECURITY DEFINER, search_path and grants are as before.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_calcular_monto_destino(p_operation_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op            remittance_operations%ROWTYPE;
  v_found         boolean := true;
  v_vigente_count integer;
  v_ben           remittance_beneficiaries%ROWTYPE;
  v_rail          text;
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

      IF v_vigente_count <= 1
         AND coalesce(v_op.quoted_source_amount, 0) > 0
         AND upper(coalesce(v_op.source_currency, 'GYD')) = 'GYD'
      THEN
        IF v_vigente_count = 1 THEN
          SELECT * INTO v_ben
            FROM remittance_beneficiaries
           WHERE operation_id = p_operation_id AND status = 'vigente';
          v_rail := v_ben.beneficiary_type;
        ELSE
          -- (224) No recipient yet: the operation's own rail prices it with the same rules, so a Zelle / card / cash
          -- operation shows its destination amount before (or after losing) its recipient.
          v_rail := v_op.delivery_method;
        END IF;

        IF v_rail IN ('zelle', 'clasica', 'tropical') THEN
          -- (215) Zelle is priced by tier of the deposit; Clasica and Tropical keep the single rate.
          IF v_rail = 'zelle' THEN
            SELECT z.tasa INTO v_rate FROM cerebro_zelle_cotizar_op(v_op.id, v_op.quoted_source_amount) z;
          ELSE
            v_rate := crm_tasa_vigente('usd');
          END IF;
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
        ELSIF v_rail = 'efectivo_usd' THEN
          -- (188) Cash USD has its own rate, the calculator's efectivo_usd_gyd (via `tasas`
          -- as 'efectivo'). Whole dollars, rounded DOWN, like the other USD rails.
          v_rate := crm_tasa_vigente('efectivo');
          IF v_rate > 0 THEN
            v_amount := floor(v_op.quoted_source_amount / v_rate);
            v_currency := 'USD';
            v_computable := true;
          END IF;
        ELSIF v_rail = 'cuban_card' THEN
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

        IF v_vigente_count = 1
           AND NOT (v_op.admin_locked_fields ? 'beneficiaries')
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
END $function$;

-- Recompute when the rail (delivery_method) or the service changes, not only the deposit / currency / status:
-- the bot's cerebro_marcar_destino_usd and a panel service change set the rail with no recipient.
DROP TRIGGER IF EXISTS trg_zz_recalc_destino_operations ON remittance_operations;
CREATE TRIGGER trg_zz_recalc_destino_operations
  AFTER INSERT OR UPDATE OF quoted_source_amount, source_currency, status, delivery_method, service_type
  ON remittance_operations
  FOR EACH ROW EXECUTE FUNCTION remittance_operations_recalc_destino_trigger();
