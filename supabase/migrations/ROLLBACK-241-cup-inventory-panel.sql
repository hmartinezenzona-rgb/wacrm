-- ROLLBACK of 241_cup_inventory_panel.sql: drops the panel RPC and the shared allocator and restores 240's cup_consumir body (inline
-- allocation; md5 of its text 0e6e3a2111e798735c4ba4c681054504). Consumptions already written are untouched. No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.crm_inventario_cup_operacion(uuid);

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

DROP FUNCTION IF EXISTS public.cup_planificar(uuid, numeric, date);
