-- ROLLBACK of 242_recarga_tier_cost.sql: restores crm_set_calculator_rates (223 body), calculator_feed_operation (240 body) and the 3-argument
-- crm_corregir_tasas_entrada_calculadora (238 body, with its 238 grants), and drops the 4-argument one. The column recarga_costo_usdt_500 is
-- DROPPED: its values are lost (entries keep their cost_gyd snapshot and figures). Do not run after rates carrying it were relied upon
-- without re-entering them. No BEGIN/COMMIT.

CREATE OR REPLACE FUNCTION public.crm_set_calculator_rates(p_account_id uuid, p_rates jsonb, p_expected_version_id uuid DEFAULT NULL::uuid)
 RETURNS calculator_rate_versions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_current  calculator_rate_versions;
  v_new      calculator_rate_versions;
  v_key      text;
  v_value    numeric;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'admin') THEN
    RAISE EXCEPTION 'not authorized to set calculator rates' USING ERRCODE = '42501';
  END IF;

  IF p_rates IS NULL OR jsonb_typeof(p_rates) <> 'object' OR p_rates = '{}'::jsonb THEN
    RAISE EXCEPTION 'no rates provided' USING ERRCODE = '22023';
  END IF;

  FOR v_key IN SELECT jsonb_object_keys(p_rates) LOOP
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd',
                     'recarga_costo_usdt', 'saldo_costo_usdt', 'zelle_sell_gyd', 'zelle_sell_gyd_1000', 'zelle_sell_gyd_2000') THEN
      RAISE EXCEPTION 'unknown rate: %', v_key USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(p_rates -> v_key) NOT IN ('number', 'null') THEN
      RAISE EXCEPTION 'rate % must be a number or null', v_key USING ERRCODE = '22023';
    END IF;

    v_value := (p_rates ->> v_key)::numeric;
    IF v_value IS NOT NULL AND (v_value <= 0 OR v_value >= 1e9) THEN
      RAISE EXCEPTION 'rate % must be greater than 0 and less than 1e9', v_key
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Lock the account's rate history so two concurrent admins cannot both
  -- read the same "current" and both append on top of it.
  PERFORM 1 FROM accounts WHERE id = p_account_id FOR UPDATE;

  v_current := calculator_rates_vigentes(p_account_id);

  IF p_expected_version_id IS NOT NULL
     AND p_expected_version_id IS DISTINCT FROM v_current.id THEN
    RAISE EXCEPTION 'calculator rates changed concurrently, reload and retry'
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO calculator_rate_versions (
    account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, efectivo_usd_gyd,
    recarga_costo_usdt, saldo_costo_usdt, zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000, set_by
  ) VALUES (
    p_account_id,
    CASE WHEN p_rates ? 'cup_global_rate'
         THEN (p_rates ->> 'cup_global_rate')::numeric ELSE v_current.cup_global_rate END,
    CASE WHEN p_rates ? 'usdt_buy_gyd'
         THEN (p_rates ->> 'usdt_buy_gyd')::numeric ELSE v_current.usdt_buy_gyd END,
    CASE WHEN p_rates ? 'usdt_sell_gyd'
         THEN (p_rates ->> 'usdt_sell_gyd')::numeric ELSE v_current.usdt_sell_gyd END,
    CASE WHEN p_rates ? 'usdt_sell_cup'
         THEN (p_rates ->> 'usdt_sell_cup')::numeric ELSE v_current.usdt_sell_cup END,
    CASE WHEN p_rates ? 'efectivo_usd_gyd'
         THEN (p_rates ->> 'efectivo_usd_gyd')::numeric ELSE v_current.efectivo_usd_gyd END,
    -- (198) The cost of one recharge in USDT.
    CASE WHEN p_rates ? 'recarga_costo_usdt'
         THEN (p_rates ->> 'recarga_costo_usdt')::numeric ELSE v_current.recarga_costo_usdt END,
    -- (223) The cost of one package of mobile balance in USDT.
    CASE WHEN p_rates ? 'saldo_costo_usdt'
         THEN (p_rates ->> 'saldo_costo_usdt')::numeric ELSE v_current.saldo_costo_usdt END,
    -- (216) The Zelle sale price of each tier.
    CASE WHEN p_rates ? 'zelle_sell_gyd'
         THEN (p_rates ->> 'zelle_sell_gyd')::numeric ELSE v_current.zelle_sell_gyd END,
    CASE WHEN p_rates ? 'zelle_sell_gyd_1000'
         THEN (p_rates ->> 'zelle_sell_gyd_1000')::numeric ELSE v_current.zelle_sell_gyd_1000 END,
    CASE WHEN p_rates ? 'zelle_sell_gyd_2000'
         THEN (p_rates ->> 'zelle_sell_gyd_2000')::numeric ELSE v_current.zelle_sell_gyd_2000 END,
    auth.uid()
  )
  RETURNING * INTO v_new;

  RETURN v_new;
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
  v_zrate     numeric;
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
  v_cup_rate  numeric;   -- (240) CUP chat line: the rate the consumed lots cost, combined with the global rate for any shortfall
  v_cup_done  boolean;   -- (240) CUP was taken from the inventory for this part and still has to be linked to its entry
  v_inv       record;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND OR v_op.status <> 'completed' THEN
    RETURN NULL;
  END IF;

  IF v_op.quoted_source_amount IS NULL OR v_op.quoted_source_amount <= 0 THEN
    RETURN NULL;
  END IF;

  v_rates := calculator_rates_vigentes(v_op.account_id);
  -- (215) The Zelle sale rate is the tier of the deposit's TOTAL (also for a part of a split deposit).
  SELECT z.tasa INTO v_zrate FROM cerebro_zelle_cotizar_op(v_op.id, v_op.quoted_source_amount) z;

  SELECT c.name INTO v_customer
    FROM conversations conv JOIN contacts c ON c.id = conv.contact_id
   WHERE conv.id = v_op.conversation_id;

  FOR v_part IN SELECT * FROM calculator_operation_parts(v_op, v_rates) LOOP
    v_basis     := v_part.basis;
    v_amount    := NULL;
    v_facturado := NULL;
    v_invertido := NULL;
    v_cup_rate  := NULL;
    v_cup_done  := false;
    v_missing   := calculator_missing_rates(v_part.service, v_rates) || coalesce(v_part.missing, ARRAY[]::text[]);
    -- (199) a recharge whose deposit matches no recharge price cannot be priced
    IF v_part.service = 'RECARGA' AND cerebro_recarga_precio(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['recargaPrecioGyd'];
    END IF;
    -- (223) a mobile balance whose deposit is not a whole number of packages cannot be priced: no silent rounding
    IF v_part.service = 'SALDO_MOVIL' AND cerebro_saldo_paquetes(v_basis) IS NULL THEN
      v_missing := v_missing || ARRAY['saldoPaquetes'];
    END IF;
    -- (209) a combo whose cost the admin has not entered yet stays pending
    IF v_part.service = 'COMBO' AND v_op.combo_costo_gyd IS NULL THEN
      v_missing := v_missing || ARRAY['comboCosto'];
    END IF;
    v_currency  := CASE WHEN v_part.service = 'CUP' THEN 'CUP' WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN 'REC'
                        WHEN v_part.service IN ('COMBO', 'VISA') THEN 'GYD' ELSE 'USD' END;
    -- (193) The sale rate of the line: a cash dollar sells at efectivo_usd_gyd; every other USD service at
    -- usdt_sell_gyd. The cost (usdt_buy_gyd) is shared. Snapshotted in usdt_sell_gyd (= the sale rate used).
    v_sell      := CASE WHEN v_part.service = 'EFECTIVO' THEN v_rates.efectivo_usd_gyd
                        -- (199) a recharge sells at the price its deposit pays (198 cerebro_recarga_precio)
                        WHEN v_part.service = 'RECARGA' THEN cerebro_recarga_precio(v_basis)
                        -- (223) a mobile balance sells at the package price (cerebro_saldo_precio)
                        WHEN v_part.service = 'SALDO_MOVIL' THEN cerebro_saldo_precio()
                        -- (215) Zelle: tiered (still pending while the calculator has no sell rate); Clasica, Tropical and the rest keep usdt_sell_gyd
                        WHEN v_part.service = 'ZELLE' AND v_rates.usdt_sell_gyd IS NOT NULL THEN coalesce(v_zrate, v_rates.usdt_sell_gyd)
                        ELSE v_rates.usdt_sell_gyd END;

    IF v_part.service = 'COMBO' THEN
      -- (209) facturado = the verified deposit (GYD), invertido = the cost entered on the operation.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := v_op.combo_costo_gyd;
      END IF;
    ELSIF v_part.service = 'VISA' THEN
      -- (213) facturado = the verified deposit (GYD), invertido = 0 (owner: all of it is profit). No rate, never pending.
      IF v_basis IS NOT NULL AND v_basis > 0 AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
        v_amount    := v_basis;
        v_facturado := v_basis;
        v_invertido := 0;
      END IF;
    ELSIF v_basis IS NOT NULL AND coalesce(array_length(v_missing, 1), 0) = 0 THEN
      v_amount    := calculator_amount_from_basis(v_part.service, v_basis, v_rates.cup_global_rate, v_sell);
      v_facturado := calculator_facturado(v_part.service, v_amount, v_rates.cup_global_rate, v_sell);
      -- (235) facturado is the money that came in for this line (its GYD share of the operation: v_basis), not delivered units x price.
      -- The rounding leftover of a dollar rail (deposit - floor(deposit / price) x price, always below one price unit) is therefore
      -- billed and, since invertido (what the delivery costs) is untouched, lands in retorno. Where facturado already was the deposit
      -- (CUP, recarga, saldo: amount x price = basis exactly) nothing changes. A line still pending keeps NULL.
      IF v_facturado IS NOT NULL THEN
        v_facturado := v_basis;
      END IF;
      v_invertido := CASE WHEN v_part.service = 'RECARGA'
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line)
                          THEN v_amount * v_rates.recarga_costo_usdt * v_rates.usdt_buy_gyd
                          -- (223) packages x USDT cost per package x USDT buy rate
                          WHEN v_part.service = 'SALDO_MOVIL' THEN v_amount * v_rates.saldo_costo_usdt * v_rates.usdt_buy_gyd
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

    -- (223) The amount of a mobile balance line is the saldo itself (packages x saldo per package) in 'SM'; without an exact
    -- package count there is no saldo to show, so the raw deposit stays, labelled GYD (never SM). facturado/invertido
    -- above were already computed from the package count.
    IF v_part.service = 'SALDO_MOVIL' THEN
      IF cerebro_saldo_paquetes(v_basis) IS NOT NULL THEN
        v_amount   := cerebro_saldo_paquetes(v_basis) * cerebro_saldo_unidad();
        v_currency := 'SM';
      ELSE
        v_currency := 'GYD';
      END IF;
    END IF;

    -- (209) The cost of a combo is entered by hand and can change. Completed lines are append-only (149), so a live COMBO
    -- line whose figures differ is VOIDED here (figures untouched) and the upsert below revives that row with the new
    -- ones, the way a reverted-then-completed operation is re-fed. Identical figures: nothing is touched (idempotent).
    IF v_part.service = 'COMBO' THEN
      UPDATE remittance_calculator_entries e
         SET status = 'void', voided_at = clock_timestamp(), void_reason = 'combo cost or deposit changed; re-fed'
       WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
         AND e.service = 'COMBO' AND e.status <> 'void'
         AND (e.status IS DISTINCT FROM CASE WHEN coalesce(array_length(v_missing, 1), 0) = 0 THEN 'completed' ELSE 'verified_pending' END
              OR e.amount IS DISTINCT FROM v_amount OR e.facturado_gyd IS DISTINCT FROM v_facturado
              OR e.invertido_gyd IS DISTINCT FROM v_invertido OR e.basis_gyd IS DISTINCT FROM v_basis);
    END IF;

    -- (240) CUP inventory. A CUP chat line that is about to be WRITTEN (no live or deliberately deleted row exists for this
    -- operation: a fresh insert or the revival of a void row) and is fully priced takes its CUP from the owner's sending cards
    -- (cup_consumir: cards by priority, lots FIFO, daily limit per Cuba day, split across cards). The line's cup_rate becomes
    -- amount / (consumed / lot-rate + shortfall / global usdt_sell_cup), so invertido = amount / cup_rate * usdt_buy_gyd is
    -- exactly what that CUP cost. Consumption happens BEFORE the insert so no completed row is ever updated (149 guard untouched)
    -- and is linked to the entry right after it. A re-feed of a live line never gets here (no double consumption). Any failure
    -- of the inventory part is caught HERE (its own subtransaction rolls back what it did): the line keeps the global rate and a
    -- notification is raised, so the feed (and the delivery behind it) is never aborted and an inventory failure is never silent.
    IF v_part.service = 'CUP' AND coalesce(array_length(v_missing, 1), 0) = 0 AND v_facturado IS NOT NULL AND v_amount > 0
       AND NOT EXISTS (SELECT 1 FROM remittance_calculator_entries e
                        WHERE e.account_id = v_op.account_id AND e.operation_id = v_op.id AND e.source = 'completed_operation'
                          AND e.service = 'CUP' AND (e.status <> 'void' OR e.deleted_at IS NOT NULL))
    THEN
      v_cup_done := true;
      BEGIN
        SELECT * INTO v_inv
          FROM cup_consumir(v_op.account_id, v_amount, NULL, v_op.id, coalesce(v_op.completed_at, clock_timestamp()),
                            cup_cuba_day(coalesce(v_op.completed_at, clock_timestamp())));
        IF v_inv.missing_cup > 0 THEN
          PERFORM cup_alertar(v_op.account_id, v_op.id, 'Inventario CUP insuficiente',
            format('La operacion de %s no se cubrio por completo con el inventario CUP: faltan %s CUP (limite diario o saldo agotado). '
                   'Esa parte usa la tasa global. Revise las tarjetas y lotes en Inventario CUP.',
                   coalesce(v_customer, 'un cliente'), to_char(v_inv.missing_cup, 'FM999G999G999G990')));
        END IF;
        IF v_inv.consumed_cup > 0 THEN
          v_cup_rate  := v_amount / (v_inv.consumed_cup / v_inv.effective_rate + v_inv.missing_cup / v_rates.usdt_sell_cup);
          v_invertido := calculator_invertido('CUP', v_amount, v_cup_rate, v_rates.usdt_buy_gyd);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_cup_rate := NULL;
        v_cup_done := false;
        PERFORM cup_alertar(v_op.account_id, v_op.id, 'Error en el inventario CUP',
          format('No se pudo descontar el inventario CUP de la operacion de %s (%s). La linea quedo con la tasa global; revise el inventario.',
                 coalesce(v_customer, 'un cliente'), left(SQLERRM, 200)));
      END;
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
      -- (209) A COMBO line snapshots no rate (it does not depend on them). (213) Nor does a VISA line.
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.cup_global_rate END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL
           WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_rates.usdt_buy_gyd
           -- (240) a CUP line taken from the inventory snapshots the combined lot rate
           WHEN v_part.service = 'CUP' AND v_cup_rate IS NOT NULL THEN v_cup_rate ELSE v_rates.usdt_sell_cup END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_rates.usdt_buy_gyd END,
      CASE WHEN v_part.service IN ('COMBO', 'VISA') THEN NULL ELSE v_sell END, v_rates.id,
      v_facturado, v_invertido,
      CASE WHEN v_facturado IS NULL THEN NULL ELSE v_facturado - v_invertido END,
      nullif(v_missing, ARRAY[]::text[]), v_op.delivery_mode, v_op.delivered_by,
      coalesce(v_op.completed_at, clock_timestamp()),
      CASE WHEN v_part.service = 'RECARGA' THEN v_rates.recarga_costo_usdt
           WHEN v_part.service = 'SALDO_MOVIL' THEN v_rates.saldo_costo_usdt
           WHEN v_part.service = 'COMBO' THEN v_op.combo_costo_gyd
           WHEN v_part.service = 'VISA' THEN 0 END,
      CASE WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_sell
           WHEN v_part.service IN ('COMBO', 'VISA') THEN v_facturado END
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
    -- (226) a row the admin deleted on purpose (deleted_at) is never revived: only a reverted operation's void row is
    WHERE remittance_calculator_entries.status = 'void'
      AND remittance_calculator_entries.deleted_at IS NULL
    RETURNING id INTO v_entry_id;

    -- (240) link the CUP taken above to the line it priced (or give it back if, against expectation, no row was written)
    IF v_cup_done THEN
      IF v_entry_id IS NOT NULL THEN
        UPDATE cup_lot_consumptions SET calculator_entry_id = v_entry_id
         WHERE account_id = v_op.account_id AND operation_id = v_op.id AND calculator_entry_id IS NULL;
      ELSE
        PERFORM cup_devolver(NULL, v_op.id);
      END IF;
    END IF;

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.crm_corregir_tasas_entrada_calculadora(uuid, numeric, numeric, numeric);

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

ALTER TABLE public.calculator_rate_versions DROP COLUMN IF EXISTS recarga_costo_usdt_500;
