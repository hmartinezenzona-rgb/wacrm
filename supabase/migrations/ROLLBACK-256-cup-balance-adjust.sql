-- ROLLBACK of 256_cup_balance_adjust.sql: restores the 241 / 240 bodies of cup_planificar, cup_consumir and crm_inventario_cup (md5 of prosrc
-- 6ed9de4d.. / 66863411.. / b4b33373..), drops crm_ajustar_saldo_cup and the kind / reason / created_by columns. The ajuste ledger rows are
-- DELETED (lot remaining_cup values stay as adjusted: the balances the owner set are kept). No BEGIN/COMMIT.

DROP FUNCTION IF EXISTS public.crm_ajustar_saldo_cup(uuid, numeric, text);

CREATE OR REPLACE FUNCTION public.cup_planificar(p_account_id uuid, p_amount_cup numeric, p_cuba_day date)
 RETURNS TABLE(seq integer, card_id uuid, lot_id uuid, amount_cup numeric, lot_rate numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card   cup_cards;
  v_lot    cup_lots;
  v_left   numeric;
  v_room   numeric;
  v_take   numeric;
  v_seq    integer := 0;
BEGIN
  IF p_account_id IS NULL OR p_amount_cup IS NULL OR p_amount_cup <= 0 THEN
    RETURN;
  END IF;

  v_left := p_amount_cup;
  FOR v_card IN
    SELECT c.* FROM cup_cards c WHERE c.account_id = p_account_id AND c.active ORDER BY c.priority, c.created_at, c.id
  LOOP
    EXIT WHEN v_left <= 0;
    SELECT greatest(v_card.daily_limit_cup - coalesce(sum(k.amount_cup), 0), 0) INTO v_room
      FROM cup_lot_consumptions k WHERE k.card_id = v_card.id AND k.cuba_day = p_cuba_day;
    v_room := least(v_room, v_left);
    FOR v_lot IN
      SELECT l.* FROM cup_lots l WHERE l.card_id = v_card.id AND l.remaining_cup > 0 ORDER BY l.loaded_at, l.created_at, l.id
    LOOP
      EXIT WHEN v_room <= 0;
      v_take := least(v_lot.remaining_cup, v_room);
      v_seq := v_seq + 1;
      seq := v_seq; card_id := v_card.id; lot_id := v_lot.id; amount_cup := v_take; lot_rate := v_lot.rate_cup_per_usdt;
      RETURN NEXT;
      v_room := v_room - v_take;
      v_left := v_left - v_take;
    END LOOP;
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cup_consumir(p_account_id uuid, p_amount_cup numeric, p_entry_id uuid, p_operation_id uuid, p_at timestamp with time zone, p_cuba_day date)
 RETURNS TABLE(consumed_cup numeric, missing_cup numeric, effective_rate numeric, parts jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_part     record;
  v_day      date;
  v_at       timestamptz := coalesce(p_at, clock_timestamp());
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

  -- (241) the split is decided by the shared allocator; this function only writes it.
  FOR v_part IN SELECT * FROM cup_planificar(p_account_id, p_amount_cup, v_day) ORDER BY seq
  LOOP
    PERFORM 1 FROM cup_lots WHERE id = v_part.lot_id FOR UPDATE;
    INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, calculator_entry_id, operation_id, amount_cup, consumed_at, cuba_day)
    VALUES (p_account_id, v_part.lot_id, v_part.card_id, p_entry_id, p_operation_id, v_part.amount_cup, v_at, v_day);
    UPDATE cup_lots SET remaining_cup = remaining_cup - v_part.amount_cup WHERE id = v_part.lot_id;
    v_consumed := v_consumed + v_part.amount_cup;
    v_usdt := v_usdt + v_part.amount_cup / v_part.lot_rate;
    v_parts := v_parts || jsonb_build_object('card_id', v_part.card_id, 'lot_id', v_part.lot_id, 'amount_cup', v_part.amount_cup,
                                             'rate_cup_per_usdt', v_part.lot_rate);
  END LOOP;

  RETURN QUERY SELECT v_consumed, greatest(p_amount_cup - v_consumed, 0::numeric),
                      CASE WHEN v_consumed > 0 THEN v_consumed / v_usdt END, v_parts;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_inventario_cup(p_account_id uuid, p_include_inactive boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
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

DELETE FROM public.cup_lot_consumptions WHERE kind = 'ajuste';
ALTER TABLE public.cup_lot_consumptions
  DROP CONSTRAINT IF EXISTS cup_lot_consumptions_kind_chk,
  DROP CONSTRAINT IF EXISTS cup_lot_consumptions_amount_sign_chk,
  DROP CONSTRAINT IF EXISTS cup_lot_consumptions_ajuste_refs_chk,
  DROP CONSTRAINT IF EXISTS cup_lot_consumptions_reason_length_chk,
  DROP COLUMN IF EXISTS kind,
  DROP COLUMN IF EXISTS reason,
  DROP COLUMN IF EXISTS created_by;
ALTER TABLE public.cup_lot_consumptions ADD CONSTRAINT cup_lot_consumptions_amount_cup_check CHECK (amount_cup > 0);
