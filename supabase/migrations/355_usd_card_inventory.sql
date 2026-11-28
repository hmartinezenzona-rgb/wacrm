-- =====================================================================
-- 355 -- Clasica / Tropical USD card inventory: cards, lots, monthly limit, balance adjust, report (staging first)
--
-- odd/tasks/usd-card-inventory.md (T1). Clasica and Tropical sends draw from the owner's own bank-issued USD cards. This migration only
-- TRACKS that inventory (cards, lots bought with USDT, balance, usage of the current Cuba month); nothing consumes it yet (T2/356).
-- A PARALLEL table set to the CUP inventory (239/256): no CUP table or function is read, replaced or altered, so there are no md5 notes.
--   * usd_cards: one bank card per service (CLASICA | TROPICAL, immutable after creation), name (unique among ACTIVE cards per
--     account + service, case-insensitive), optional last4, priority PER SERVICE (lower = used first), monthly_limit_usd (default 5000, the
--     old MLC reference), active flag. Deactivated, never deleted.
--   * usd_lots: one purchase of USD loaded on a card: amount_usd, remaining_usd (0..amount), usdt_paid and the stored rate
--     usd_per_usdt = amount_usd / usdt_paid (500 USD for 476.19 USDT = 1.0500115; 1x1 = 1). FIFO inside a card by loaded_at.
--   * usd_lot_consumptions: what a lot gave out (calculator_entry_id / operation_id nullable, cuba_month = first day of the America/Havana
--     month). kind 'operacion' | 'manual' | 'ajuste' with the 256 sign rule (ajuste rows may be negative = given back, carry no entry /
--     operation reference). Only 'ajuste' rows are written in T1; created now so the report computes month usage.
--   * usd_cuba_month(timestamptz): first day of the Cuba calendar month (America/Havana) of an instant.
--   * RLS: account members SELECT; nobody writes the tables directly. Writes go through admin+ SECURITY DEFINER RPCs, serialized per
--     account by the advisory lock 'usd-inventory:<account>':
--       crm_guardar_tarjeta_usd   create (no card id, service required) or update; NULL keeps the stored value; last4 '' clears it;
--                                 a new card without priority goes last in its service; service cannot change (22023).
--       crm_cargar_lote_usd       load a lot on an ACTIVE card; stores usd_per_usdt; loaded_at defaults to now (at most a day ahead).
--       crm_corregir_lote_usd     change amount / usdt_paid / note while untouched; the rate is recomputed; NULL keeps, note '' clears.
--       crm_eliminar_lote_usd     delete a lot while untouched.
--       crm_ajustar_saldo_usd     set a card's real balance: lower = FIFO positive 'ajuste' rows, higher = newest-first negative rows
--                                 up to each lot's loaded amount, equal = no-op, one remittance_admin_audit row (usd_cards /
--                                 human_correction / balance_usd). Same semantics as crm_ajustar_saldo_cup (256).
--       crm_inventario_usd        the report (jsonb): {cuba_month, cards, totals}. Per card (service, priority, created_at order):
--                                 balance_usd, monthly_limit_usd, used_this_month_usd (kind <> 'ajuste'), remaining_month_usd, every lot
--                                 (FIFO, agotado / adjusted / adjustment_net_usd) and consumptions_month. totals is keyed by service.
--   * Refusals: non-admin 42501; unknown card / lot / foreign account P0002; bad values or a consumed lot 22023.
-- Grants: EXECUTE to authenticated only (REVOKE FROM PUBLIC, anon); no anon access to the tables. No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/usd-card-inventory.sql. ROLLBACK: ROLLBACK-355-usd-card-inventory.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.usd_cuba_month(p_at timestamptz)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT date_trunc('month', p_at AT TIME ZONE 'America/Havana')::date;
$function$;

