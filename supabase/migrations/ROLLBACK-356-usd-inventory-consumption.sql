-- ROLLBACK of 356_usd_inventory_consumption.sql: restores the exact previous (live staging 2026-11-06) bodies of calculator_feed_operation,
-- remittance_operations_calculator_feed, crm_eliminar_entrada_calculadora, crm_registrar_entradas_manuales, crm_entregar_operacion and
-- crm_cerrar_operacion_manual (same signatures; CREATE OR REPLACE keeps their ACLs) and drops the 9 functions 356 created.
-- Consumptions already written stay in usd_lot_consumptions. No BEGIN/COMMIT.

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
  v_rcost     numeric;   -- (242) USDT cost of ONE recharge of this line, by its promotion tier
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

    -- (242) A recharge is costed by the promotion tier of its price: the precio_recarga row the price belongs to (min_cup 500 = "starts
    -- at 500 CUP", 5,200 GYD; min_cup 600 = 6,200 GYD). The 500 tier takes recarga_costo_usdt_500; every other tier (600 and any
    -- future one) and a 500 tier whose rate is not set yet keep recarga_costo_usdt, i.e. the behaviour before 242.
    v_rcost := v_rates.recarga_costo_usdt;
    IF v_part.service = 'RECARGA' AND v_rates.recarga_costo_usdt_500 IS NOT NULL
       AND (SELECT min(r.min_cup) FROM precio_recarga r WHERE r.precio_gyd = v_sell) = 500 THEN
      v_rcost := v_rates.recarga_costo_usdt_500;
    END IF;

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
                          -- (199) units x USDT cost per recharge x USDT buy rate (the guide's "rec promo" line); (242) cost by tier
                          THEN v_amount * v_rcost * v_rates.usdt_buy_gyd
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
                            cup_cuba_day(coalesce(v_op.completed_at, clock_timestamp())),
                            -- (257) the sending card the operator chose when completing the operation (NULL = by priority)
                            v_op.cup_source_card_id);
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
      CASE WHEN v_part.service = 'RECARGA' THEN v_rcost
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

CREATE OR REPLACE FUNCTION public.remittance_operations_calculator_feed()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_reason text;
  v_cup_ids uuid[];
  v_cup_id  uuid;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  BEGIN
    IF NEW.status = 'completed' THEN
      PERFORM calculator_feed_operation(NEW.id);

    ELSIF OLD.status = 'completed' THEN
      v_reason := format('operation reverted from completed to %s', NEW.status);
      WITH voided AS (
        UPDATE remittance_calculator_entries
           SET status      = 'void',
               voided_at   = clock_timestamp(),
               void_reason = v_reason
         WHERE account_id = NEW.account_id
           AND operation_id = NEW.id
           AND source = 'completed_operation'
           AND status <> 'void'
        RETURNING id, service
      )
      SELECT coalesce(array_agg(id) FILTER (WHERE service = 'CUP'), ARRAY[]::uuid[]) INTO v_cup_ids FROM voided;

      -- (240) the CUP a voided line took goes back to its lots. Each return has its own subtransaction: a failure is an
      -- alert, it never rolls back the void nor the status change (the outer handler would).
      FOREACH v_cup_id IN ARRAY v_cup_ids LOOP
        BEGIN
          PERFORM cup_devolver(v_cup_id);
        EXCEPTION WHEN OTHERS THEN
          PERFORM cup_alertar(NEW.account_id, NEW.id, 'Error en el inventario CUP',
            format('No se pudo devolver al inventario CUP el monto de una operacion revertida (%s). Revise el inventario.', left(SQLERRM, 200)));
        END;
      END LOOP;
    END IF;

  EXCEPTION WHEN OTHERS THEN
    -- A ledger problem must never cost the operator the delivery they just
    -- made. Record what broke and let the status change commit.
    BEGIN
      INSERT INTO remittance_admin_audit (account_id, table_name, row_id, action, actor, reason, before, after)
      VALUES (NEW.account_id, 'remittance_calculator_entries', NEW.id, 'calculator_feed_failed',
              wacrm_current_actor(), left(SQLERRM, 500),
              jsonb_build_object('status', OLD.status),
              jsonb_build_object('status', NEW.status, 'sqlstate', SQLSTATE));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'calculator feed failed and could not be audited for operation %: %', NEW.id, SQLERRM;
    END;
  END;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_eliminar_entrada_calculadora(p_entry_id uuid)
 RETURNS remittance_calculator_entries
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_entry  remittance_calculator_entries;
  v_before jsonb;
  v_actor  text;
