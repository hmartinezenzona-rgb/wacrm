-- =====================================================================
-- 240 -- CUP inventory: automatic consumption, return on void, alerts (staging first)
--
-- odd/tasks/cup-card-inventory.md (T6, phase 2). Owner decisions (2026-10-14/15): a CUP remesa costs what the CUP really cost, by
-- sending card and lot. 239 only TRACKED the inventory; 240 makes it move.
--   * cup_consumir(account, amount_cup, entry_id, operation_id, at, cuba_day) -> (consumed_cup, missing_cup, effective_rate, parts):
--     under the advisory lock 'cup-inventory:<account>' (the SAME key 239's admin RPCs take, so a lot edit and a consumption never
--     interleave) it walks the ACTIVE cards by priority (then created_at), takes from each at most
--     min(sum of its lots' remaining, daily_limit_cup - what the card already gave on that Cuba day), FIFO inside the card (lots by
--     loaded_at, created_at), writes one cup_lot_consumptions row per lot touched and lowers remaining_cup. A request that does not
--     fit on one card SPLITS to the next. effective_rate = consumed_cup / sum(part_cup / lot_rate) (NULL if nothing was consumed).
--     Idempotent: if consumptions already exist for the entry (or, before the entry exists, for the operation) it consumes nothing
--     and reports the existing ones. A lot is consumable whatever its loaded_at (a manual line dated yesterday may use a lot loaded today).
--   * cup_devolver(entry_id [, operation_id]) -> CUP returned: each consumption goes back to its lot (remaining_cup + amount, never above
--     amount_cup) and the consumption row is DELETED, not flagged. Why delete: used_today, the remaining limit and the idempotency check
--     all read "consumptions that stand"; a flagged row would need a filter in each, and a void-then-revive would collide with it. The
--     history of what happened stays in the audit/void trail of the entry. Idempotent (no rows -> returns 0).
--   * cup_alertar(account, operation, title, body): a notification (new type 'inventario_cup') to every owner/admin of the account. It
--     reuses the table behind the 'coherencia_servicio' alert (231) and the app's bell; it NEVER raises (a failed alert is only a WARNING).
--   * HOOKS (each marked "(240)" inside the body, everything else is the previous body verbatim):
--       calculator_feed_operation  -- a fully priced CUP chat line that is about to be written takes its CUP BEFORE the INSERT, so it is
--         written once with the right cup_rate / invertido / retorno (no UPDATE of a completed row, the 149 guard and its
--         wacrm.calculator_correction hole are not used) and the consumptions are linked to the new row right after. The combined rate is
--         cup_rate = amount / (consumed / effective_rate + missing / global usdt_sell_cup), so invertido = amount / cup_rate * usdt_buy_gyd
--         is exactly (consumed / lot-rate + shortfall / global) * usdt_buy_gyd. A shortfall alerts and the rest uses the global rate. Any
--         exception of the inventory part is caught inside the function (its subtransaction undoes the partial work): the line keeps the
--         global rate, an alert is raised, the feed (inside the trigger's EXCEPTION WHEN OTHERS) is never aborted by the inventory.
--         It only consumes when the row will be INSERTED or REVIVED (no live row, no deleted_at row): a re-feed of a live line is a no-op.
--         A PENDING CUP line (missing rates) consumes nothing; see the OPEN POINT below.
--       crm_registrar_entradas_manuales -- a manual CUP line (currency CUP) consumes its amount after the row exists. The typed rate is
--         untouched. Cuba day = the line's date when it is not today (Guyana), else the current Cuba day. A shortfall or a failure alerts
--         and the registration still succeeds.
--       remittance_operations_calculator_feed (trigger, 104) -- an operation leaving 'completed' voids its lines; the CUP lines now also
--         get cup_devolver, each in its own subtransaction (a failure alerts, it does not undo the void or the status change).
--       crm_eliminar_entrada_calculadora (228) -- deleting a CUP line (chat OR manual: 228 made manual lines deletable, so the phase-2 note
--         "manual lines cannot be deleted" no longer holds) gives its CUP back; here a failure is NOT swallowed (the deletion fails with it).
--       crm_inventario_cup (239) -- each card also carries consumptions_today (time, amount, lot rate, operation / entry, source, customer,
--         at most 100, newest first) for the page; used_today_cup already summed cup_lot_consumptions, so it now reflects real use.
--   * Untouched by design: the rate-edit RPC (236-238) and crm_corregir_entrada_calculadora change only an entry's profit figures, never the
--     inventory. crm_resolve_pending_entry is NOT hooked (OPEN POINT: a CUP line that was pending when its operation completed and is later
--     resolved by an admin does not consume; the phase-2 doc lists it for the owner to decide).
--   * Lock order (no deadlock): calculator-cut:<account> (manual registration, week cut) -> cup-inventory:<account> (inside cup_consumir /
--     cup_devolver, also the 239 admin RPCs, which take nothing else). The feed and the trigger take only cup-inventory (after the operation
--     row they are already fired from). Nothing takes cup-inventory and then calculator-cut.
--   * notifications_type_check: 231's list carried forward + 'inventario_cup'.
-- Replaced bodies (md5 of the body text between the $function$/$$ delimiters as written in the migration that last defined it; confirm on
-- the target with md5(prosrc) before applying, ROLLBACK-240 restores exactly these texts):
--   calculator_feed_operation              1a9b5bc161de994196a4d899d31ffab3  (migration 235)
--   crm_registrar_entradas_manuales        1390c52323fa5fc0929b9abb9d781268  (migration 228)
--   crm_eliminar_entrada_calculadora       497ed1157498dfa9c12aae71c6b1089b  (migration 228)
--   remittance_operations_calculator_feed  71ecdeaae2233519a480c190c0bbcea4  (migration 104)
--   crm_inventario_cup                     a76c03d6bb317b0448c8474fdf0e2842  (migration 239)
-- Grants: CREATE OR REPLACE keeps the ACLs of the five replaced functions. The three NEW internal functions are revoked from PUBLIC, anon,
-- authenticated and service_role: only the SECURITY DEFINER bodies above (owner postgres) call them. No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/cup-inventory-consumption.sql (pending staging run, T8). ROLLBACK: ROLLBACK-240-cup-inventory-consumption.sql
-- =====================================================================

ALTER TABLE public.notifications DROP CONSTRAINT IF EXISTS notifications_type_check;
ALTER TABLE public.notifications ADD CONSTRAINT notifications_type_check CHECK (type IN (
  'conversation_assigned', 'deal_incidencia', 'mensaje_fallido', 'promo_etecsa', 'chat_atascado', 'ingesta_caida', 'deposito_sin_cruzar',
  'mensaje_perdido', 'envio_incompleto', 'pide_mlc', 'envio_sin_beneficiario', 'remesa_abierta_vieja', 'entrega_efectivo_lista',
  'coherencia_servicio', 'inventario_cup'));

-- ---------------------------------------------------------------------
-- cup_alertar: a notification for the owners/admins; never raises.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cup_alertar(p_account_id uuid, p_operation_id uuid, p_title text, p_body text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_conv    uuid;
  v_contact uuid;
  v_n       integer := 0;
BEGIN
  BEGIN
    IF p_operation_id IS NOT NULL THEN
      SELECT conv.id, conv.contact_id INTO v_conv, v_contact
        FROM remittance_operations o JOIN conversations conv ON conv.id = o.conversation_id
       WHERE o.id = p_operation_id;
    END IF;
    INSERT INTO notifications (account_id, user_id, type, conversation_id, contact_id, title, body)
    SELECT p_account_id, p.user_id, 'inventario_cup', v_conv, v_contact, left(p_title, 200), left(p_body, 1000)
      FROM profiles p
     WHERE p.account_id = p_account_id AND p.account_role IN ('owner', 'admin')
       AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);
    GET DIAGNOSTICS v_n = ROW_COUNT;
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING '[wacrm] cup_alertar failed for account %: % (%)', p_account_id, SQLERRM, p_title;
    v_n := 0;
  END;
  RETURN v_n;
END;
$function$;

-- ---------------------------------------------------------------------
-- cup_consumir: take CUP from the sending cards (priority, FIFO lots, daily limit, split).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cup_consumir(
  p_account_id  uuid,
  p_amount_cup  numeric,
  p_entry_id    uuid,
  p_operation_id uuid,
  p_at          timestamptz,
  p_cuba_day    date
) RETURNS TABLE (consumed_cup numeric, missing_cup numeric, effective_rate numeric, parts jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card     cup_cards;
  v_lot      cup_lots;
  v_day      date;
  v_at       timestamptz := coalesce(p_at, clock_timestamp());
  v_left     numeric;
  v_room     numeric;
  v_take     numeric;
  v_consumed numeric := 0;
  v_usdt     numeric := 0;
  v_parts    jsonb := '[]'::jsonb;
BEGIN
  IF p_account_id IS NULL OR p_amount_cup IS NULL OR p_amount_cup <= 0 THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, NULL::numeric, '[]'::jsonb;
    RETURN;
  END IF;
  v_day := coalesce(p_cuba_day, cup_cuba_day(v_at));

  -- lock order: calculator-cut (callers that hold it) -> cup-inventory. Same key as the 239 admin RPCs.
  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || p_account_id::text, 0));

  -- Idempotent: what already stands for this entry (or operation, before its entry exists) is reported, not taken again.
  SELECT coalesce(sum(k.amount_cup), 0), coalesce(sum(k.amount_cup / l.rate_cup_per_usdt), 0),
         coalesce(jsonb_agg(jsonb_build_object('card_id', k.card_id, 'lot_id', k.lot_id, 'amount_cup', k.amount_cup,
                                               'rate_cup_per_usdt', l.rate_cup_per_usdt) ORDER BY k.consumed_at, k.id), '[]'::jsonb)
    INTO v_consumed, v_usdt, v_parts
    FROM cup_lot_consumptions k JOIN cup_lots l ON l.id = k.lot_id
   WHERE k.account_id = p_account_id
     AND ((p_entry_id IS NOT NULL AND k.calculator_entry_id = p_entry_id)
          OR (p_operation_id IS NOT NULL AND k.operation_id = p_operation_id));
  IF v_consumed > 0 THEN
    RETURN QUERY SELECT v_consumed, greatest(p_amount_cup - v_consumed, 0::numeric), v_consumed / v_usdt, v_parts;
    RETURN;
  END IF;

  v_left := p_amount_cup;
  FOR v_card IN
    SELECT * FROM cup_cards WHERE account_id = p_account_id AND active ORDER BY priority, created_at, id
  LOOP
    EXIT WHEN v_left <= 0;
    SELECT greatest(v_card.daily_limit_cup - coalesce(sum(k.amount_cup), 0), 0) INTO v_room
      FROM cup_lot_consumptions k WHERE k.card_id = v_card.id AND k.cuba_day = v_day;
    v_room := least(v_room, v_left);
    FOR v_lot IN
      SELECT * FROM cup_lots WHERE card_id = v_card.id AND remaining_cup > 0 ORDER BY loaded_at, created_at, id FOR UPDATE
    LOOP
      EXIT WHEN v_room <= 0;
      v_take := least(v_lot.remaining_cup, v_room);
      INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, calculator_entry_id, operation_id, amount_cup, consumed_at, cuba_day)
      VALUES (p_account_id, v_lot.id, v_card.id, p_entry_id, p_operation_id, v_take, v_at, v_day);
      UPDATE cup_lots SET remaining_cup = remaining_cup - v_take WHERE id = v_lot.id;
      v_consumed := v_consumed + v_take;
      v_usdt := v_usdt + v_take / v_lot.rate_cup_per_usdt;
      v_parts := v_parts || jsonb_build_object('card_id', v_card.id, 'lot_id', v_lot.id, 'amount_cup', v_take,
                                               'rate_cup_per_usdt', v_lot.rate_cup_per_usdt);
      v_room := v_room - v_take;
      v_left := v_left - v_take;
    END LOOP;
  END LOOP;

  RETURN QUERY SELECT v_consumed, greatest(p_amount_cup - v_consumed, 0::numeric),
                      CASE WHEN v_consumed > 0 THEN v_consumed / v_usdt END, v_parts;