REVOKE ALL ON FUNCTION public.usd_cuba_month(timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.usd_cuba_month(timestamptz) TO authenticated;
COMMENT ON FUNCTION public.usd_cuba_month(timestamptz) IS
  '(355) First day of the Cuba calendar month (America/Havana) of an instant. The Clasica/Tropical monthly limit resets there.';

CREATE TABLE public.usd_cards (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id         uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  service            text NOT NULL CHECK (service IN ('CLASICA', 'TROPICAL')),
  name               text NOT NULL CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 60),
  last4              text CHECK (last4 ~ '^[0-9]{4}$'),
  priority           integer NOT NULL DEFAULT 1 CHECK (priority BETWEEN 0 AND 100000),
  monthly_limit_usd  numeric NOT NULL DEFAULT 5000 CHECK (monthly_limit_usd > 0 AND monthly_limit_usd < 1e12),
  active             boolean NOT NULL DEFAULT true,
  created_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_by         uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, account_id)
);
CREATE UNIQUE INDEX usd_cards_active_name_uidx ON public.usd_cards (account_id, service, lower(name)) WHERE active;
CREATE INDEX usd_cards_account_priority_idx ON public.usd_cards (account_id, service, priority, created_at);
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.usd_cards FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE public.usd_lots (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id     uuid NOT NULL,
  card_id        uuid NOT NULL,
  amount_usd     numeric NOT NULL CHECK (amount_usd > 0 AND amount_usd < 1e12),
  remaining_usd  numeric NOT NULL CHECK (remaining_usd >= 0),
  usdt_paid      numeric NOT NULL CHECK (usdt_paid > 0 AND usdt_paid < 1e12),
  usd_per_usdt   numeric NOT NULL CHECK (usd_per_usdt > 0),
  loaded_at      timestamptz NOT NULL DEFAULT now(),
  note           text CHECK (length(note) <= 500),
  created_by     uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT usd_lots_remaining_within_amount_chk CHECK (remaining_usd <= amount_usd),
  CONSTRAINT usd_lots_card_fk FOREIGN KEY (card_id, account_id) REFERENCES public.usd_cards (id, account_id) ON DELETE RESTRICT,
  UNIQUE (id, account_id)
);
CREATE INDEX usd_lots_card_fifo_idx ON public.usd_lots (card_id, loaded_at, created_at);
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.usd_lots FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE public.usd_lot_consumptions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id            uuid NOT NULL,
  lot_id                uuid NOT NULL,
  card_id               uuid NOT NULL REFERENCES public.usd_cards(id) ON DELETE RESTRICT,
  calculator_entry_id   uuid REFERENCES remittance_calculator_entries(id) ON DELETE SET NULL,
  operation_id          uuid REFERENCES remittance_operations(id) ON DELETE SET NULL,
  amount_usd            numeric NOT NULL,
  kind                  text NOT NULL DEFAULT 'operacion',
  reason                text,
  consumed_at           timestamptz NOT NULL DEFAULT now(),
  cuba_month            date NOT NULL,
  created_by            uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT usd_lot_consumptions_lot_fk FOREIGN KEY (lot_id, account_id) REFERENCES public.usd_lots (id, account_id) ON DELETE RESTRICT,
  CONSTRAINT usd_lot_consumptions_kind_chk CHECK (kind IN ('operacion', 'manual', 'ajuste')),
  CONSTRAINT usd_lot_consumptions_amount_sign_chk CHECK ((kind = 'ajuste' AND amount_usd <> 0) OR (kind <> 'ajuste' AND amount_usd > 0)),
  CONSTRAINT usd_lot_consumptions_ajuste_refs_chk CHECK (kind <> 'ajuste' OR (calculator_entry_id IS NULL AND operation_id IS NULL)),
  CONSTRAINT usd_lot_consumptions_reason_length_chk CHECK (length(reason) <= 500)
);
CREATE INDEX usd_lot_consumptions_card_month_idx ON public.usd_lot_consumptions (card_id, cuba_month);
CREATE INDEX usd_lot_consumptions_lot_idx ON public.usd_lot_consumptions (lot_id);
CREATE INDEX usd_lot_consumptions_entry_idx ON public.usd_lot_consumptions (calculator_entry_id) WHERE calculator_entry_id IS NOT NULL;
CREATE INDEX usd_lot_consumptions_operation_idx ON public.usd_lot_consumptions (operation_id) WHERE operation_id IS NOT NULL;

ALTER TABLE public.usd_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usd_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.usd_lot_consumptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY usd_cards_select ON public.usd_cards FOR SELECT TO authenticated USING (is_account_member(account_id));
CREATE POLICY usd_lots_select ON public.usd_lots FOR SELECT TO authenticated USING (is_account_member(account_id));
CREATE POLICY usd_lot_consumptions_select ON public.usd_lot_consumptions FOR SELECT TO authenticated USING (is_account_member(account_id));

