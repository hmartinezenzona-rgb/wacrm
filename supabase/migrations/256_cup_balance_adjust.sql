-- =====================================================================
-- 256 -- CUP inventory: adjustable card balance, consumption kind, full lot history (staging first)
--
-- odd/tasks/cup-balance-adjust-and-source-card.md (B1). The owner sets a card's REAL balance from the page; every lot stays visible.
--   * cup_lot_consumptions.kind: 'operacion' (chat / CRM operation), 'manual' (manual Calculator line), 'ajuste' (balance adjustment).
--     Backfill: a row whose entry is a manual line -> 'manual', every other existing row -> 'operacion'. Also `reason` (text, ajuste only)
--     and `created_by` (the acting user, ajuste only). The 239 CHECK amount_cup > 0 becomes: ajuste rows may be NEGATIVE (non-zero),
--     every other kind stays > 0. An ajuste row carries no operation / entry reference.
--   * crm_ajustar_saldo_cup(card, target_balance, reason) -> jsonb {card_id, saldo_anterior, saldo_nuevo, movimientos:[{lot_id, amount_cup}]}.
--     Admin+ (42501), unknown card P0002, target NULL / negative / reason > 500 chars / target above the sum of the card's loaded amounts
--     22023 ("load a new lot"). Serialized by the advisory lock 'cup-inventory:<account>'. LOWER: the difference is taken FIFO (oldest loaded
--     first) from lots with remaining > 0, recorded as POSITIVE ajuste rows (same sign as any consumption: CUP taken off the lot).
--     HIGHER: the difference is given back NEWEST-first, each lot up to its loaded amount (amount - remaining), recorded as NEGATIVE ajuste
--     rows. Equal: no-op (no rows, no audit). One remittance_admin_audit row (cup_cards / human_correction / balance_cup, before / after /
--     reason / actor) when something moved. movimientos.amount_cup has the ledger sign (positive = taken off the lot, negative = given back).
--     SIGN CONVENTION, why: 240 returns CUP by DELETING the consumption row (a void erases the consumption, nothing to explain). An
--     adjustment is an audit fact the owner wants to keep visible, so it is never deleted: an increase APPENDS a mirror (negative) row,
--     and sum(ledger of a lot) = amount - remaining still holds for every lot touched only through the ledger.
--   * The daily limit ignores adjustments: cup_planificar (the 241 allocator) and crm_inventario_cup count only kind <> 'ajuste' for "used
--     today" / remaining limit. Adjusted lots stay usable by the allocator.
--   * cup_consumir sets kind ('manual' when the entry is a manual line, else 'operacion'); everything else of the 240/241 body is verbatim.
--   * crm_inventario_cup lists EVERY lot of the card (used-up ones included) with agotado (remaining = 0), adjusted and adjustment_net_cup
--     (net CUP taken off the lot by adjustments), and kind / reason on every movement. Fields are added, none renamed.
-- Replaced bodies (md5 of prosrc, i.e. the text between the $function$ delimiters; ROLLBACK-256 restores exactly these texts):
--   cup_planificar      6ed9de4dd8a6ba11853a62d501559a01  (241)
--   cup_consumir        6686341131868928e9a89a14808bcd1b  (241)
--   crm_inventario_cup  b4b33373851ecdb91e5ffd18eca5e18d  (240)
-- Grants: crm_ajustar_saldo_cup EXECUTE to authenticated only (REVOKE FROM PUBLIC, anon); replaced functions keep their ACL.
-- No BEGIN/COMMIT. Guarded by supabase/staging/assertions/cup-balance-adjust.sql. ROLLBACK: ROLLBACK-256-cup-balance-adjust.sql
-- =====================================================================

ALTER TABLE public.cup_lot_consumptions
  ADD COLUMN IF NOT EXISTS kind       text NOT NULL DEFAULT 'operacion',
  ADD COLUMN IF NOT EXISTS reason     text,
  ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL;

UPDATE public.cup_lot_consumptions k
   SET kind = 'manual'
  FROM public.remittance_calculator_entries e
 WHERE e.id = k.calculator_entry_id AND e.source = 'manual';