END;
$function$;

-- ---------------------------------------------------------------------
-- cup_devolver: give an entry's CUP back to its lots (consumption rows are deleted).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cup_devolver(p_entry_id uuid, p_operation_id uuid DEFAULT NULL)
 RETURNS numeric
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_op      uuid;
  v_k       cup_lot_consumptions;
  v_total   numeric := 0;
BEGIN
  IF p_entry_id IS NOT NULL THEN
    SELECT account_id, operation_id INTO v_account, v_op FROM remittance_calculator_entries WHERE id = p_entry_id;
    IF NOT FOUND THEN
      RETURN 0;
    END IF;
  ELSIF p_operation_id IS NOT NULL THEN
    SELECT account_id INTO v_account FROM remittance_operations WHERE id = p_operation_id;
    IF NOT FOUND THEN
      RETURN 0;
    END IF;
    v_op := p_operation_id;
  ELSE
    RETURN 0;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || v_account::text, 0));

  -- the consumptions linked to the entry, plus any not yet linked to one for the same operation
  FOR v_k IN
    SELECT * FROM cup_lot_consumptions k
     WHERE k.account_id = v_account
       AND ((p_entry_id IS NOT NULL AND k.calculator_entry_id = p_entry_id)
            OR (v_op IS NOT NULL AND k.calculator_entry_id IS NULL AND k.operation_id = v_op))
     ORDER BY k.consumed_at, k.id
     FOR UPDATE
  LOOP
    UPDATE cup_lots SET remaining_cup = least(remaining_cup + v_k.amount_cup, amount_cup) WHERE id = v_k.lot_id;
    DELETE FROM cup_lot_consumptions WHERE id = v_k.id;
    v_total := v_total + v_k.amount_cup;
  END LOOP;

  RETURN v_total;
