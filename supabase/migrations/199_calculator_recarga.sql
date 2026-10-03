-- =====================================================================
-- 199 — Completed recharges reach the calculator as RECARGA (staging first)
--
-- odd/tasks/panel-other-services.md (R1). The calculator guide prices a recharge "• Josefa 1 rec promo
-- (23.1/6.2k/242)": units, USDT cost per recharge, GYD sale price, GYD per USDT. A completed service_type 'recarga'
-- operation now feeds the same line:
--   - calculator_resolve_operation_service: a recharge is RECARGA (even with no number yet);
--     calculator_service_for_operation maps a 'recarga' beneficiary row to RECARGA;
--   - calculator_missing_rates: RECARGA needs recargaCostoUsdt and usdtBuyGyd; the feed adds recargaPrecioGyd when the
--     deposit matches no recharge price (198 cerebro_recarga_precio) — the line is then pending;
--   - calculator_feed_operation: units = deposit / price (cerebro_recarga_precio), facturado = units x price, invertido =
--     units x recarga_costo_usdt x usdt_buy_gyd, amount currency 'REC'; snapshot cup_rate = usdt_buy_gyd, cost_gyd =
--     USDT cost, sale_gyd = price (what a manual RECARGA line stores). Every other service is priced as before.
--
-- Guarded by supabase/staging/assertions/calculator-recarga.sql.
-- ROLLBACK: ROLLBACK-199-calculator-recarga.sql
-- =====================================================================
CREATE OR REPLACE FUNCTION public.calculator_service_for_operation(p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE lower(coalesce(p_delivery_method, ''))
           WHEN 'cuban_card'            THEN 'CUP'
           WHEN 'multiple_distribution' THEN 'CUP'
           WHEN 'zelle'                 THEN 'ZELLE'
           WHEN 'clasica'               THEN 'CLASICA'
           WHEN 'tropical'              THEN 'TROPICAL'
           -- (193) Cash dollars delivered in Cuba: their own service, priced at the cash sale rate.
           WHEN 'efectivo_usd'          THEN 'EFECTIVO'
           -- (199) A beneficiary row of a recharge (one Cuban number per recharge).
           WHEN 'recarga'               THEN 'RECARGA'
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_resolve_operation_service(p_operation_id uuid, p_delivery_method text)
 RETURNS text
 LANGUAGE sql
 STABLE
AS $function$
  SELECT CASE
           -- (199) A recharge is priced as RECARGA whatever its rows say (even with no number yet).
           WHEN (SELECT o.service_type FROM remittance_operations o WHERE o.id = p_operation_id) = 'recarga' THEN 'RECARGA'
           WHEN NOT EXISTS (
             SELECT 1 FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) THEN calculator_service_for_operation(p_delivery_method)
           WHEN (
             SELECT count(DISTINCT b.beneficiary_type)
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
           ) = 1 THEN calculator_service_for_operation((
             SELECT b.beneficiary_type
               FROM remittance_beneficiaries b
              WHERE b.operation_id = p_operation_id AND b.status = 'vigente'
              LIMIT 1
           ))
           ELSE NULL
         END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_missing_rates(p_service text, p_rates calculator_rate_versions)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT CASE p_service
    WHEN 'CUP' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.cup_global_rate IS NULL THEN 'cupGlobalRate' END,
        CASE WHEN p_rates.usdt_sell_cup   IS NULL THEN 'usdtSellCup'   END,
        CASE WHEN p_rates.usdt_buy_gyd    IS NULL THEN 'usdtBuyGyd'    END
      ], NULL)
    -- (199) A recharge: its USDT cost and the USDT buy rate (its price comes from the deposit, see the feed).
    WHEN 'RECARGA' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.recarga_costo_usdt IS NULL THEN 'recargaCostoUsdt' END,
        CASE WHEN p_rates.usdt_buy_gyd       IS NULL THEN 'usdtBuyGyd'       END
      ], NULL)
    -- (193) Cash: the shared buy rate and the cash sale rate (efectivo_usd_gyd), not the Zelle sale rate.
    WHEN 'EFECTIVO' THEN
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd     IS NULL THEN 'usdtBuyGyd'     END,
        CASE WHEN p_rates.efectivo_usd_gyd IS NULL THEN 'efectivoUsdGyd' END
      ], NULL)
    ELSE
      array_remove(ARRAY[
        CASE WHEN p_rates.usdt_buy_gyd  IS NULL THEN 'usdtBuyGyd'  END,
        CASE WHEN p_rates.usdt_sell_gyd IS NULL THEN 'usdtSellGyd' END
      ], NULL)
  END;
$function$;

CREATE OR REPLACE FUNCTION public.calculator_feed_operation(p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op        remittance_operations;
  v_rates     calculator_rate_versions;
  v_sell      numeric;
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
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service = 'RECARGA' THEN 'REC' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_sell);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_sell);
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line)
                          THEN v_amount * v_rates.recarga_costo_usdt * v_rates.usdt_buy_gyd
                          ELSE calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd) END;
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
      missing_inputs, delivery_mode, actor_user_id, completed_at, cost_gyd, sale_gyd
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      -- (199) A RECARGA line reads like a manual "rec promo" one: cup_rate = USDT rate, cost_gyd = USDT cost, sale_gyd = price.
      v_rates.cup_global_rate,
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
      v_rates.usdt_buy_gyd, v_sell, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt END,
      CASE WHEN v_part.service = 'RECARGA' THEN v_sell END
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
      cost_gyd        = EXCLUDED.cost_gyd,
      sale_gyd        = EXCLUDED.sale_gyd,
      voided_at       = NULL,
      void_reason     = NULL
    WHERE remittance_calculator_entries.status = 'void'
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;