BEGIN
  SELECT * INTO v_entry FROM remittance_calculator_entries WHERE id = p_entry_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'ledger entry not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_entry.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to delete calculator entries' USING ERRCODE = '42501';
  END IF;

  -- (228) a chat-fed entry or a manual one (both are rows of the Calculator's table).
  IF v_entry.source NOT IN ('completed_operation', 'manual') THEN
    RAISE EXCEPTION 'only a chat-fed or a manual entry can be deleted here' USING ERRCODE = '22023';
  END IF;

  IF v_entry.status NOT IN ('completed', 'verified_pending') THEN
    RAISE EXCEPTION 'entry is % and cannot be deleted', v_entry.status USING ERRCODE = '22023';
  END IF;

  v_before := to_jsonb(v_entry);
  v_actor  := wacrm_current_actor();

  -- Open the append-only guard's narrow hole for exactly this UPDATE (a manual row has no other way to be voided).
  PERFORM set_config('wacrm.calculator_manual_delete', 'true', true);

  -- completed -> void keeps every figure (the append-only guard checks it); the deletion marker is not a figure.
  UPDATE remittance_calculator_entries
     SET status      = 'void',
         voided_at   = clock_timestamp(),
         void_reason = 'deleted by ' || coalesce(v_actor, 'unknown'),
         deleted_at  = clock_timestamp(),
         deleted_by  = auth.uid()
   WHERE id = p_entry_id
  RETURNING * INTO v_entry;

  PERFORM set_config('wacrm.calculator_manual_delete', '', true);

  -- (240) A deleted CUP line (chat or manual) gives its CUP back to the lots. Not swallowed: if the return fails the deletion fails
  -- with it, so the ledger and the inventory never disagree silently.
  IF v_entry.service = 'CUP' THEN
    PERFORM cup_devolver(v_entry.id);
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'status,deleted_at',
          'human_calculator_entry_deleted', v_actor, v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_registrar_entradas_manuales(p_account_id uuid, p_lineas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  c_services constant text[] := ARRAY['CUP', 'ZELLE', 'MLC', 'TROPICAL', 'CLASICA', 'USDT', 'SALDO_MOVIL', 'RECARGA', 'DIRECTO'];
  v_today   date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_line    jsonb;
  v_n       integer := 0;
  v_date    date;
  v_entry   remittance_calculator_entries;
  v_out     jsonb := '[]'::jsonb;
  v_inv     record;
BEGIN
  IF p_account_id IS NULL THEN
    RAISE EXCEPTION 'account_id is required' USING ERRCODE = '22023';
  END IF;

  IF NOT is_account_member(p_account_id, 'agent') THEN
    RAISE EXCEPTION 'not authorized to add calculator entries' USING ERRCODE = '42501';
  END IF;

  IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' THEN
    RAISE EXCEPTION 'lines must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_lineas) = 0 THEN
    RAISE EXCEPTION 'at least one line is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_lineas) > 500 THEN
    RAISE EXCEPTION 'too many lines (500 at most)' USING ERRCODE = '22023';
  END IF;

  -- Validate EVERYTHING first: a refused payload writes nothing (the transaction would also undo a half insert).
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lineas) LOOP
    v_n := v_n + 1;
    IF jsonb_typeof(v_line) <> 'object' THEN
      RAISE EXCEPTION 'line %: must be an object', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'customer') IS DISTINCT FROM 'string' OR char_length(btrim(v_line ->> 'customer')) NOT BETWEEN 1 AND 240 THEN
      RAISE EXCEPTION 'line %: customer is required (1 to 240 characters)', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'service') IS DISTINCT FROM 'string' OR NOT (v_line ->> 'service') = ANY (c_services) THEN
      RAISE EXCEPTION 'line %: unknown service', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'currency') IS DISTINCT FROM 'string' OR char_length(v_line ->> 'currency') NOT BETWEEN 1 AND 12 THEN
      RAISE EXCEPTION 'line %: currency is required (1 to 12 characters)', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'amount') IS DISTINCT FROM 'number' OR (v_line ->> 'amount')::numeric <= 0 OR (v_line ->> 'amount')::numeric >= 1e15 THEN
      RAISE EXCEPTION 'line %: amount must be a number above zero', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'facturado_gyd') IS DISTINCT FROM 'number' OR (v_line ->> 'facturado_gyd')::numeric < 0 OR (v_line ->> 'facturado_gyd')::numeric >= 1e15
       OR jsonb_typeof(v_line -> 'invertido_gyd') IS DISTINCT FROM 'number' OR (v_line ->> 'invertido_gyd')::numeric < 0 OR (v_line ->> 'invertido_gyd')::numeric >= 1e15
       OR jsonb_typeof(v_line -> 'retorno_gyd') IS DISTINCT FROM 'number' OR abs((v_line ->> 'retorno_gyd')::numeric) >= 1e15 THEN
      RAISE EXCEPTION 'line %: facturado and invertido must be numbers of zero or more, retorno a number', v_n USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(v_line -> 'date') IS DISTINCT FROM 'string' OR (v_line ->> 'date') !~ '^\d{4}-\d{2}-\d{2}$' THEN
      RAISE EXCEPTION 'line %: date must be YYYY-MM-DD', v_n USING ERRCODE = '22023';
    END IF;
    BEGIN
      v_date := (v_line ->> 'date')::date;
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'line %: date is not a valid day', v_n USING ERRCODE = '22023';
    END;
    IF v_date > v_today + 1 OR v_date < v_today - 60 THEN
      RAISE EXCEPTION 'line %: date out of range', v_n USING ERRCODE = '22023';
    END IF;
    IF v_line ? 'day_label' AND jsonb_typeof(v_line -> 'day_label') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'line %: day_label must be text', v_n USING ERRCODE = '22023';
    END IF;
    IF v_line ? 'raw_line' AND jsonb_typeof(v_line -> 'raw_line') NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'line %: raw_line must be text', v_n USING ERRCODE = '22023';
    END IF;
  END LOOP;

  PERFORM pg_advisory_xact_lock(hashtextextended('calculator-cut:' || p_account_id::text, 0));

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lineas) LOOP
    v_date := (v_line ->> 'date')::date;

    INSERT INTO remittance_calculator_entries (
      account_id, source, status, operation_id, entry_date, day_label, customer_name, service, amount, amount_currency,
      facturado_gyd, invertido_gyd, retorno_gyd, actor_user_id, completed_at, created_at, raw_line
    ) VALUES (
      p_account_id, 'manual', 'completed', NULL, v_date, nullif(left(v_line ->> 'day_label', 120), ''), btrim(v_line ->> 'customer'),
      v_line ->> 'service', (v_line ->> 'amount')::numeric, v_line ->> 'currency',
      (v_line ->> 'facturado_gyd')::numeric, (v_line ->> 'invertido_gyd')::numeric, (v_line ->> 'retorno_gyd')::numeric,
      auth.uid(),
      -- midday of the line's Guyana day, so the close files it on that day whatever the viewer's zone
      (v_date + time '12:00') AT TIME ZONE 'America/Guyana',
      -- strictly increasing inside the batch, so the rows keep the order they were sent in
      clock_timestamp(), nullif(left(v_line ->> 'raw_line', 1000), '')
    )
    RETURNING * INTO v_entry;

    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'created', 'human_calculator_manual_added',
            wacrm_current_actor(), NULL, to_jsonb(v_entry));

    -- (240) CUP inventory: a manual CUP line takes its CUP from the sending cards (the typed rate is NOT touched: the owner's number
    -- wins). Its Cuba day is the line's date when that is not today (Guyana), else the current Cuba day. A shortfall or a failure
    -- never rejects the registration (the money already moved): it raises a notification instead. Lock order: calculator-cut
    -- (above) then cup-inventory (inside cup_consumir); nothing takes them in the opposite order.
    IF v_entry.service = 'CUP' THEN
      BEGIN
        IF upper(btrim(v_entry.amount_currency)) = 'CUP' THEN
          SELECT * INTO v_inv
            FROM cup_consumir(p_account_id, v_entry.amount, v_entry.id, NULL, clock_timestamp(),
                              CASE WHEN v_date <> v_today THEN v_date ELSE cup_cuba_day(now()) END);
          IF v_inv.missing_cup > 0 THEN
            PERFORM cup_alertar(p_account_id, NULL, 'Inventario CUP insuficiente',
              format('La linea manual de %s (%s CUP) no se cubrio por completo con el inventario: faltan %s CUP (limite diario o saldo agotado). '
                     'Se registro igual con la tasa que usted escribio.',
                     v_entry.customer_name, to_char(v_entry.amount, 'FM999G999G999G990'), to_char(v_inv.missing_cup, 'FM999G999G999G990')));
          END IF;
        ELSE
          PERFORM cup_alertar(p_account_id, NULL, 'Linea CUP sin descontar del inventario',
            format('La linea manual de %s esta en %s, no en CUP: no se desconto del inventario CUP.', v_entry.customer_name, v_entry.amount_currency));
        END IF;
      EXCEPTION WHEN OTHERS THEN
        PERFORM cup_alertar(p_account_id, NULL, 'Error en el inventario CUP',
          format('No se pudo descontar del inventario CUP la linea manual de %s (%s). Se registro igual; revise el inventario.',
                 v_entry.customer_name, left(SQLERRM, 200)));
      END;
    END IF;

    v_out := v_out || to_jsonb(v_entry);
  END LOOP;

  RETURN v_out;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_entregar_operacion(p_operation_id uuid, p_evidence jsonb, p_notify boolean DEFAULT true, p_cup_source_card_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_deal_id       uuid;

  v_status_before text;
  v_status_after  text;
  v_completed_at  timestamptz;

  v_mode          text;
  v_wamid         text;
  v_path          text;
  v_n             int;
  v_nnull         int;
  v_sum           numeric;
  v_dest          numeric;
  v_cur           text;
  v_cur_ok        boolean;
  v_riel          text;
  v_req           numeric;
  v_dep           numeric;
  v_cov           boolean;
  v_forced        boolean := false;
BEGIN
  SELECT account_id, deal_id
    INTO v_account_id, v_deal_id
    FROM remittance_operations
   WHERE id = p_operation_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;

  IF NOT is_account_member(v_account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to deliver this operation' USING ERRCODE = '42501';
  END IF;

  IF p_evidence IS NULL OR jsonb_typeof(p_evidence) <> 'object' THEN
    RAISE EXCEPTION 'evidence must be a JSON object' USING ERRCODE = '22023';
  END IF;

  -- (257) The optional CUP sending card: one of this account's active cards, else refused before anything changes.
  PERFORM cup_validar_tarjeta_origen(v_account_id, p_cup_source_card_id);

  v_mode := p_evidence ->> 'mode';
  IF v_mode IS NULL OR v_mode NOT IN ('proof_sent', 'no_proof', 'skip_proof') THEN
    RAISE EXCEPTION 'evidence mode must be proof_sent, no_proof or skip_proof' USING ERRCODE = '22023';
  END IF;

  IF p_evidence ? 'wamid' AND (p_evidence -> 'wamid') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'wamid') <> 'string' THEN
      RAISE EXCEPTION 'evidence wamid must be a string' USING ERRCODE = '22023';
    END IF;
    v_wamid := p_evidence ->> 'wamid';
    IF v_wamid = '' OR length(v_wamid) > 500 THEN
      RAISE EXCEPTION 'evidence wamid must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  IF p_evidence ? 'path' AND (p_evidence -> 'path') IS DISTINCT FROM 'null'::jsonb THEN
    IF jsonb_typeof(p_evidence -> 'path') <> 'string' THEN
      RAISE EXCEPTION 'evidence path must be a string' USING ERRCODE = '22023';
    END IF;
    v_path := p_evidence ->> 'path';
    IF v_path = '' OR length(v_path) > 500 THEN
      RAISE EXCEPTION 'evidence path must be non-empty and at most 500 characters' USING ERRCODE = '22023';
    END IF;
  END IF;

  -- (164) The ordering lock that stood here — a `FOR UPDATE` on the legacy
  -- deal row — was removed with the legacy table. It only serialized
  -- against retired n8n notes/value writes and touched no result.

  SELECT status
    INTO v_status_before
    FROM remittance_operations
   WHERE id = p_operation_id
     FOR UPDATE;

  IF v_status_before IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'operation is not ready to transfer' USING ERRCODE = '22023';
  END IF;

  IF NOT crm_beneficiarios_completos(p_operation_id) THEN
    RAISE EXCEPTION 'beneficiary data is incomplete' USING ERRCODE = '22023';
  END IF;

  -- (331) A case in incident blocks delivery: a confirmed card-prefix conflict or an over-allocated
  -- case after a void. An operator resolves it with funding_case_resolver. The case is found through
  -- the conversation because an operation may still have case_id NULL (no allocation yet).
  IF EXISTS (SELECT 1 FROM funding_case fc
              WHERE fc.status = 'incident'
                AND fc.conversation_id = (SELECT o.conversation_id
                                            FROM remittance_operations o
                                           WHERE o.id = p_operation_id)) THEN
    RAISE EXCEPTION 'the funding case has a conflict: %',
      COALESCE((SELECT fc.note FROM funding_case fc
                 WHERE fc.status = 'incident'
                   AND fc.conversation_id = (SELECT o.conversation_id
                                               FROM remittance_operations o
                                              WHERE o.id = p_operation_id)
                 ORDER BY fc.opened_at DESC LIMIT 1), 'resolve it before delivering')
      USING ERRCODE = '22023';
  END IF;

  -- (329) No delivery with unverified money: the operation, or its mixed group as a whole, must be
  -- covered by consumed, unvoided MMG deposits. Over-funding is allowed in phase 1 and stays visible
  -- as a negative balance in cerebro_saldo_operacion.
  SELECT s.requerido, s.depositado, s.cubierto INTO v_req, v_dep, v_cov
    FROM cerebro_fondos_operacion(p_operation_id) s;
  IF coalesce(v_req, 0) <= 0 THEN
    RAISE EXCEPTION 'the operation has no source amount to fund' USING ERRCODE = '22023';
  END IF;
  -- (352) An admin's forced verification counts as verified funding (rule in the header). Evaluated only
  -- when the deposits do not already cover the scope, so a funded operation never pays for the audit lookup.
  IF NOT coalesce(v_cov, false) THEN
    v_forced := NOT EXISTS (
      SELECT 1
        FROM remittance_operations b
        JOIN remittance_operations m
          ON (b.mixed_group_id IS NOT NULL AND m.mixed_group_id = b.mixed_group_id AND m.status <> 'cancelled')
          OR (b.mixed_group_id IS NULL AND m.id = b.id)
       WHERE b.id = p_operation_id
         AND NOT EXISTS (
           SELECT 1
             FROM remittance_admin_audit a
            WHERE a.table_name = 'remittance_operations'
              AND a.row_id = m.id
              AND a.action = 'human_forced_verification'
              AND NOT EXISTS (
                SELECT 1
                  FROM remittance_admin_audit s
                 WHERE s.table_name = 'remittance_operations'
                   AND s.row_id = m.id
                   AND s.created_at > a.created_at
                   AND (s.action = 'human_deposit_verification'
                        OR s.after ->> 'status' IN ('deposit_verification', 'incident', 'cancelled')))));
  END IF;
  IF NOT coalesce(v_cov, false) AND NOT v_forced THEN
    RAISE EXCEPTION 'the operation has % GYD of verified funding but needs % GYD: verify the deposit before delivering',
      v_dep, v_req USING ERRCODE = '22023';
  END IF;

  -- (329) EVERY RAIL: the recipients' amounts must add up to what the operation sends. The gate only
  -- applies when every vigente recipient has an amount and all their currencies equal the destination
  -- currency (a null destination only accepts null currencies). Zelle compares whole dollars; the
  -- other rails compare cents. Yoandrys 2026-10-26: a 1,100 USD Zelle was delivered with 800 + 200.
  SELECT o.quoted_destination_amount, o.destination_currency
    INTO v_dest, v_cur
    FROM remittance_operations o WHERE o.id = p_operation_id;
  SELECT count(*),
         count(*) FILTER (WHERE b.amount IS NULL),
         coalesce(sum(b.amount), 0),
         coalesce(bool_and(b.currency IS NOT DISTINCT FROM v_cur), true)
    INTO v_n, v_nnull, v_sum, v_cur_ok
    FROM remittance_beneficiaries b
   WHERE b.operation_id = p_operation_id AND b.status = 'vigente';
  v_riel := cerebro_riel_op(p_operation_id);
  IF coalesce(v_dest, 0) > 0 AND v_n > 0 AND v_nnull = 0 AND v_cur_ok THEN
    IF (v_riel = 'zelle' AND round(v_sum) <> round(v_dest))
       OR (v_riel IS DISTINCT FROM 'zelle' AND round(v_sum, 2) <> round(v_dest, 2)) THEN
      RAISE EXCEPTION 'the recipients add up to % % but the operation sends % %: complete them before delivering',
        round(v_sum, 2)::text, coalesce(v_cur, ''), round(v_dest, 2)::text, coalesce(v_cur, '')
        USING ERRCODE = '22023';
    END IF;
  END IF;

  -- (143) With proof and 2+ current beneficiaries, every beneficiary needs
  -- its own proof (crm_registrar_prueba_beneficiario) before delivering.
  IF v_mode = 'proof_sent' AND crm_pruebas_faltantes(p_operation_id) > 0 THEN
    RAISE EXCEPTION 'every beneficiary needs its delivery proof before delivering (% missing)',
      crm_pruebas_faltantes(p_operation_id)
      USING ERRCODE = '22023';
  END IF;

  -- (114) One statement: status, evidence, completed_at (the latter set
  -- automatically by trg_remittance_operations_touch, 040) all land in
  -- the same NEW row image the calculator feed trigger reads.
  UPDATE remittance_operations
     SET status = 'completed',
         -- (191) The panel's notify-customer choice, in the row image the notifier reads.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END,
         delivery_mode = v_mode,
         delivery_proof_wamid = v_wamid,
         delivery_proof_path = v_path,
         delivered_by = auth.uid(),
         -- (257) In the SAME statement, so the calculator feed (AFTER UPDATE OF status) sees the chosen card.
         cup_source_card_id = p_cup_source_card_id
   WHERE id = p_operation_id
     AND status = 'ready_to_transfer'
  RETURNING status, completed_at INTO v_status_after, v_completed_at;

  IF v_status_after IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'delivery did not complete the operation' USING ERRCODE = 'P0001';
  END IF;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_delivery',
          wacrm_current_actor(),
          jsonb_build_object('status', 'ready_to_transfer'),
          jsonb_build_object('status', 'completed', 'evidence', p_evidence)
            || CASE WHEN p_cup_source_card_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('cup_source_card_id', p_cup_source_card_id) END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

CREATE OR REPLACE FUNCTION public.crm_cerrar_operacion_manual(p_operation_id uuid, p_motivo text DEFAULT NULL::text, p_notify boolean DEFAULT false, p_delivery_method text DEFAULT NULL::text, p_cup_source_card_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id    uuid;
  v_status_before text;
  v_service_before text;
  v_service_after text;
  v_completed_at  timestamptz;
  v_motivo        text := coalesce(nullif(btrim(p_motivo), ''), 'Closed manually from the panel');
BEGIN
  SELECT account_id, status, service_type INTO v_account_id, v_status_before, v_service_before
    FROM remittance_operations WHERE id = p_operation_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'only an owner or admin can close an operation manually' USING ERRCODE = '42501';
  END IF;
  -- (191) No typed reason any more: the fixed note above is audited unless one is given.
  IF length(v_motivo) > 500 THEN
    RAISE EXCEPTION 'the reason must be at most 500 characters' USING ERRCODE = '22023';
  END IF;
  -- (257) The optional CUP sending card: one of this account's active cards, else refused before anything changes.
  PERFORM cup_validar_tarjeta_origen(v_account_id, p_cup_source_card_id);
  -- (196) The service chosen in the panel when the remesa has no beneficiary, so the calculator can price it.
  IF p_delivery_method IS NOT NULL THEN
    IF p_delivery_method NOT IN ('cuban_card', 'zelle', 'clasica', 'tropical', 'efectivo_usd', 'recarga', 'combo', 'visa', 'saldo') THEN
      RAISE EXCEPTION 'unknown service: %', p_delivery_method USING ERRCODE = '22023';
    END IF;
    IF EXISTS (SELECT 1 FROM remittance_beneficiaries b WHERE b.operation_id = p_operation_id AND b.status = 'vigente') THEN
      RAISE EXCEPTION 'this remesa already has a beneficiary: its service comes from it' USING ERRCODE = '22023';
    END IF;
  END IF;
  IF v_status_before NOT IN ('ready_to_transfer', 'transferring') THEN
    RAISE EXCEPTION 'only a verified operation can be closed manually (status %)', v_status_before USING ERRCODE = '22023';
  END IF;

  -- (249) The chosen service IS the operation's service, as in _cambiar_servicio_core (222): a remesa rail makes a remesa.
  v_service_after := CASE WHEN p_delivery_method IS NULL THEN v_service_before
                          WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN p_delivery_method
                          ELSE 'remesa' END;

  -- One statement, like crm_entregar_operacion: completed_at (040) and the calculator feed read this row image.
  UPDATE remittance_operations
     SET status = 'completed', delivery_mode = 'closed_manually', delivered_by = auth.uid(),
         -- (196) In the same UPDATE, so the calculator feed (AFTER UPDATE OF status) sees the service.
         -- (200) 'recarga' is a kind of operation, not a delivery method: it sets service_type. (208) So is 'combo'. (213) And 'visa'. (223) And 'saldo'.
         delivery_method = CASE WHEN p_delivery_method IN ('recarga', 'combo', 'visa', 'saldo') THEN delivery_method ELSE coalesce(p_delivery_method, delivery_method) END,
         service_type = v_service_after,
         -- (249) A combo cost belongs to a combo only.
         combo_costo_gyd = CASE WHEN v_service_after = 'combo' THEN combo_costo_gyd END,
         -- (191) Silent by default (p_notify false); the bell on the panel can turn the notice on.
         customer_notice_muted_for = CASE WHEN p_notify THEN NULL ELSE 'completed' END,
         -- (257) In the SAME statement, so the calculator feed (AFTER UPDATE OF status) sees the chosen card.
         cup_source_card_id = p_cup_source_card_id
   WHERE id = p_operation_id
  RETURNING completed_at INTO v_completed_at;

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
  VALUES (v_account_id, 'remittance_operations', p_operation_id, 'status', 'human_manual_close', wacrm_current_actor(),
          v_motivo, jsonb_build_object('status', v_status_before),
          jsonb_build_object('status', 'completed', 'delivery_mode', 'closed_manually', 'notify', p_notify)
            || CASE WHEN p_delivery_method IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('delivery_method', p_delivery_method) END
            || CASE WHEN p_cup_source_card_id IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('cup_source_card_id', p_cup_source_card_id) END
            -- (249) A change of service is visible in the audit row.
            || CASE WHEN v_service_after IS DISTINCT FROM v_service_before
                    THEN jsonb_build_object('service_type', v_service_after, 'service_type_before', v_service_before)
                    ELSE '{}'::jsonb END);

  RETURN jsonb_build_object('new_status', 'completed', 'completed_at', v_completed_at);
END $function$;

DROP FUNCTION IF EXISTS public.crm_inventario_usd_operacion(uuid);
DROP FUNCTION IF EXISTS public.usd_verificar_saldo(remittance_operations);
DROP FUNCTION IF EXISTS public.usd_necesidad_operacion(remittance_operations);
DROP FUNCTION IF EXISTS public.usd_operacion_es_mexico(uuid, text);
DROP FUNCTION IF EXISTS public.usd_devolver(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.usd_consumir(uuid, text, numeric, uuid, uuid, timestamptz, text);
DROP FUNCTION IF EXISTS public.usd_faltante(uuid, text, numeric, timestamptz);
DROP FUNCTION IF EXISTS public.usd_planificar(uuid, text, numeric, timestamptz);
DROP FUNCTION IF EXISTS public.usd_alertar(uuid, uuid, text, text);
