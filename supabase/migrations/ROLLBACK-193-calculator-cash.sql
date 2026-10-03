-- ROLLBACK of 193_calculator_cash.sql. Fails on purpose while EFECTIVO entries exist (the CHECK below rejects them):
-- they are real ledger lines, so they are voided or reviewed by hand first.
ALTER TABLE remittance_calculator_entries DROP CONSTRAINT remittance_calculator_entries_service_chk;
ALTER TABLE remittance_calculator_entries ADD CONSTRAINT remittance_calculator_entries_service_chk
  CHECK (service = ANY (ARRAY['CUP', 'ZELLE', 'MLC', 'CLASICA', 'TROPICAL', 'USDT', 'RECARGA', 'SALDO_MOVIL', 'DIRECTO']));

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
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' ELSE 'USD' END;

    IF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_rates.usdt_sell_gyd);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_rates.usdt_sell_gyd);
      v_invertido := calculator_invertido(v_part.service, v_amount, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd);
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
      missing_inputs, delivery_mode, actor_user_id, completed_at
    ) VALUES (
      v_op.account_id, 'completed_operation',
      CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END,
      v_op.id, coalesce(v_op.completed_at, clock_timestamp())::date, v_customer,
      v_part.service, v_amount, v_currency, v_basis,
      v_rates.cup_global_rate, v_rates.usdt_sell_cup, v_rates.usdt_buy_gyd, v_rates.usdt_sell_gyd, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp())
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
      voided_at       = NULL,
      void_reason     = NULL
    WHERE remittance_calculator_entries.status = 'void'
    RETURNING id INTO v_entry_id;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

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

  IF p_reason IS NULL OR length(btrim(p_reason)) < 5 THEN
    RAISE EXCEPTION 'a reason of at least 5 characters is required' USING ERRCODE = '22023';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup') THEN
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

  -- coalesce, not overwrite: what the entry already recorded wins.
  v_cup_glob := coalesce(v_entry.cup_global_rate, (p_rates ->> 'cup_global_rate')::numeric);
  v_cup_rate := coalesce(v_entry.cup_rate,        (p_rates ->> 'usdt_sell_cup')::numeric);
  v_buy      := coalesce(v_entry.usdt_buy_gyd,    (p_rates ->> 'usdt_buy_gyd')::numeric);
  v_sell     := coalesce(v_entry.usdt_sell_gyd,   (p_rates ->> 'usdt_sell_gyd')::numeric);

  IF v_entry.service = 'CUP' THEN
    v_missing := array_remove(ARRAY[
      CASE WHEN v_cup_glob IS NULL THEN 'cupGlobalRate' END,
      CASE WHEN v_cup_rate IS NULL THEN 'usdtSellCup'   END,
      CASE WHEN v_buy      IS NULL THEN 'usdtBuyGyd'    END
    ], NULL);
  ELSE
    v_missing := array_remove(ARRAY[
      CASE WHEN v_buy  IS NULL THEN 'usdtBuyGyd'  END,
      CASE WHEN v_sell IS NULL THEN 'usdtSellGyd' END
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
  v_invertido := calculator_invertido(v_entry.service, v_amount, v_cup_rate, v_buy);

  IF v_amount IS NULL OR v_facturado IS NULL OR v_invertido IS NULL THEN
    RAISE EXCEPTION 'the operation has no usable deposit amount to price' USING ERRCODE = '22023';
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
