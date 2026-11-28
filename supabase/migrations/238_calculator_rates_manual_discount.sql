-- =====================================================================
-- 238 -- The investment rates edit re-costs MANUAL lines with a discount (staging first)
--
-- odd/tasks/calculator-edit-investment-rates.md (T7b). 237 refused every manual ZELLE / MLC / CLASICA / TROPICAL line whose typed text
-- carries a "%", because the discount was assumed to be lost. It is not: the typed line is kept in raw_line, e.g.
--   "• Zulemys 76 Clásica (3%/238/260)"  -> discount 3 %, buy 238, sale 260, invertido = 76 / 1.03 * 238 = 17561.165...
-- CREATE OR REPLACE crm_corregir_tasas_entrada_calculadora (237): same signature, same grants, same result. Replaced body: 237 as applied
-- on staging, md5(prosrc) a111e1b5010f6ad4cf32f84230daa045 (queried 2026-10-14; the ROLLBACK restores 237's body).
--   * What changes: the "%" refusal is replaced by reading the discount from raw_line. Formula (the manual calculator's, web-calculator.ts
--     calculateLine, = formulas.ts calculateEntry): invertido = amount / (1 + pct / 100) * usdt_buy_gyd, only for ZELLE, MLC, CLASICA and
--     TROPICAL and only when pct > 0; every other manual service keeps amount * buy / (amount / cup) * buy.
--   * Discount rule, the SQL twin of parseManualLineRates / procesarTexto (src/lib/calculator/web-calculator.ts):
--       detail  = the text between the FIRST "(" and the FINAL ")" of raw_line (regex '\((.*)\)\s*$'; the customer cannot hold a "(").
--       slot    = the first "/"-separated piece of the detail. It is a discount only if it contains a "%".
--       pct     = the leading decimal of that slot with the "%" removed, as JavaScript parseFloat reads it:
--                   "3%" -> 3, "3.5%" -> 3.5, " 3 % " -> 3, ".5%" -> 0.5, "0%" -> none, "3,5%" -> 3 (parseFloat stops at the comma;
--                   the calculator costed the stored row with 3, so the re-cost keeps 3).
--       "%" in any other slot is no discount (the calculator ignores it).
--     REFUSED (22023), because parseFloat does not give a usable percent there and guessing would store a wrong invertido:
--       a sign ("-5%", "+5%"), non-numeric text ("abc%", "%"), an exponent ("3e1%": JavaScript reads 30, SQL refuses).
--     A discount on a CUP or USDT line is ignored, as in the calculator.
--   * Not done (kept the API contract): when a manual row has no stored rates and the caller omits one, SQL does NOT take it from raw_line;
--     the UI reads the quote from the line (parseManualLineRates) and sends the full set.
--   * Untouched: everything 237 kept (refusals, lock trigger, no audit row, facturado, amount, service, raw_line).
-- Grants identical to 236/237: REVOKE ALL FROM PUBLIC, anon; GRANT EXECUTE TO authenticated (production holds EXECUTE for postgres and
-- authenticated only; staging also holds service_role from its own history -- not granted here). No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/calculator-entry-investment-rates.sql (cases 18-20).
-- ROLLBACK: ROLLBACK-238-calculator-rates-manual-discount.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_corregir_tasas_entrada_calculadora(
  p_entry_id      uuid,
  p_usdt_buy_gyd  numeric DEFAULT NULL,
  p_cup_rate      numeric DEFAULT NULL
) RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry     remittance_calculator_entries;
  v_buy       numeric;
  v_cup       numeric;
  v_invertido numeric;
  v_detail    text;
  v_slot      text;
  v_pct_text  text;
  v_pct       numeric := 0;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to correct calculator entries' USING ERRCODE = '42501';
  END IF;

  IF v_entry.source NOT IN ('completed_operation', 'manual') THEN
    RAISE EXCEPTION 'only a chat-fed or a manual entry has investment rates to correct' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status <> 'completed' THEN
    RAISE EXCEPTION 'entry is % and its rates cannot be corrected here', v_entry.status USING ERRCODE = '22023';
  END IF;

  IF EXISTS (SELECT 1 FROM remittance_calculator_week_entries we WHERE we.entry_id = v_entry.id) THEN
    RAISE EXCEPTION 'entry belongs to an archived week and cannot be corrected' USING ERRCODE = '22023';
  END IF;

  IF p_usdt_buy_gyd IS NULL AND p_cup_rate IS NULL THEN
    RAISE EXCEPTION 'at least one rate is required' USING ERRCODE = '22023';
  END IF;

  IF p_usdt_buy_gyd IS NOT NULL AND NOT (p_usdt_buy_gyd > 0 AND p_usdt_buy_gyd < 1e9) THEN
    RAISE EXCEPTION 'usdt_buy_gyd must be greater than zero' USING ERRCODE = '22023';
  END IF;

  IF p_cup_rate IS NOT NULL AND NOT (p_cup_rate > 0 AND p_cup_rate < 1e9) THEN
    RAISE EXCEPTION 'cup_rate must be greater than zero' USING ERRCODE = '22023';
  END IF;

  IF v_entry.service IN ('COMBO', 'VISA') THEN
    RAISE EXCEPTION '% entries have no investment rates', v_entry.service USING ERRCODE = '22023';
  END IF;

  -- (237) A manual row is typed with the manual calculator's formulas. Only the plain ones are rebuilt here: CUP (amount / cup) * buy and
  -- amount * buy. A manual RECARGA / SALDO_MOVIL keeps no unit cost (it lives in the typed line) and DIRECTO has no investment: refused.
  -- (238) A ZELLE / MLC / CLASICA / TROPICAL line may carry a leading "N%" discount in its typed text: read it from raw_line with the
  -- calculator's rule (see the header) and divide the amount by (1 + pct / 100) first. An unreadable discount form is refused, not guessed.
  IF v_entry.source = 'manual' THEN
    IF v_entry.service NOT IN ('CUP', 'ZELLE', 'MLC', 'CLASICA', 'TROPICAL', 'USDT') THEN
      RAISE EXCEPTION 'a manual % entry has no investment rates to correct', v_entry.service USING ERRCODE = '22023';
    END IF;
    IF v_entry.service IN ('ZELLE', 'MLC', 'CLASICA', 'TROPICAL') THEN
      v_detail := substring(coalesce(v_entry.raw_line, '') from '\((.*)\)\s*$');
      v_slot   := split_part(coalesce(v_detail, ''), '/', 1);
      IF position('%' IN v_slot) > 0 THEN
        -- parseFloat of the slot without its "%": an unsigned decimal at the start, not followed by an exponent.
        v_pct_text := substring(replace(v_slot, '%', '') from '^\s*([0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?![0-9eE])');
        IF v_pct_text IS NULL THEN
          RAISE EXCEPTION 'a manual entry whose discount cannot be read from its line cannot be re-costed from its rates' USING ERRCODE = '22023';
        END IF;
        v_pct := v_pct_text::numeric;
      END IF;
    END IF;
  END IF;

  IF p_cup_rate IS NOT NULL AND v_entry.service <> 'CUP' THEN
    RAISE EXCEPTION 'cup_rate only applies to the CUP service' USING ERRCODE = '22023';
  END IF;

  v_buy := coalesce(p_usdt_buy_gyd, v_entry.usdt_buy_gyd);
  v_cup := coalesce(p_cup_rate, v_entry.cup_rate);

  IF v_buy IS NULL THEN
    RAISE EXCEPTION 'the entry has no usdt_buy_gyd snapshot' USING ERRCODE = '22023';
  END IF;

  IF v_entry.service = 'CUP' THEN
    IF v_cup IS NULL OR v_cup = 0 THEN
      RAISE EXCEPTION 'the entry has no cup_rate snapshot' USING ERRCODE = '22023';
    END IF;
    v_invertido := calculator_invertido('CUP', v_entry.amount, v_cup, v_buy);
  ELSIF v_entry.service = 'RECARGA' THEN
    IF v_entry.cost_gyd IS NULL THEN
      RAISE EXCEPTION 'the entry has no USDT cost per recharge' USING ERRCODE = '22023';
    END IF;
    v_invertido := v_entry.amount * v_entry.cost_gyd * v_buy;
  ELSIF v_entry.service = 'SALDO_MOVIL' THEN
    IF v_entry.cost_gyd IS NULL OR v_entry.basis_gyd IS NULL OR v_entry.sale_gyd IS NULL OR v_entry.sale_gyd <= 0
       OR mod(v_entry.basis_gyd, v_entry.sale_gyd) <> 0 THEN
      RAISE EXCEPTION 'the entry has no usable package count to cost' USING ERRCODE = '22023';
    END IF;
    v_invertido := (v_entry.basis_gyd / v_entry.sale_gyd) * v_entry.cost_gyd * v_buy;
  ELSIF v_pct > 0 THEN
    -- (238) discounted manual line: amount / (1 + pct / 100) * buy (web-calculator.ts calculateLine, formulas.ts calculateEntry).
    v_invertido := v_entry.amount / (1 + v_pct / 100) * v_buy;
  ELSE
    v_invertido := calculator_invertido(v_entry.service, v_entry.amount, NULL, v_buy);
  END IF;

  IF v_invertido IS NULL OR v_invertido < 0 OR v_invertido >= 1e15 OR v_entry.facturado_gyd IS NULL THEN
    RAISE EXCEPTION 'the entry cannot be costed with these rates' USING ERRCODE = '22023';
  END IF;

  -- Open the append-only guard's narrow hole (149) for exactly this UPDATE.
  PERFORM set_config('wacrm.calculator_correction', 'true', true);

  UPDATE remittance_calculator_entries
     SET usdt_buy_gyd  = v_buy,
         cup_rate      = CASE WHEN service IN ('RECARGA', 'SALDO_MOVIL') THEN v_buy
                              WHEN service = 'CUP' THEN v_cup
                              ELSE cup_rate END,
         invertido_gyd = v_invertido,
         retorno_gyd   = facturado_gyd - v_invertido
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  PERFORM set_config('wacrm.calculator_correction', '', true);

  RETURN v_entry;
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_corregir_tasas_entrada_calculadora(uuid, numeric, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_corregir_tasas_entrada_calculadora(uuid, numeric, numeric) TO authenticated;

COMMENT ON FUNCTION public.crm_corregir_tasas_entrada_calculadora(uuid, numeric, numeric) IS
  'Admin+ only. Sets the investment rates (usdt_buy_gyd, and cup_rate for CUP) of a completed chat-fed or manual entry (manual: CUP, ZELLE, MLC, CLASICA, TROPICAL, USDT; a ZELLE/MLC/CLASICA/TROPICAL discount is read from raw_line; the rates are stored on the row) that is not in an archived '
  'week, recomputes invertido_gyd from the entry''s own amount/service/snapshot and retorno_gyd = facturado - invertido. facturado, '
  'the global rate, the sale rate and the rate version are untouched. COMBO and VISA have no rates and are refused. Not audited '
  '(owner decision).';