ALTER TABLE public.cup_lot_consumptions DROP CONSTRAINT IF EXISTS cup_lot_consumptions_amount_cup_check;
ALTER TABLE public.cup_lot_consumptions
  ADD CONSTRAINT cup_lot_consumptions_kind_chk CHECK (kind IN ('operacion', 'manual', 'ajuste')),
  ADD CONSTRAINT cup_lot_consumptions_amount_sign_chk CHECK (
    (kind = 'ajuste' AND amount_cup <> 0) OR (kind <> 'ajuste' AND amount_cup > 0)),
  ADD CONSTRAINT cup_lot_consumptions_ajuste_refs_chk CHECK (
    kind <> 'ajuste' OR (calculator_entry_id IS NULL AND operation_id IS NULL)),
  ADD CONSTRAINT cup_lot_consumptions_reason_length_chk CHECK (length(reason) <= 500);

COMMENT ON COLUMN public.cup_lot_consumptions.kind IS
  '(256) operacion = chat/CRM operation, manual = manual Calculator line, ajuste = balance adjustment (excluded from the daily limit; may be negative = CUP given back).';

-- ---------------------------------------------------------------------
-- cup_planificar (241 body): the daily room ignores adjustments.
-- ---------------------------------------------------------------------
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
      FROM cup_lot_consumptions k WHERE k.card_id = v_card.id AND k.cuba_day = p_cuba_day AND k.kind <> 'ajuste';
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
-- cup_consumir (241 body): writes the consumption kind.
-- ---------------------------------------------------------------------
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
  v_kind     text := 'operacion';
