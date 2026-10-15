-- =====================================================================
-- 241 -- CUP inventory: delivery-panel plan (one allocator, read-only plan, panel RPC) (staging first)
--
-- odd/tasks/cup-card-inventory.md (T10, phase 3). The chat panel of a CUP remesa shows which card the CUP will leave from (before
-- completion, an ESTIMATE) and which cards/lots it left from (after).
--   * cup_planificar(account, amount_cup, cuba_day) -> ordered parts (seq, card_id, lot_id, amount_cup, lot_rate): the ONE allocator.
--     It is 240's allocation loop moved out of cup_consumir verbatim and made read-only: active cards by (priority, created_at, id), room =
--     min(daily_limit - what the card gave on that Cuba day, what is still to place), lots FIFO (loaded_at, created_at, id) with
--     remaining_cup > 0, take = min(lot remaining, room). It writes nothing and takes no lock.
--   * cup_consumir (240) now calls cup_planificar for the split and keeps everything else of 240 verbatim: argument guard, advisory lock
--     'cup-inventory:<account>', the idempotency check, the consumption INSERT, the lot UPDATE, the parts/usdt accumulation and the
--     RETURN shape. Equivalence argument: (1) the planner runs AFTER the advisory lock cup_consumir already holds, and every writer of
--     lots/consumptions (239 admin RPCs, cup_consumir, cup_devolver) takes that same lock, so the planner sees exactly the state the old
--     inline loop saw; (2) the old loop read each card's used amount before inserting that card's consumptions and inserts for card X never
--     change card Y's room, and each lot was visited once, so planning first and inserting after yields the same parts in the same order;
--     (3) the per-lot row lock the old cursor took (FOR UPDATE) is kept as a PERFORM ... FOR UPDATE per part. The 240 assertion
--     (cup-inventory-consumption.sql) drives cup_consumir through the feed, manual registration and resolve, so it must still pass unchanged;
--     the new assertion also proves plan = consumption part by part.
--   * crm_inventario_cup_operacion(operation_id) -> jsonb, for the panel. Callable by members with role agent or above of the operation's
--     account (the roles that complete the operation; viewers are refused). state:
--       'plan'          CUP operation not completed: the plan for the CUP amount of its current beneficiaries, segmented per beneficiary in
--                       position order (greedy fill over the same plan), total/planned/missing, effective_rate, cuba_day, estimate = true.
--       'completed'     the consumptions linked to the operation (card name, last4, lot rate, amount) and the entry cup_rate, estimate = false.
--       'no_inventory'  CUP operation but the account has no active card.   'no_amounts' CUP beneficiaries without a CUP amount.
--       'not_cup'       nothing CUP about the operation.                    'unavailable' cancelled operation.
--     Card names and last4 only; never card numbers.
-- Replaced bodies (md5 of the text between the $function$ delimiters, newline-delimited as prosrc stores it; confirm with md5(prosrc) before
-- applying, ROLLBACK-241 restores exactly this text):
--   cup_consumir   0e6e3a2111e798735c4ba4c681054504  (migration 240)
-- Grants: cup_planificar is internal (revoked from PUBLIC, anon, authenticated, service_role). The RPC is EXECUTE postgres + authenticated.
-- No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/cup-inventory-panel.sql (pending staging run, T12). ROLLBACK: ROLLBACK-241-cup-inventory-panel.sql
-- =====================================================================

-- ---------------------------------------------------------------------
-- cup_planificar: the allocator. Read-only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cup_planificar(p_account_id uuid, p_amount_cup numeric, p_cuba_day date)
 RETURNS TABLE (seq integer, card_id uuid, lot_id uuid, amount_cup numeric, lot_rate numeric)
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
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

-- ---------------------------------------------------------------------
-- cup_consumir: 240 body, allocation delegated to cup_planificar.
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