REVOKE ALL ON public.usd_cards, public.usd_lots, public.usd_lot_consumptions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.usd_cards, public.usd_lots, public.usd_lot_consumptions TO authenticated;

-- ---------------------------------------------------------------------
-- crm_guardar_tarjeta_usd: create (p_card_id NULL) or update a card. The service is fixed at creation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_guardar_tarjeta_usd(
  p_account_id          uuid,
  p_card_id             uuid    DEFAULT NULL,
  p_service             text    DEFAULT NULL,
  p_name                text    DEFAULT NULL,
  p_last4               text    DEFAULT NULL,
  p_priority            integer DEFAULT NULL,
  p_monthly_limit_usd   numeric DEFAULT NULL,
  p_active              boolean DEFAULT NULL
) RETURNS usd_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card     usd_cards;
  v_service  text;
  v_name     text;
  v_last4    text;
  v_priority integer;
  v_limit    numeric;
  v_active   boolean;
BEGIN
  IF p_account_id IS NULL OR NOT is_account_member(p_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the USD inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usd-inventory:' || p_account_id::text, 0));

  IF p_card_id IS NOT NULL THEN
    SELECT * INTO v_card FROM usd_cards WHERE id = p_card_id AND account_id = p_account_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_service IS NOT NULL AND upper(btrim(p_service)) <> v_card.service THEN
      RAISE EXCEPTION 'the service of a card cannot change' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_service := coalesce(v_card.service, upper(btrim(p_service)));
  IF v_service IS NULL OR v_service NOT IN ('CLASICA', 'TROPICAL') THEN
    RAISE EXCEPTION 'service must be CLASICA or TROPICAL' USING ERRCODE = '22023';
  END IF;

  v_name := coalesce(btrim(p_name), v_card.name);
  IF v_name IS NULL OR length(v_name) NOT BETWEEN 1 AND 60 THEN
    RAISE EXCEPTION 'name is required (1 to 60 characters)' USING ERRCODE = '22023';
  END IF;

  IF p_last4 IS NULL THEN
    v_last4 := v_card.last4;
  ELSIF btrim(p_last4) = '' THEN
    v_last4 := NULL;
  ELSIF btrim(p_last4) ~ '^[0-9]{4}$' THEN
    v_last4 := btrim(p_last4);
  ELSE
    RAISE EXCEPTION 'last4 must be exactly 4 digits' USING ERRCODE = '22023';
  END IF;

  IF p_priority IS NOT NULL AND (p_priority < 0 OR p_priority > 100000) THEN
    RAISE EXCEPTION 'priority must be between 0 and 100000' USING ERRCODE = '22023';
  END IF;
  v_priority := coalesce(p_priority, v_card.priority,
                         (SELECT coalesce(max(priority), 0) + 1 FROM usd_cards
                           WHERE account_id = p_account_id AND service = v_service AND active));

  IF p_monthly_limit_usd IS NOT NULL AND NOT (p_monthly_limit_usd > 0 AND p_monthly_limit_usd < 1e12) THEN
    RAISE EXCEPTION 'monthly_limit_usd must be greater than zero' USING ERRCODE = '22023';
  END IF;
  v_limit := coalesce(p_monthly_limit_usd, v_card.monthly_limit_usd, 5000);
  v_active := coalesce(p_active, v_card.active, true);

  IF v_active AND EXISTS (
    SELECT 1 FROM usd_cards c
     WHERE c.account_id = p_account_id AND c.service = v_service AND c.active
       AND lower(c.name) = lower(v_name) AND c.id IS DISTINCT FROM p_card_id
  ) THEN
    RAISE EXCEPTION 'an active card with that name already exists for this service' USING ERRCODE = '22023';
  END IF;

  IF p_card_id IS NULL THEN
    INSERT INTO usd_cards (account_id, service, name, last4, priority, monthly_limit_usd, active, created_by, updated_by)
    VALUES (p_account_id, v_service, v_name, v_last4, v_priority, v_limit, v_active, auth.uid(), auth.uid())
    RETURNING * INTO v_card;
  ELSE
    UPDATE usd_cards
       SET name = v_name, last4 = v_last4, priority = v_priority, monthly_limit_usd = v_limit, active = v_active, updated_by = auth.uid()
     WHERE id = p_card_id
    RETURNING * INTO v_card;
  END IF;

  RETURN v_card;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_cargar_lote_usd: load a lot of USD on an active card.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_cargar_lote_usd(
  p_account_id   uuid,
  p_card_id      uuid,
  p_amount_usd   numeric,
  p_usdt_paid    numeric,
  p_loaded_at    timestamptz DEFAULT NULL,
  p_note         text        DEFAULT NULL
) RETURNS usd_lots
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card usd_cards;
  v_lot  usd_lots;
  v_note text;
BEGIN
  IF p_account_id IS NULL OR NOT is_account_member(p_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the USD inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usd-inventory:' || p_account_id::text, 0));

  SELECT * INTO v_card FROM usd_cards WHERE id = p_card_id AND account_id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT v_card.active THEN
    RAISE EXCEPTION 'the card is inactive' USING ERRCODE = '22023';
  END IF;

  IF p_amount_usd IS NULL OR NOT (p_amount_usd > 0 AND p_amount_usd < 1e12) THEN
    RAISE EXCEPTION 'amount_usd must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF p_usdt_paid IS NULL OR NOT (p_usdt_paid > 0 AND p_usdt_paid < 1e12) THEN
    RAISE EXCEPTION 'usdt_paid must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF p_loaded_at IS NOT NULL AND p_loaded_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'loaded_at cannot be more than a day ahead' USING ERRCODE = '22023';
  END IF;
  v_note := nullif(btrim(p_note), '');
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'note is too long (500 characters at most)' USING ERRCODE = '22023';
  END IF;

  INSERT INTO usd_lots (account_id, card_id, amount_usd, remaining_usd, usdt_paid, usd_per_usdt, loaded_at, note, created_by)
  VALUES (p_account_id, p_card_id, p_amount_usd, p_amount_usd, p_usdt_paid, p_amount_usd / p_usdt_paid,
          coalesce(p_loaded_at, now()), v_note, auth.uid())
  RETURNING * INTO v_lot;

  RETURN v_lot;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_corregir_lote_usd: fix a lot nobody has taken from yet (the rate follows amount / usdt_paid).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_corregir_lote_usd(
  p_lot_id       uuid,
  p_amount_usd   numeric DEFAULT NULL,
  p_usdt_paid    numeric DEFAULT NULL,
  p_note         text    DEFAULT NULL
) RETURNS usd_lots
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_lot     usd_lots;
  v_amount  numeric;
  v_paid    numeric;
  v_note    text;
BEGIN
  SELECT account_id INTO v_account FROM usd_lots WHERE id = p_lot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the USD inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usd-inventory:' || v_account::text, 0));

  SELECT * INTO v_lot FROM usd_lots WHERE id = p_lot_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_lot.remaining_usd <> v_lot.amount_usd OR EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE lot_id = p_lot_id) THEN
    RAISE EXCEPTION 'the lot was already consumed and cannot be corrected' USING ERRCODE = '22023';
  END IF;

  IF p_amount_usd IS NULL AND p_usdt_paid IS NULL AND p_note IS NULL THEN
    RAISE EXCEPTION 'nothing to correct' USING ERRCODE = '22023';
  END IF;
  IF p_amount_usd IS NOT NULL AND NOT (p_amount_usd > 0 AND p_amount_usd < 1e12) THEN
    RAISE EXCEPTION 'amount_usd must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF p_usdt_paid IS NOT NULL AND NOT (p_usdt_paid > 0 AND p_usdt_paid < 1e12) THEN
    RAISE EXCEPTION 'usdt_paid must be greater than zero' USING ERRCODE = '22023';
  END IF;

  v_amount := coalesce(p_amount_usd, v_lot.amount_usd);
  v_paid := coalesce(p_usdt_paid, v_lot.usdt_paid);
  v_note := CASE WHEN p_note IS NULL THEN v_lot.note ELSE nullif(btrim(p_note), '') END;
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'note is too long (500 characters at most)' USING ERRCODE = '22023';
  END IF;

  UPDATE usd_lots
     SET amount_usd = v_amount, remaining_usd = v_amount, usdt_paid = v_paid, usd_per_usdt = v_amount / v_paid, note = v_note
   WHERE id = p_lot_id
  RETURNING * INTO v_lot;

  RETURN v_lot;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_eliminar_lote_usd: delete a lot nobody has taken from yet.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_eliminar_lote_usd(p_lot_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_lot     usd_lots;
BEGIN
  SELECT account_id INTO v_account FROM usd_lots WHERE id = p_lot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the USD inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usd-inventory:' || v_account::text, 0));

  SELECT * INTO v_lot FROM usd_lots WHERE id = p_lot_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_lot.remaining_usd <> v_lot.amount_usd OR EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE lot_id = p_lot_id) THEN
    RAISE EXCEPTION 'the lot was already consumed and cannot be deleted' USING ERRCODE = '22023';
  END IF;

  DELETE FROM usd_lots WHERE id = p_lot_id;
  RETURN p_lot_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_ajustar_saldo_usd: set a card's real balance (same semantics as crm_ajustar_saldo_cup, 256).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_ajustar_saldo_usd(
  p_card_id    uuid,
  p_saldo_usd  numeric,
  p_motivo     text DEFAULT NULL
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card     usd_cards;
  v_lot      usd_lots;
  v_reason   text;
  v_before   numeric;
  v_loaded   numeric;
  v_left     numeric;
  v_take     numeric;
  v_month    date := usd_cuba_month(now());
  v_moves    jsonb := '[]'::jsonb;
BEGIN
  SELECT * INTO v_card FROM usd_cards WHERE id = p_card_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_card.account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the USD inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('usd-inventory:' || v_card.account_id::text, 0));

  IF p_saldo_usd IS NULL OR NOT (p_saldo_usd >= 0 AND p_saldo_usd < 1e12) THEN
    RAISE EXCEPTION 'saldo_usd must be zero or greater' USING ERRCODE = '22023';
  END IF;
  v_reason := nullif(btrim(p_motivo), '');
  IF length(v_reason) > 500 THEN
    RAISE EXCEPTION 'reason is too long (500 characters at most)' USING ERRCODE = '22023';
  END IF;

  -- lock the card's lots in a stable order, then read the totals under the lock
  PERFORM 1 FROM usd_lots WHERE card_id = p_card_id ORDER BY loaded_at, created_at, id FOR UPDATE;
  SELECT coalesce(sum(remaining_usd), 0), coalesce(sum(amount_usd), 0) INTO v_before, v_loaded FROM usd_lots WHERE card_id = p_card_id;

  IF p_saldo_usd > v_loaded THEN
    RAISE EXCEPTION 'the balance cannot exceed what was loaded on the card (% USD): load a new lot', v_loaded USING ERRCODE = '22023';
  END IF;

  IF p_saldo_usd < v_before THEN
    -- LOWER: take the difference FIFO (oldest loaded first), as positive ajuste rows.
    v_left := v_before - p_saldo_usd;
    FOR v_lot IN
      SELECT l.* FROM usd_lots l WHERE l.card_id = p_card_id AND l.remaining_usd > 0 ORDER BY l.loaded_at, l.created_at, l.id
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_lot.remaining_usd, v_left);
      INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, consumed_at, cuba_month, kind, reason, created_by)
      VALUES (v_card.account_id, v_lot.id, p_card_id, v_take, clock_timestamp(), v_month, 'ajuste', v_reason, auth.uid());
      UPDATE usd_lots SET remaining_usd = remaining_usd - v_take WHERE id = v_lot.id;
      v_moves := v_moves || jsonb_build_object('lot_id', v_lot.id, 'amount_usd', v_take);
      v_left := v_left - v_take;
    END LOOP;
  ELSIF p_saldo_usd > v_before THEN
    -- HIGHER: give the difference back newest-first, each lot up to its loaded amount, as NEGATIVE ajuste rows.
    v_left := p_saldo_usd - v_before;
    FOR v_lot IN
      SELECT l.* FROM usd_lots l WHERE l.card_id = p_card_id AND l.remaining_usd < l.amount_usd ORDER BY l.loaded_at DESC, l.created_at DESC, l.id DESC
    LOOP
      EXIT WHEN v_left <= 0;
      v_take := least(v_lot.amount_usd - v_lot.remaining_usd, v_left);
      INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, consumed_at, cuba_month, kind, reason, created_by)
      VALUES (v_card.account_id, v_lot.id, p_card_id, -v_take, clock_timestamp(), v_month, 'ajuste', v_reason, auth.uid());
      UPDATE usd_lots SET remaining_usd = remaining_usd + v_take WHERE id = v_lot.id;
      v_moves := v_moves || jsonb_build_object('lot_id', v_lot.id, 'amount_usd', -v_take);
      v_left := v_left - v_take;
    END LOOP;
  END IF;

  IF jsonb_array_length(v_moves) > 0 THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, reason, before, after)
    VALUES (v_card.account_id, 'usd_cards', p_card_id, 'balance_usd', 'human_correction', wacrm_current_actor(), v_reason,
            jsonb_build_object('balance_usd', v_before),
            jsonb_build_object('balance_usd', p_saldo_usd, 'movimientos', v_moves));
  END IF;

  RETURN jsonb_build_object('card_id', p_card_id, 'saldo_anterior', v_before, 'saldo_nuevo', p_saldo_usd, 'movimientos', v_moves);
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_inventario_usd: the report.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_inventario_usd(p_account_id uuid, p_include_inactive boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_month  date := usd_cuba_month(now());
  v_cards  jsonb;
  v_totals jsonb;
BEGIN
  IF p_account_id IS NULL OR NOT is_account_member(p_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to read the USD inventory' USING ERRCODE = '42501';
  END IF;

  WITH base AS (
    SELECT c.id, c.service, c.priority, c.created_at, c.monthly_limit_usd,
           b.balance, u.used, greatest(c.monthly_limit_usd - u.used, 0) AS remaining_month,
           jsonb_build_object(
             'id', c.id,
             'service', c.service,
             'name', c.name,
             'last4', c.last4,
             'priority', c.priority,
             'active', c.active,
             'monthly_limit_usd', c.monthly_limit_usd,
             'balance_usd', b.balance,
             'used_this_month_usd', u.used,
             'remaining_month_usd', greatest(c.monthly_limit_usd - u.used, 0),
             'lots', coalesce((
               SELECT jsonb_agg(jsonb_build_object(
                        'id', l.id,
                        'amount_usd', l.amount_usd,
                        'remaining_usd', l.remaining_usd,
                        'usdt_paid', l.usdt_paid,
                        'usd_per_usdt', l.usd_per_usdt,
                        'loaded_at', l.loaded_at,
                        'note', l.note,
                        'editable', (l.remaining_usd = l.amount_usd
                                     AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions k WHERE k.lot_id = l.id)),
                        'agotado', (l.remaining_usd = 0),
                        'adjusted', EXISTS (SELECT 1 FROM usd_lot_consumptions k WHERE k.lot_id = l.id AND k.kind = 'ajuste'),
                        'adjustment_net_usd', (SELECT sum(k.amount_usd) FROM usd_lot_consumptions k WHERE k.lot_id = l.id AND k.kind = 'ajuste')
                      ) ORDER BY l.loaded_at, l.created_at, l.id)
                 FROM usd_lots l
                WHERE l.card_id = c.id), '[]'::jsonb),
             'consumptions_month', coalesce((
               SELECT jsonb_agg(jsonb_build_object(
                        'id', m.id,
                        'consumed_at', m.consumed_at,
                        'amount_usd', m.amount_usd,
                        'lot_id', m.lot_id,
                        'lot_usd_per_usdt', m.lot_rate,
                        'operation_id', m.operation_id,
                        'entry_id', m.calculator_entry_id,
                        'source', m.source,
                        'customer_name', m.customer_name,
                        'kind', m.kind,
                        'reason', m.reason
                      ) ORDER BY m.consumed_at DESC, m.id)
                 FROM (
                   SELECT k.id, k.consumed_at, k.amount_usd, k.lot_id, lt.usd_per_usdt AS lot_rate, k.operation_id,
                          k.calculator_entry_id, e.source, e.customer_name, k.kind, k.reason
                     FROM usd_lot_consumptions k
                     JOIN usd_lots lt ON lt.id = k.lot_id
                     LEFT JOIN remittance_calculator_entries e ON e.id = k.calculator_entry_id
                    WHERE k.card_id = c.id AND k.cuba_month = v_month
                    ORDER BY k.consumed_at DESC, k.id
                    LIMIT 100) m), '[]'::jsonb)
           ) AS j
      FROM usd_cards c
      CROSS JOIN LATERAL (SELECT coalesce(sum(l.remaining_usd), 0) AS balance FROM usd_lots l WHERE l.card_id = c.id) b
      CROSS JOIN LATERAL (
        SELECT coalesce(sum(k.amount_usd), 0) AS used
          FROM usd_lot_consumptions k
         WHERE k.card_id = c.id AND k.cuba_month = v_month AND k.kind <> 'ajuste'
      ) u
     WHERE c.account_id = p_account_id AND (c.active OR p_include_inactive)
  )
  SELECT coalesce((SELECT jsonb_agg(base.j ORDER BY base.service, base.priority, base.created_at, base.id) FROM base), '[]'::jsonb),
         (SELECT jsonb_object_agg(s.service, jsonb_build_object(
                   'cards', s.cards,
                   'balance_usd', s.balance,
                   'monthly_limit_usd', s.lim,
                   'used_this_month_usd', s.used,
                   'remaining_month_usd', s.remaining))
            FROM (
              SELECT sv.service, count(base.id) AS cards, coalesce(sum(base.balance), 0) AS balance,
                     coalesce(sum(base.monthly_limit_usd), 0) AS lim, coalesce(sum(base.used), 0) AS used,
                     coalesce(sum(base.remaining_month), 0) AS remaining
                FROM (VALUES ('CLASICA'), ('TROPICAL')) sv(service)
                LEFT JOIN base ON base.service = sv.service
               GROUP BY sv.service) s)
    INTO v_cards, v_totals;

  RETURN jsonb_build_object('cuba_month', v_month, 'cards', v_cards, 'totals', v_totals);
END;
$function$;

REVOKE ALL ON FUNCTION public.crm_guardar_tarjeta_usd(uuid, uuid, text, text, text, integer, numeric, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_cargar_lote_usd(uuid, uuid, numeric, numeric, timestamptz, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_corregir_lote_usd(uuid, numeric, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_eliminar_lote_usd(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_ajustar_saldo_usd(uuid, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_inventario_usd(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_guardar_tarjeta_usd(uuid, uuid, text, text, text, integer, numeric, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_cargar_lote_usd(uuid, uuid, numeric, numeric, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_corregir_lote_usd(uuid, numeric, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_eliminar_lote_usd(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_ajustar_saldo_usd(uuid, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_inventario_usd(uuid, boolean) TO authenticated;

COMMENT ON TABLE public.usd_cards IS '(355) The owner''s Clasica / Tropical USD cards: one service per card, priority per service, monthly limit, never a full card number.';
COMMENT ON TABLE public.usd_lots IS '(355) USD lots loaded on a card with the USDT they cost (usd_per_usdt = amount_usd / usdt_paid); FIFO by loaded_at inside a card.';
COMMENT ON TABLE public.usd_lot_consumptions IS '(355) USD taken from a lot, by Cuba month. kind ajuste = balance adjustment (excluded from the monthly limit; may be negative).';
COMMENT ON FUNCTION public.crm_guardar_tarjeta_usd(uuid, uuid, text, text, text, integer, numeric, boolean) IS
  'Admin+ only. Creates (p_card_id NULL, service required) or updates a USD card; the service never changes; NULL keeps the stored value, last4 '''' clears it.';
COMMENT ON FUNCTION public.crm_cargar_lote_usd(uuid, uuid, numeric, numeric, timestamptz, text) IS
  'Admin+ only. Loads a lot of USD (amount and USDT paid; usd_per_usdt is stored) on an active card.';
COMMENT ON FUNCTION public.crm_corregir_lote_usd(uuid, numeric, numeric, text) IS
  'Admin+ only. Corrects amount / usdt_paid / note of a lot while nothing has been taken from it; the rate is recomputed.';
COMMENT ON FUNCTION public.crm_eliminar_lote_usd(uuid) IS 'Admin+ only. Deletes a lot while nothing has been taken from it.';
COMMENT ON FUNCTION public.crm_ajustar_saldo_usd(uuid, numeric, text) IS
  'Admin+. Sets the card balance: lower = FIFO positive ajuste rows, higher = newest-first negative ajuste rows up to each lot''s loaded amount; audited; never touches the monthly limit.';
COMMENT ON FUNCTION public.crm_inventario_usd(uuid, boolean) IS
  'Admin+ only. {cuba_month, cards, totals}: per card balance, FIFO lots, month usage and remaining month limit; totals keyed by service.';