BEGIN
  IF p_account_id IS NULL OR p_amount_cup IS NULL OR p_amount_cup <= 0 THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, NULL::numeric, '[]'::jsonb;
    RETURN;
  END IF;
  v_day := coalesce(p_cuba_day, cup_cuba_day(v_at));

  -- (256) the kind of what this call writes: a manual Calculator line, else a chat / CRM operation.
  IF p_entry_id IS NOT NULL AND EXISTS (SELECT 1 FROM remittance_calculator_entries e WHERE e.id = p_entry_id AND e.source = 'manual') THEN
    v_kind := 'manual';
  END IF;

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
    INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, calculator_entry_id, operation_id, amount_cup, consumed_at, cuba_day, kind)
    VALUES (p_account_id, v_part.lot_id, v_part.card_id, p_entry_id, p_operation_id, v_part.amount_cup, v_at, v_day, v_kind);
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
-- crm_inventario_cup (240 body): every lot, kind / reason on movements, used today without adjustments.
-- ---------------------------------------------------------------------
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
                                       AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions k WHERE k.lot_id = l.id)),
                          'agotado', (l.remaining_cup = 0),
                          'adjusted', EXISTS (SELECT 1 FROM cup_lot_consumptions k WHERE k.lot_id = l.id AND k.kind = 'ajuste'),
                          'adjustment_net_cup', (SELECT sum(k.amount_cup) FROM cup_lot_consumptions k WHERE k.lot_id = l.id AND k.kind = 'ajuste')
                        ) ORDER BY l.loaded_at, l.created_at, l.id)
                   FROM cup_lots l
                  WHERE l.card_id = c.id), '[]'::jsonb),
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
                          'customer_name', m.customer_name,
                          'kind', m.kind,
                          'reason', m.reason
                        ) ORDER BY m.consumed_at DESC, m.id)
                   FROM (
                     SELECT k.id, k.consumed_at, k.amount_cup, k.lot_id, lt.rate_cup_per_usdt AS lot_rate, k.operation_id,
                            k.calculator_entry_id, e.source, e.customer_name, k.kind, k.reason
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
           WHERE k.card_id = c.id AND k.cuba_day = v_today AND k.kind <> 'ajuste'
        ) u
       WHERE c.account_id = p_account_id AND (c.active OR p_include_inactive)
    ) card;

  RETURN jsonb_build_object('cuba_day', v_today, 'cards', v_cards);
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_ajustar_saldo_cup: set a card's real balance (admin).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_ajustar_saldo_cup(
  p_card_id    uuid,
  p_saldo_cup  numeric,
  p_motivo     text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card     cup_cards;
  v_lot      cup_lots;
  v_reason   text;
  v_before   numeric;
  v_loaded   numeric;
  v_left     numeric;
  v_take     numeric;
  v_day      date := cup_cuba_day(now());
  v_moves    jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_card FROM cup_cards WHERE id = p_card_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_card.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the CUP inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || v_card.account_id::text, 0));

  IF p_saldo_cup IS NULL OR NOT (p_saldo_cup >= 0 AND p_saldo_cup < 1e12) THEN
    RAISE EXCEPTION 'saldo_cup must be zero or greater' USING ERRCODE = '22023';
  END IF;
  v_reason := nullif(btrim(p_motivo), '');
  IF length(v_reason) > 500 THEN
    RAISE EXCEPTION 'reason is too long (500 characters at most)' USING ERRCODE = '22023';
  END IF;

  -- lock the card's lots in a stable order, then read the totals under the lock
  PERFORM 1 FROM cup_lots WHERE card_id = p_card_id ORDER BY loaded_at, created_at, id FOR UPDATE;
  SELECT coalesce(sum(remaining_cup), 0), coalesce(sum(amount_cup), 0) INTO v_before, v_loaded FROM cup_lots WHERE card_id = p_card_id;

  IF p_saldo_cup > v_loaded THEN
    RAISE EXCEPTION 'the balance cannot exceed what was loaded on the card (% CUP): load a new lot', v_loaded USING ERRCODE = '22023';
  END IF;

  IF p_saldo_cup < v_before THEN
    -- LOWER: take the difference FIFO (oldest loaded first), as positive ajuste rows.
    v_left := v_before - p_saldo_cup;
    FOR v_lot IN
      SELECT l.* FROM cup_lots l WHERE l.card_id = p_card_id AND l.remaining_cup > 0 ORDER BY l.loaded_at, l.created_at, l.id
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_lot.remaining_cup, v_left);
      INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, consumed_at, cuba_day, kind, reason, created_by)
      VALUES (v_card.account_id, v_lot.id, p_card_id, v_take, clock_timestamp(), v_day, 'ajuste', v_reason, auth.uid());
      UPDATE cup_lots SET remaining_cup = remaining_cup - v_take WHERE id = v_lot.id;
      v_moves := v_moves || jsonb_build_object('lot_id', v_lot.id, 'amount_cup', v_take);
      v_left := v_left - v_take;
    END LOOP;
  ELSIF p_saldo_cup > v_before THEN
    -- HIGHER: give the difference back newest-first, each lot up to its loaded amount, as NEGATIVE ajuste rows.
    v_left := p_saldo_cup - v_before;
    FOR v_lot IN
      SELECT l.* FROM cup_lots l WHERE l.card_id = p_card_id AND l.remaining_cup < l.amount_cup ORDER BY l.loaded_at DESC, l.created_at DESC, l.id DESC
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_lot.amount_cup - v_lot.remaining_cup, v_left);
      INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, consumed_at, cuba_day, kind, reason, created_by)
      VALUES (v_card.account_id, v_lot.id, p_card_id, -v_take, clock_timestamp(), v_day, 'ajuste', v_reason, auth.uid());
      UPDATE cup_lots SET remaining_cup = remaining_cup + v_take WHERE id = v_lot.id;
      v_moves := v_moves || jsonb_build_object('lot_id', v_lot.id, 'amount_cup', -v_take);
      v_left := v_left - v_take;
    END LOOP;
  END IF;

  IF jsonb_array_length(v_moves) > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_card.account_id, 'cup_cards', p_card_id, 'balance_cup', 'human_correction', wacrm_current_actor(), v_reason,
            jsonb_build_object('balance_cup', v_before),
            jsonb_build_object('balance_cup', p_saldo_cup, 'movimientos', v_moves));
  END IF;

  RETURN jsonb_build_object('card_id', p_card_id, 'saldo_anterior', v_before, 'saldo_nuevo', p_saldo_cup, 'movimientos', v_moves);
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_ajustar_saldo_cup(uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_ajustar_saldo_cup(uuid, numeric, text) TO authenticated;
COMMENT ON FUNCTION public.crm_ajustar_saldo_cup(uuid, numeric, text) IS
  '(256) Admin+. Sets the card balance: lower = FIFO positive ajuste rows, higher = newest-first negative ajuste rows up to each lot''s loaded amount; audited; never touches the daily limit.';