END;
$function$;


-- ---------------------------------------------------------------------
-- Replaced functions (latest body carried forward verbatim, hook marked (240))
-- ---------------------------------------------------------------------

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

CREATE OR REPLACE FUNCTION remittance_operations_calculator_feed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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
                  WHERE l.card_id = c.id AND l.remaining_cup > 0), '[]'::jsonb),
               'consumptions_today', coalesce((
                 SELECT jsonb_agg(jsonb_build_object(
                          'id', m.id,
                          'consumed_at', m.consumed_at,
                          'amount_cup', m.amount_cup,
                          'lot_id', m.lot_id,
                          'lot_rate_cup_per_usdt', m.lot_rate,
                          'operation_id', m.operation_id,
                          'entry_id', m.calculator_entry_id,
                          'source', m.source,
                          'customer_name', m.customer_name
                        ) ORDER BY m.consumed_at DESC, m.id)
                   FROM (
                     SELECT k.id, k.consumed_at, k.amount_cup, k.lot_id, lt.rate_cup_per_usdt AS lot_rate, k.operation_id,
                            k.calculator_entry_id, e.source, e.customer_name
                       FROM cup_lot_consumptions k
                       JOIN cup_lots lt ON lt.id = k.lot_id
                       LEFT JOIN remittance_calculator_entries e ON e.id = k.calculator_entry_id
                      WHERE k.card_id = c.id AND k.cuba_day = v_today
                      ORDER BY k.consumed_at DESC, k.id
                      LIMIT 100) m), '[]'::jsonb)
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

REVOKE ALL ON FUNCTION public.cup_alertar(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.cup_devolver(uuid, uuid) FROM PUBLIC, anon, authenticated, service_role;

COMMENT ON FUNCTION public.cup_alertar(uuid, uuid, text, text) IS
  '(240) Internal. Notification (type inventario_cup) to the owners/admins of the account; never raises.';
COMMENT ON FUNCTION public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date) IS
  '(240) Internal. Takes CUP from the active cards by priority (daily limit per Cuba day, lots FIFO, split across cards); idempotent per entry/operation.';
COMMENT ON FUNCTION public.cup_devolver(uuid, uuid) IS
  '(240) Internal. Returns the CUP an entry took to its lots and deletes the consumption rows; idempotent.';
COMMENT ON TABLE public.cup_lot_consumptions IS '(239/240) CUP taken from a lot, by Cuba day. Written by cup_consumir, deleted by cup_devolver.';
COMMENT ON FUNCTION public.crm_inventario_cup(uuid, boolean) IS
  'Admin+ only. Per card in priority order: balance, FIFO lots, used today and remaining limit for the current Cuba day, and today''s consumptions.';
