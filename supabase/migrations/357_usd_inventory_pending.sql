-- =====================================================================
-- 357 -- Clasica / Tropical USD inventory: resolving a pending line consumes the USD (staging first)
--
-- odd/tasks/usd-card-inventory.md (T2b). Closes the gap left by 356: crm_resolve_pending_entry (an admin pricing a pending chat line with
-- rates) now takes the USD of a Clasica / Tropical line from the cards like the feed does, with the lot cost in invertido_gyd. Only when the
-- account has an active card of the service and the operation is not a Mexico one; otherwise today's behavior, byte for byte. A shortfall
-- or a failure alerts and keeps today's cost (never blocks, never aborts). Voiding / deleting the entry already returns the USD (356).
-- Starts from the LIVE staging body of 2026-11-06, md5 874a3f1b62cb (240 + 223 version). Same signature and ACL (CREATE OR REPLACE).
-- No BEGIN/COMMIT. Guarded by supabase/staging/assertions/usd-inventory-pending.sql. ROLLBACK: ROLLBACK-357-usd-inventory-pending.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.crm_resolve_pending_entry(p_entry_id uuid, p_rates jsonb, p_reason text)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_zrate     numeric;
  v_cost      numeric;
  v_inv       record;
  v_at        timestamptz;
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

  -- (209) A COMBO line is priced by the combo's cost (crm_set_combo_costo, panel), never by rates.
  IF v_entry.service = 'COMBO' THEN
    RAISE EXCEPTION 'a combo line is resolved by entering the combo cost in the panel, not with rates' USING ERRCODE = '22023';
  END IF;

  -- (213) A VISA line never needs rates (facturado = the deposit, invertido = 0): nothing to resolve with them.
  IF v_entry.service = 'VISA' THEN
    RAISE EXCEPTION 'a visa line needs no rates: it is priced by its deposit' USING ERRCODE = '22023';
  END IF;

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd',
                     'recarga_costo_usdt', 'saldo_costo_usdt') THEN
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

  -- (223) A RECARGA or SALDO_MOVIL line is priced by its own rule, never as a USD service (it used to ask for a Zelle-style
  -- sale rate and price floor(deposit / rate) units): units = deposit / its price (the recharge price the deposit pays,
  -- or the package price), facturado = units x price, invertido = units x cost per unit x USDT buy rate. What the
  -- line recorded wins (coalesce); the cost and the buy rate come from the payload. A saldo deposit that is not a
  -- whole number of packages (and a recharge deposit matching no price) cannot be resolved with rates: a person
  -- fixes the deposit and re-feeds the operation.
  IF v_entry.service IN ('RECARGA', 'SALDO_MOVIL') THEN
    v_buy   := coalesce(v_entry.usdt_buy_gyd, (p_rates ->> 'usdt_buy_gyd')::numeric);
    v_cost  := coalesce(v_entry.cost_gyd,
                        CASE WHEN v_entry.service = 'RECARGA' THEN (p_rates ->> 'recarga_costo_usdt')::numeric
                             ELSE (p_rates ->> 'saldo_costo_usdt')::numeric END);
    v_basis := coalesce(v_entry.basis_gyd, (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_entry.operation_id));
    v_sell  := CASE WHEN v_entry.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis) ELSE cerebro_saldo_precio() END;
    IF v_entry.service = 'SALDO_MOVIL' AND cerebro_saldo_paquetes(v_basis) IS NULL THEN
      RAISE EXCEPTION 'this saldo line is not a whole number of packages: fix the deposit and re-feed the operation' USING ERRCODE = '22023';
    END IF;
    IF v_entry.service = 'RECARGA' AND v_sell IS NULL THEN
      RAISE EXCEPTION 'this recarga line matches no recharge price: fix the deposit and re-feed the operation' USING ERRCODE = '22023';
    END IF;
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cost IS NULL THEN CASE WHEN v_entry.service = 'RECARGA' THEN 'recargaCostoUsdt' ELSE 'saldoCostoUsdt' END END,
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd' END
    ], NULL);
    IF coalesce(array_length(v_missing, 1), 0) > 0 THEN
      RAISE EXCEPTION 'a % line still needs: %', CASE WHEN v_entry.service = 'RECARGA' THEN 'recarga' ELSE 'saldo' END,
        array_to_string(v_missing, ', ') USING ERRCODE = '22023';
    END IF;
    v_amount    := floor(v_basis / v_sell);
    v_facturado := v_amount * v_sell;
    v_invertido := v_amount * v_cost * v_buy;
    IF v_amount IS NULL OR v_amount <= 0 THEN
      RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
    END IF;
    UPDATE remittance_calculator_entries
       SET status          = 'completed',
           -- (223) a saldo line shows the saldo (packages x saldo per package) in SM; a recharge keeps its units
           amount          = CASE WHEN v_entry.service = 'SALDO_MOVIL' THEN v_amount * cerebro_saldo_unidad() ELSE v_amount END,
           amount_currency = CASE WHEN v_entry.service = 'SALDO_MOVIL' THEN 'SM' ELSE amount_currency END,
           cup_rate        = v_buy,
           usdt_buy_gyd    = v_buy,
           usdt_sell_gyd   = v_sell,
           facturado_gyd   = v_facturado,
           invertido_gyd   = v_invertido,
           retorno_gyd     = v_facturado - v_invertido,
           cost_gyd        = v_cost,
           sale_gyd        = v_sell,
           missing_inputs  = NULL
     WHERE id = p_entry_id
     RETURNING * INTO v_entry;
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
    VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id,
            'calculator_pending_resolved', wacrm_current_actor(), btrim(p_reason),
            v_before, to_jsonb(v_entry));
    RETURN v_entry;
  END IF;

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  -- (193) A cash line sells at the cash rate.
  v_sell     := coalesce(v_entry.usdt_sell_gyd,
                         CASE WHEN v_entry.service = 'EFECTIVO' THEN (p_rates ->> 'efectivo_usd_gyd')::numeric
                              ELSE (p_rates ->> 'usdt_sell_gyd')::numeric END);

  -- (215) A ZELLE line whose operation's deposit total reaches a tier above the base one sells at that tier, not at
  -- the rate the payload carries. A deposit in the base tier keeps the rate the admin entered, and a line still
  -- missing its sell rate keeps asking for it (the required-rate check below is unchanged).
  IF v_entry.service = 'ZELLE' AND v_sell IS NOT NULL THEN
    SELECT z.tasa INTO v_zrate
      FROM remittance_operations o, cerebro_zelle_cotizar_op(o.id, o.quoted_source_amount) z
     WHERE o.id = v_entry.operation_id;
    IF v_zrate IS NOT NULL AND v_zrate < cerebro_tasa_zelle(50) THEN
      v_sell := coalesce(v_entry.usdt_sell_gyd, v_zrate);
    END IF;
  END IF;

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN CASE WHEN v_entry.service = 'EFECTIVO' THEN 'efectivoUsdGyd' ELSE 'usdtSellGyd' END END
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
  -- (235) Same rule as the feed: a resolved line bills the money that came in for it (its basis), not delivered units x price.
  IF v_facturado IS NOT NULL THEN
    v_facturado := v_basis;
  END IF;
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
  END IF;

  -- (240) CUP inventory: resolving a pending CUP chat line to completed takes its CUP exactly like the feed does (cup_consumir keyed
  -- on this entry, so it is idempotent; Cuba day of the operation's completion time). The line's cup_rate becomes
  -- amount / (consumed / lot-rate + shortfall / the resolved global rate) and invertido follows. A shortfall or any failure of the
  -- inventory part alerts and leaves the resolved global rate: it never aborts the resolve.
  IF v_entry.service = 'CUP' THEN
    BEGIN
      SELECT coalesce(o.completed_at, v_entry.completed_at, clock_timestamp()) INTO v_at
        FROM remittance_operations o WHERE o.id = v_entry.operation_id;
      v_at := coalesce(v_at, v_entry.completed_at, clock_timestamp());
      SELECT * INTO v_inv
        FROM cup_consumir(v_entry.account_id, v_amount, v_entry.id, v_entry.operation_id, v_at, cup_cuba_day(v_at));
      IF v_inv.missing_cup > 0 THEN
        PERFORM cup_alertar(v_entry.account_id, v_entry.operation_id, 'Inventario CUP insuficiente',
          format('La operacion de %s no se cubrio por completo con el inventario CUP: faltan %s CUP (limite diario o saldo agotado). '
                 'Esa parte usa la tasa global. Revise las tarjetas y lotes en Inventario CUP.',
                 coalesce(v_entry.customer_name, 'un cliente'), to_char(v_inv.missing_cup, 'FM999G999G999G990')));
      END IF;
      IF v_inv.consumed_cup > 0 THEN
        v_cup_rate  := v_amount / (v_inv.consumed_cup / v_inv.effective_rate + v_inv.missing_cup / v_cup_rate);
        v_invertido := calculator_invertido('CUP', v_amount, v_cup_rate, v_buy);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      PERFORM cup_alertar(v_entry.account_id, v_entry.operation_id, 'Error en el inventario CUP',
        format('No se pudo descontar el inventario CUP de la linea resuelta de %s (%s). Quedo con la tasa global; revise el inventario.',
               coalesce(v_entry.customer_name, 'un cliente'), left(SQLERRM, 200)));
    END;
  END IF;

  -- (357) Clasica / Tropical inventory: resolving a pending USD chat line takes its USD exactly like the feed (356) does, as if it had
  -- just been registered: usd_consumir keyed on this entry (idempotent), month of the operation's completion, invertido = (USDT the lots
  -- cost + any shortfall at par) x the buy rate that stands on the line (what the entry already recorded wins, as above). Only when the
  -- account has an active card of the service and it is not a Mexico operation. A shortfall or any failure alerts and leaves today's cost:
  -- it never blocks nor aborts the resolve.
  IF v_entry.service IN ('CLASICA', 'TROPICAL') AND upper(btrim(v_entry.amount_currency)) = 'USD' AND v_amount > 0
     AND EXISTS (SELECT 1 FROM usd_cards c WHERE c.account_id = v_entry.account_id AND c.service = v_entry.service AND c.active)
     AND NOT (v_entry.operation_id IS NOT NULL AND usd_operacion_es_mexico(v_entry.operation_id, (SELECT o.service_type FROM remittance_operations o WHERE o.id = v_entry.operation_id)))
  THEN
    BEGIN
      SELECT coalesce(o.completed_at, v_entry.completed_at, clock_timestamp()) INTO v_at
        FROM remittance_operations o WHERE o.id = v_entry.operation_id;
      v_at := coalesce(v_at, v_entry.completed_at, clock_timestamp());
      SELECT * INTO v_inv
        FROM usd_consumir(v_entry.account_id, v_entry.service, v_amount, v_entry.id, v_entry.operation_id, v_at,
                          CASE WHEN v_entry.operation_id IS NULL THEN 'manual' ELSE 'operacion' END);
      IF v_inv.missing_usd > 0 THEN
        PERFORM usd_alertar(v_entry.account_id, v_entry.operation_id, 'Inventario Clasica/Tropical insuficiente',
          format('La operacion de %s no se cubrio por completo con el inventario %s: faltan %s USD (saldo agotado). '
                 'Esa parte se costea a la tasa global. Revise las tarjetas y lotes en Inventario.',
                 coalesce(v_entry.customer_name, 'un cliente'), v_entry.service, to_char(v_inv.missing_usd, 'FM999G999G999G990')));
      END IF;
      v_invertido := (coalesce(v_inv.invested_usdt, 0) + v_inv.missing_usd) * v_buy;
    EXCEPTION WHEN OTHERS THEN
      PERFORM usd_alertar(v_entry.account_id, v_entry.operation_id, 'Error en el inventario Clasica/Tropical',
        format('No se pudo descontar el inventario %s de la linea resuelta de %s (%s). Quedo con el costo global; revise el inventario.',
               v_entry.service, coalesce(v_entry.customer_name, 'un cliente'), left(SQLERRM, 200)));
    END;
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
$function$;