-- ---------------------------------------------------------------------
-- crm_inventario_cup_operacion: what the delivery panel shows for one operation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_inventario_cup_operacion(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_op       remittance_operations;
  v_day      date := cup_cuba_day(now());
  v_n_cup    integer;
  v_total    numeric;
  v_planned  numeric;
  v_usdt     numeric;
  v_bens     jsonb;
  v_lines    jsonb;
  v_consumed numeric;
  v_rate     numeric;
BEGIN
  SELECT * INTO v_op FROM remittance_operations WHERE id = p_operation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'operation not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_op.account_id, 'agent'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read the CUP plan of this operation' USING ERRCODE = '42501';
  END IF;

  IF v_op.status = 'cancelled' THEN
    RETURN jsonb_build_object('state', 'unavailable', 'operation_id', v_op.id);
  END IF;

  SELECT count(*) INTO v_n_cup FROM remittance_beneficiaries b
   WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND calculator_service_for_operation(b.beneficiary_type) = 'CUP';

  -- ---- completed: what really left, from the consumptions linked to the operation or to its entries ----------------------------
  IF v_op.status = 'completed' THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'card_id', c.id, 'card_name', c.name, 'last4', c.last4, 'lot_id', l.id,
             'amount_cup', k.amount_cup, 'lot_rate', l.rate_cup_per_usdt, 'consumed_at', k.consumed_at) ORDER BY k.consumed_at, k.id), '[]'::jsonb),
           coalesce(sum(k.amount_cup), 0)
      INTO v_lines, v_consumed
      FROM cup_lot_consumptions k
      JOIN cup_cards c ON c.id = k.card_id
      JOIN cup_lots l ON l.id = k.lot_id
     WHERE k.account_id = v_op.account_id
       AND (k.operation_id = v_op.id
            OR k.calculator_entry_id IN (SELECT e.id FROM remittance_calculator_entries e WHERE e.operation_id = v_op.id));
    IF v_consumed = 0 AND v_n_cup = 0 THEN
      RETURN jsonb_build_object('state', 'not_cup', 'operation_id', v_op.id);
    END IF;
    SELECT e.cup_rate INTO v_rate
      FROM remittance_calculator_entries e
     WHERE e.operation_id = v_op.id AND e.account_id = v_op.account_id AND e.service = 'CUP' AND e.source = 'completed_operation'
       AND e.status <> 'void' AND e.deleted_at IS NULL
     ORDER BY e.created_at DESC, e.id LIMIT 1;
    RETURN jsonb_build_object('state', 'completed', 'operation_id', v_op.id, 'estimate', false,
                              'consumed_cup', v_consumed, 'cup_rate', v_rate, 'lines', v_lines);
  END IF;

  -- ---- not completed: the plan --------------------------------------------------------------------------------------------------
  IF v_n_cup = 0 THEN
    RETURN jsonb_build_object('state', 'not_cup', 'operation_id', v_op.id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cup_cards c WHERE c.account_id = v_op.account_id AND c.active) THEN
    RETURN jsonb_build_object('state', 'no_inventory', 'operation_id', v_op.id);
  END IF;

  -- One statement: the CUP beneficiaries in position order with the CUP each receives (a lone CUP beneficiary without an amount takes the
  -- quoted CUP), ONE plan for their total from the shared allocator, and the plan cut per beneficiary by cumulative ranges (the same greedy
  -- fill as consuming the total at once: the first beneficiary takes the first part of the plan, and so on).
  WITH ben AS (
    SELECT b.id, b."position" AS pos, b.created_at, b.name,
           CASE WHEN b.amount > 0 AND coalesce(b.currency, 'CUP') = 'CUP' THEN b.amount
                WHEN v_n_cup = 1 AND v_op.destination_currency = 'CUP' AND v_op.quoted_destination_amount > 0
                  THEN v_op.quoted_destination_amount END AS amt
      FROM remittance_beneficiaries b
     WHERE b.operation_id = v_op.id AND b.status = 'vigente' AND calculator_service_for_operation(b.beneficiary_type) = 'CUP'
  ), bens AS (
    SELECT x.*, sum(x.amt) OVER (ORDER BY x.pos, x.created_at, x.id) - x.amt AS s, sum(x.amt) OVER (ORDER BY x.pos, x.created_at, x.id) AS e
      FROM ben x WHERE x.amt IS NOT NULL
  ), tot AS (
    SELECT coalesce(sum(x.amt), 0) AS t FROM bens x
  ), parts AS (
    SELECT p.seq, p.card_id, p.lot_id, p.amount_cup, p.lot_rate,
           sum(p.amount_cup) OVER (ORDER BY p.seq) - p.amount_cup AS ps, sum(p.amount_cup) OVER (ORDER BY p.seq) AS pe
      FROM tot, cup_planificar(v_op.account_id, tot.t, v_day) p
  )
  SELECT (SELECT t FROM tot),
         (SELECT coalesce(sum(p.amount_cup), 0) FROM parts p),
         (SELECT coalesce(sum(p.amount_cup / p.lot_rate), 0) FROM parts p),
         (SELECT coalesce(jsonb_agg(jsonb_build_object(
                   'beneficiary_id', bn.id, 'position', bn.pos, 'name', bn.name, 'amount_cup', bn.amt,
                   'missing_cup', bn.amt - coalesce(ln.placed, 0),
                   'lines', coalesce(ln.lines, '[]'::jsonb)) ORDER BY bn.pos, bn.created_at, bn.id), '[]'::jsonb)
            FROM bens bn
            LEFT JOIN LATERAL (
              SELECT sum(least(p.pe, bn.e) - greatest(p.ps, bn.s)) AS placed,
                     jsonb_agg(jsonb_build_object(
                       'card_id', c.id, 'card_name', c.name, 'last4', c.last4, 'lot_id', p.lot_id,
                       'amount_cup', least(p.pe, bn.e) - greatest(p.ps, bn.s), 'lot_rate', p.lot_rate) ORDER BY p.seq) AS lines
                FROM parts p JOIN cup_cards c ON c.id = p.card_id
               WHERE p.pe > bn.s AND p.ps < bn.e
            ) ln ON true)
    INTO v_total, v_planned, v_usdt, v_bens;

  IF v_total = 0 THEN
    RETURN jsonb_build_object('state', 'no_amounts', 'operation_id', v_op.id);
  END IF;

  RETURN jsonb_build_object('state', 'plan', 'operation_id', v_op.id, 'estimate', true, 'cuba_day', v_day,
                            'total_cup', v_total, 'planned_cup', v_planned, 'missing_cup', v_total - v_planned,
                            'effective_rate', CASE WHEN v_planned > 0 THEN v_planned / v_usdt END,
                            'beneficiaries', v_bens);
END;
$function$;

REVOKE ALL ON FUNCTION public.cup_planificar(uuid, numeric, date) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.crm_inventario_cup_operacion(uuid) FROM PUBLIC, anon, service_role;
GRANT EXECUTE ON FUNCTION public.crm_inventario_cup_operacion(uuid) TO authenticated;

COMMENT ON FUNCTION public.cup_planificar(uuid, numeric, date) IS
  '(241) Internal, read-only. The CUP allocator: ordered parts (card, lot, amount, lot rate) cup_consumir would take for this amount on this Cuba day.';
COMMENT ON FUNCTION public.crm_inventario_cup_operacion(uuid) IS
  '(241) Agent+ of the operation''s account. Delivery panel: estimated CUP plan per beneficiary (not completed) or the consumptions of a completed CUP operation; card name + last4 only.';
