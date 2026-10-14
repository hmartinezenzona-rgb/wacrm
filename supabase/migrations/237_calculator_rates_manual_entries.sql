-- =====================================================================
-- 237 -- The investment rates edit accepts MANUAL entries (staging first)
--
-- odd/tasks/calculator-edit-investment-rates.md (T6). Owner request (2026-10-14): in production every CUP entry of the week is a manual row
-- (source 'manual': typed in the Calculator, registered by crm_registrar_entradas_manuales, 228) with NULL cup_rate / usdt_buy_gyd /
-- cup_global_rate, so Editar showed no rates. "Extiendelo a las manuales tambien."
--   * CREATE OR REPLACE crm_corregir_tasas_entrada_calculadora (236): same signature, same grants, same result. Replaced body: 236 as applied
--     in production, md5(prosrc) 4332dccb71c56d9c59dbaa2f775ca134 (recorded at the 2026-10-14 production apply; staging holds the same
--     bytes, applied from the same file). Rollback restores 236's body.
--   * What changes: a manual row is accepted. The row has no snapshot, so the rates the formula needs must be GIVEN (CUP: usdt_buy_gyd AND
--     cup_rate; the others: usdt_buy_gyd) -- the existing "has no snapshot" refusals already say so -- and they are STORED on the row
--     from then on (usdt_buy_gyd; cup_rate for CUP). A later edit may send one rate and keeps the other as stored.
--   * Formula = the manual calculator's (web-calculator.ts calculateLine) = the ledger's (calculator_invertido, 105) for the supported services:
--       CUP (amount / cup_rate) * buy; ZELLE, MLC, CLASICA, TROPICAL, USDT amount * buy.
--     Manual services REFUSED (22023): RECARGA / SALDO_MOVIL (the unit cost lives only in the typed line, cost_gyd is NULL), DIRECTO (no
--     investment), anything else. A manual ZELLE / MLC / CLASICA / TROPICAL line whose typed text carries a discount ("%", the manual formula is
--     amount / (1 + pct) * cost) is also refused: the discount is not stored in a column.
--   * Kept refusals: non-admin (42501), not found (P0002), void / pending, archived week, cup_rate off CUP, non-positive rates, COMBO / VISA.
--   * Untouched: amount, service, facturado_gyd (and everything else of the row; raw_line, date, customer). The lock trigger
--     (remittance_calculator_entries_lock_completed, 228) is NOT modified: a manual row may change under wacrm.calculator_correction while it
--     stays completed, and the rate columns are not among the identity fields it freezes.
--   * NO audit row, by owner decision (2026-10-14), as in 236.
-- Grants identical to 236: REVOKE ALL FROM PUBLIC, anon; GRANT EXECUTE TO authenticated (production holds EXECUTE for postgres and
-- authenticated only). No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/calculator-entry-investment-rates.sql (cases 13-17: pending staging run, T8).
-- ROLLBACK: ROLLBACK-237-calculator-rates-manual-entries.sql
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
  -- amount * buy. A manual RECARGA / SALDO_MOVIL keeps no unit cost (it lives in the typed line), DIRECTO has no investment, and a
  -- discounted line ("10%/...") divides the amount by (1 + pct) first; none of those can be derived from the row, so they are refused.
  IF v_entry.source = 'manual' THEN
    IF v_entry.service NOT IN ('CUP', 'ZELLE', 'MLC', 'CLASICA', 'TROPICAL', 'USDT') THEN
      RAISE EXCEPTION 'a manual % entry has no investment rates to correct', v_entry.service USING ERRCODE = '22023';
    END IF;
    IF v_entry.service IN ('ZELLE', 'MLC', 'CLASICA', 'TROPICAL') AND position('%' IN coalesce(v_entry.raw_line, '')) > 0 THEN
      RAISE EXCEPTION 'a manual entry with a discount cannot be re-costed from its rates' USING ERRCODE = '22023';
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
  'Admin+ only. Sets the investment rates (usdt_buy_gyd, and cup_rate for CUP) of a completed chat-fed or manual entry (manual: CUP, ZELLE, MLC, CLASICA, TROPICAL, USDT, no discount; the rates are stored on the row) that is not in an archived '
  'week, recomputes invertido_gyd from the entry''s own amount/service/snapshot and retorno_gyd = facturado - invertido. facturado, '
  'the global rate, the sale rate and the rate version are untouched. COMBO and VISA have no rates and are refused. Not audited '
  '(owner decision).';
