-- ROLLBACK of 240_cup_inventory_consumption.sql: restores the previous bodies (calculator_feed_operation 235, crm_registrar_entradas_manuales 228,
-- crm_eliminar_entrada_calculadora 228, remittance_operations_calculator_feed 104, crm_inventario_cup 239) and drops the three new functions.
-- BEFORE running it: DELETE FROM notifications WHERE type = 'inventario_cup' (the restored check does not allow it).
-- DATA: the CUP already taken stays taken (cup_lot_consumptions and the lots' remaining_cup are NOT touched). After a rollback nothing returns
-- CUP to the lots automatically on a void; if the consumptions must be undone too, run cup_devolver for every entry first (or reset by hand).
-- No BEGIN/COMMIT.

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type IN (
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado', 'ingesta_caida', 'deposito_sin_cruzar',
  'mensaje_perdido', 'envio_incompleto', 'pide_mlc', 'envio_sin_beneficiario', 'remesa_abierta_vieja', 'entrega_efectivo_lista',
  'coherencia_servicio'));

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
           WHEN v_part.service IN ('RECARGA', 'SALDO_MOVIL') THEN v_rates.usdt_buy_gyd ELSE v_rates.usdt_sell_cup END,
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

    v_first_id := coalesce(v_first_id, v_entry_id);
  END LOOP;

  RETURN v_first_id;
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

    v_out := v_out || to_jsonb(v_entry);
  END LOOP;

  RETURN v_out;
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

  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
  VALUES (v_entry.account_id, 'remittance_calculator_entries', v_entry.id, 'status,deleted_at',
          'human_calculator_entry_deleted', v_actor, v_before, to_jsonb(v_entry));

  RETURN v_entry;
END;
$function$;

CREATE OR REPLACE FUNCTION remittance_operations_calculator_feed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_reason text;
BEGIN
  IF OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  BEGIN
    IF NEW.status = 'completed' THEN
      PERFORM calculator_feed_operation(NEW.id);

    ELSIF OLD.status = 'completed' THEN
      v_reason := format('operation reverted from completed to %s', NEW.status);
      UPDATE remittance_calculator_entries
         SET status      = 'void',
             voided_at   = clock_timestamp(),
             void_reason = v_reason
       WHERE account_id = NEW.account_id
         AND operation_id = NEW.id
         AND source = 'completed_operation'
         AND status <> 'void';
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

CREATE OR REPLACE FUNCTION public.crm_inventario_cup(p_account_id uuid, p_include_inactive boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_today date := cup_cuba_day(now());
  v_cards jsonb;
BEGIN
  IF p_account_id IS NULL OR NOT is_account_member(p_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read the CUP inventory' USING ERRCODE = '42501';
  END IF;

  SELECT coalesce(jsonb_agg(card.j ORDER BY card.priority, card.created_at, card.id), '[]'::jsonb) INTO v_cards
    FROM (
      SELECT c.priority, c.created_at, c.id,
             jsonb_build_object(
               'id', c.id,
               'name', c.name,
               'last4', c.last4,
               'priority', c.priority,
               'active', c.active,
               'daily_limit_cup', c.daily_limit_cup,
               'balance_cup', coalesce((SELECT sum(l.remaining_cup) FROM cup_lots l WHERE l.card_id = c.id), 0),
               'used_today_cup', u.used,
               'remaining_limit_today_cup', greatest(c.daily_limit_cup - u.used, 0),
               'lots', coalesce((
                 SELECT jsonb_agg(jsonb_build_object(
                          'id', l.id,
                          'amount_cup', l.amount_cup,
                          'remaining_cup', l.remaining_cup,
                          'rate_cup_per_usdt', l.rate_cup_per_usdt,
                          'loaded_at', l.loaded_at,
                          'note', l.note,
                          'editable', (l.remaining_cup = l.amount_cup
                                       AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions k WHERE k.lot_id = l.id))
                        ) ORDER BY l.loaded_at, l.created_at, l.id)
                   FROM cup_lots l
                  WHERE l.card_id = c.id AND l.remaining_cup > 0), '[]'::jsonb)
             ) AS j
        FROM cup_cards c
        CROSS JOIN LATERAL (
          SELECT coalesce(sum(k.amount_cup), 0) AS used
            FROM cup_lot_consumptions k
           WHERE k.card_id = c.id AND k.cuba_day = v_today
        ) u
       WHERE c.account_id = p_account_id AND (c.active OR p_include_inactive)
    ) card;

  RETURN jsonb_build_object('cuba_day', v_today, 'cards', v_cards);
END;
$function$;

DROP FUNCTION IF EXISTS public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date);
DROP FUNCTION IF EXISTS public.cup_devolver(uuid, uuid);
DROP FUNCTION IF EXISTS public.cup_alertar(uuid, uuid, text, text);
COMMENT ON TABLE public.cup_lot_consumptions IS '(239) CUP taken from a lot, by Cuba day. Empty in phase 1; phase 2 writes it.';
