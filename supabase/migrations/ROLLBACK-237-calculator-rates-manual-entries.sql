-- ROLLBACK of 237_calculator_rates_manual_entries.sql: restores the body of crm_corregir_tasas_entrada_calculadora that migration 236 created
-- (chat-fed entries only; a manual row is refused again). Rows whose rates were stored through 237 keep them. No BEGIN/COMMIT.

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

  IF v_entry.source <> 'completed_operation' THEN
    RAISE EXCEPTION 'only a chat-fed entry has investment rates to correct' USING ERRCODE = '22023';
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
  'Admin+ only. Sets the investment rates (usdt_buy_gyd, and cup_rate for CUP) of a completed chat-fed entry that is not in an archived '
  'week, recomputes invertido_gyd from the entry''s own amount/service/snapshot and retorno_gyd = facturado - invertido. facturado, '
  'the global rate, the sale rate and the rate version are untouched. COMBO and VISA have no rates and are refused. Not audited '
  '(owner decision).';
