-- =====================================================================
-- 239 -- CUP inventory per sending card: cards, lots, daily limit (staging first)
--
-- odd/tasks/cup-card-inventory.md (T1, phase 1). Owner request (2026-10-14): the profit of a CUP remesa must reflect what that CUP
-- really cost, according to the sending card and the lot it came from. Phase 1 only TRACKS the inventory (cards, lots, balance, the
-- remaining daily limit); nothing deducts from it yet (phase 2) and no existing function is read or replaced.
--   * cup_cards: the owner's own SENDING cards (name + optional last 4 digits, never a full number), a priority (lower = used first;
--     ties break on created_at, so a unique priority is NOT required), a daily limit (default 120,000 CUP) and an active flag. A card is
--     deactivated, never deleted. The name is unique per account among ACTIVE cards (case/space-insensitive).
--   * cup_lots: one purchase of CUP loaded on a card: amount_cup, remaining_cup (0..amount) and the rate it cost, CUP per USDT.
--     FIFO inside a card is by loaded_at (then created_at). The lot's account is forced to its card's by a composite FK.
--   * cup_lot_consumptions: what phase 2 will take from a lot (entry / operation refs nullable, cuba_day = the Cuba day of the take).
--     EMPTY in phase 1, created now so the report can compute the limit used today.
--   * cup_cuba_day(timestamptz): the Cuba calendar day (America/Havana) of an instant. The daily limit resets at midnight CUBA, unlike
--     the rest of the system (Guyana); phase 2 reuses this helper.
--   * RLS: account members SELECT; nobody writes the tables directly (INSERT/UPDATE/DELETE revoked, no policy). Writes go through
--     admin+ SECURITY DEFINER RPCs, serialized per account by the advisory lock 'cup-inventory:<account>':
--       crm_guardar_tarjeta_cup    create (no card id) or update a card; a NULL argument keeps the stored value on update; last4 ''
--                                  clears it; a new card without priority goes last.
--       crm_cargar_lote_cup        load a lot on an ACTIVE card (loaded_at defaults to now(), at most one day ahead).
--       crm_corregir_lote_cup      change amount / rate / note, only while the lot is untouched (remaining = amount and no
--                                  consumption rows); a NULL argument keeps, note '' clears.
--       crm_eliminar_lote_cup      delete a lot, only while untouched.
--       crm_inventario_cup         the report (jsonb): per card in priority order, balance, FIFO lots, used today and the remaining
--                                  limit for the current Cuba day; inactive cards only with p_include_inactive.
--   * Refusals: non-admin 42501; unknown card / lot / foreign account P0002; bad values or a consumed lot 22023.
-- Pre-239: new tables and functions only, nothing replaced, so there are no md5 notes.
-- Grants: EXECUTE to authenticated only (REVOKE FROM PUBLIC, anon); no anon access to the tables. No BEGIN/COMMIT.
-- Guarded by supabase/staging/assertions/cup-card-inventory.sql. ROLLBACK: ROLLBACK-239-cup-card-inventory.sql
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cup_cuba_day(p_at timestamptz)
 RETURNS date
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT (p_at AT TIME ZONE 'America/Havana')::date;
$function$;

REVOKE ALL ON FUNCTION public.cup_cuba_day(timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cup_cuba_day(timestamptz) TO authenticated;
COMMENT ON FUNCTION public.cup_cuba_day(timestamptz) IS
  'The Cuba calendar day (America/Havana) of an instant. The CUP daily limit resets at midnight Cuba, not Guyana.';

CREATE TABLE public.cup_cards (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id       uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name             text NOT NULL CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 60),
  last4            text CHECK (last4 ~ '^[0-9]{4}$'),
  priority         integer NOT NULL DEFAULT 1 CHECK (priority BETWEEN 0 AND 100000),
  daily_limit_cup  numeric NOT NULL DEFAULT 120000 CHECK (daily_limit_cup > 0 AND daily_limit_cup < 1e12),
  active           boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (id, account_id)
);
CREATE UNIQUE INDEX cup_cards_active_name_uidx ON public.cup_cards (account_id, lower(name)) WHERE active;
CREATE INDEX cup_cards_account_priority_idx ON public.cup_cards (account_id, priority, created_at);
CREATE TRIGGER set_updated_at BEFORE UPDATE ON public.cup_cards FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TABLE public.cup_lots (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id          uuid NOT NULL,
  card_id             uuid NOT NULL,
  amount_cup          numeric NOT NULL CHECK (amount_cup > 0 AND amount_cup < 1e12),
  remaining_cup       numeric NOT NULL CHECK (remaining_cup >= 0),
  rate_cup_per_usdt   numeric NOT NULL CHECK (rate_cup_per_usdt > 0 AND rate_cup_per_usdt < 1e9),
  loaded_at           timestamptz NOT NULL DEFAULT now(),
  note                text CHECK (length(note) <= 500),
  created_by          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cup_lots_remaining_within_amount_chk CHECK (remaining_cup <= amount_cup),
  CONSTRAINT cup_lots_card_fk FOREIGN KEY (card_id, account_id) REFERENCES public.cup_cards (id, account_id) ON DELETE RESTRICT,
  UNIQUE (id, account_id)
);
CREATE INDEX cup_lots_card_fifo_idx ON public.cup_lots (card_id, loaded_at, created_at);

CREATE TABLE public.cup_lot_consumptions (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id            uuid NOT NULL,
  lot_id                uuid NOT NULL,
  card_id               uuid NOT NULL REFERENCES public.cup_cards(id) ON DELETE RESTRICT,
  calculator_entry_id   uuid REFERENCES remittance_calculator_entries(id) ON DELETE SET NULL,
  operation_id          uuid REFERENCES remittance_operations(id) ON DELETE SET NULL,
  amount_cup            numeric NOT NULL CHECK (amount_cup > 0),
  consumed_at           timestamptz NOT NULL DEFAULT now(),
  cuba_day              date NOT NULL,
  CONSTRAINT cup_lot_consumptions_lot_fk FOREIGN KEY (lot_id, account_id) REFERENCES public.cup_lots (id, account_id) ON DELETE RESTRICT
);
CREATE INDEX cup_lot_consumptions_card_day_idx ON public.cup_lot_consumptions (card_id, cuba_day);
CREATE INDEX cup_lot_consumptions_lot_idx ON public.cup_lot_consumptions (lot_id);

ALTER TABLE public.cup_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cup_lots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cup_lot_consumptions ENABLE ROW LEVEL SECURITY;
CREATE POLICY cup_cards_select ON public.cup_cards FOR SELECT TO authenticated USING (is_account_member(account_id));
CREATE POLICY cup_lots_select ON public.cup_lots FOR SELECT TO authenticated USING (is_account_member(account_id));
CREATE POLICY cup_lot_consumptions_select ON public.cup_lot_consumptions FOR SELECT TO authenticated USING (is_account_member(account_id));

REVOKE ALL ON public.cup_cards, public.cup_lots, public.cup_lot_consumptions FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.cup_cards, public.cup_lots, public.cup_lot_consumptions TO authenticated;

-- ---------------------------------------------------------------------
-- crm_guardar_tarjeta_cup: create (p_card_id NULL) or update a sending card.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_guardar_tarjeta_cup(
  p_account_id        uuid,
  p_card_id           uuid    DEFAULT NULL,
  p_name              text    DEFAULT NULL,
  p_last4             text    DEFAULT NULL,
  p_priority          integer DEFAULT NULL,
  p_daily_limit_cup   numeric DEFAULT NULL,
  p_active            boolean DEFAULT NULL
) RETURNS cup_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card     cup_cards;
  v_name     text;
  v_last4    text;
  v_priority integer;
  v_limit    numeric;
  v_active   boolean;
BEGIN
  IF p_account_id IS NULL OR NOT is_account_member(p_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the CUP inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || p_account_id::text, 0));

  IF p_card_id IS NOT NULL THEN
    SELECT * INTO v_card FROM cup_cards WHERE id = p_card_id AND account_id = p_account_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
    END IF;
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
                         (SELECT coalesce(max(priority), 0) + 1 FROM cup_cards WHERE account_id = p_account_id AND active));

  IF p_daily_limit_cup IS NOT NULL AND NOT (p_daily_limit_cup > 0 AND p_daily_limit_cup < 1e12) THEN
    RAISE EXCEPTION 'daily_limit_cup must be greater than zero' USING ERRCODE = '22023';
  END IF;
  v_limit := coalesce(p_daily_limit_cup, v_card.daily_limit_cup, 120000);
  v_active := coalesce(p_active, v_card.active, true);

  IF v_active AND EXISTS (
    SELECT 1 FROM cup_cards c
     WHERE c.account_id = p_account_id AND c.active AND lower(c.name) = lower(v_name) AND c.id IS DISTINCT FROM p_card_id
  ) THEN
    RAISE EXCEPTION 'an active card with that name already exists' USING ERRCODE = '22023';
  END IF;

  IF p_card_id IS NULL THEN
    INSERT INTO cup_cards (account_id, name, last4, priority, daily_limit_cup, active)
    VALUES (p_account_id, v_name, v_last4, v_priority, v_limit, v_active)
    RETURNING * INTO v_card;
  ELSE
    UPDATE cup_cards
       SET name = v_name, last4 = v_last4, priority = v_priority, daily_limit_cup = v_limit, active = v_active
     WHERE id = p_card_id
    RETURNING * INTO v_card;
  END IF;

  RETURN v_card;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_cargar_lote_cup: load a lot of CUP on an active card.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_cargar_lote_cup(
  p_account_id          uuid,
  p_card_id             uuid,
  p_amount_cup          numeric,
  p_rate_cup_per_usdt   numeric,
  p_note                text        DEFAULT NULL,
  p_loaded_at           timestamptz DEFAULT NULL
) RETURNS cup_lots
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_card cup_cards;
  v_lot  cup_lots;
  v_note text;
BEGIN
  IF p_account_id IS NULL OR NOT is_account_member(p_account_id, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the CUP inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || p_account_id::text, 0));

  SELECT * INTO v_card FROM cup_cards WHERE id = p_card_id AND account_id = p_account_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'card not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT v_card.active THEN
    RAISE EXCEPTION 'the card is inactive' USING ERRCODE = '22023';
  END IF;

  IF p_amount_cup IS NULL OR NOT (p_amount_cup > 0 AND p_amount_cup < 1e12) THEN
    RAISE EXCEPTION 'amount_cup must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF p_rate_cup_per_usdt IS NULL OR NOT (p_rate_cup_per_usdt > 0 AND p_rate_cup_per_usdt < 1e9) THEN
    RAISE EXCEPTION 'rate_cup_per_usdt must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF p_loaded_at IS NOT NULL AND p_loaded_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'loaded_at cannot be more than a day ahead' USING ERRCODE = '22023';
  END IF;
  v_note := nullif(btrim(p_note), '');
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'note is too long (500 characters at most)' USING ERRCODE = '22023';
  END IF;

  INSERT INTO cup_lots (account_id, card_id, amount_cup, remaining_cup, rate_cup_per_usdt, loaded_at, note, created_by)
  VALUES (p_account_id, p_card_id, p_amount_cup, p_amount_cup, p_rate_cup_per_usdt, coalesce(p_loaded_at, now()), v_note, auth.uid())
  RETURNING * INTO v_lot;

  RETURN v_lot;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_corregir_lote_cup: fix a lot nobody has taken from yet.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_corregir_lote_cup(
  p_lot_id              uuid,
  p_amount_cup          numeric DEFAULT NULL,
  p_rate_cup_per_usdt   numeric DEFAULT NULL,
  p_note                text    DEFAULT NULL
) RETURNS cup_lots
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_lot     cup_lots;
  v_amount  numeric;
  v_rate    numeric;
  v_note    text;
BEGIN
  SELECT account_id INTO v_account FROM cup_lots WHERE id = p_lot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the CUP inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || v_account::text, 0));

  SELECT * INTO v_lot FROM cup_lots WHERE id = p_lot_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_lot.remaining_cup <> v_lot.amount_cup OR EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE lot_id = p_lot_id) THEN
    RAISE EXCEPTION 'the lot was already consumed and cannot be corrected' USING ERRCODE = '22023';
  END IF;

  IF p_amount_cup IS NULL AND p_rate_cup_per_usdt IS NULL AND p_note IS NULL THEN
    RAISE EXCEPTION 'nothing to correct' USING ERRCODE = '22023';
  END IF;
  IF p_amount_cup IS NOT NULL AND NOT (p_amount_cup > 0 AND p_amount_cup < 1e12) THEN
    RAISE EXCEPTION 'amount_cup must be greater than zero' USING ERRCODE = '22023';
  END IF;
  IF p_rate_cup_per_usdt IS NOT NULL AND NOT (p_rate_cup_per_usdt > 0 AND p_rate_cup_per_usdt < 1e9) THEN
    RAISE EXCEPTION 'rate_cup_per_usdt must be greater than zero' USING ERRCODE = '22023';
  END IF;

  v_amount := coalesce(p_amount_cup, v_lot.amount_cup);
  v_rate := coalesce(p_rate_cup_per_usdt, v_lot.rate_cup_per_usdt);
  v_note := CASE WHEN p_note IS NULL THEN v_lot.note ELSE nullif(btrim(p_note), '') END;
  IF length(v_note) > 500 THEN
    RAISE EXCEPTION 'note is too long (500 characters at most)' USING ERRCODE = '22023';
  END IF;

  UPDATE cup_lots
     SET amount_cup = v_amount, remaining_cup = v_amount, rate_cup_per_usdt = v_rate, note = v_note
   WHERE id = p_lot_id
  RETURNING * INTO v_lot;

  RETURN v_lot;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_eliminar_lote_cup: delete a lot nobody has taken from yet.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.crm_eliminar_lote_cup(p_lot_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account uuid;
  v_lot     cup_lots;
BEGIN
  SELECT account_id INTO v_account FROM cup_lots WHERE id = p_lot_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF NOT is_account_member(v_account, 'admin'::account_role_enum) THEN
    RAISE EXCEPTION 'not authorized to manage the CUP inventory' USING ERRCODE = '42501';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('cup-inventory:' || v_account::text, 0));

  SELECT * INTO v_lot FROM cup_lots WHERE id = p_lot_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lot not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_lot.remaining_cup <> v_lot.amount_cup OR EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE lot_id = p_lot_id) THEN
    RAISE EXCEPTION 'the lot was already consumed and cannot be deleted' USING ERRCODE = '22023';
  END IF;

  DELETE FROM cup_lots WHERE id = p_lot_id;
  RETURN p_lot_id;
END;
$function$;

-- ---------------------------------------------------------------------
-- crm_inventario_cup: the report.
-- ---------------------------------------------------------------------
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

REVOKE ALL ON FUNCTION public.crm_guardar_tarjeta_cup(uuid, uuid, text, text, integer, numeric, boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_cargar_lote_cup(uuid, uuid, numeric, numeric, text, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_corregir_lote_cup(uuid, numeric, numeric, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_eliminar_lote_cup(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crm_inventario_cup(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crm_guardar_tarjeta_cup(uuid, uuid, text, text, integer, numeric, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_cargar_lote_cup(uuid, uuid, numeric, numeric, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_corregir_lote_cup(uuid, numeric, numeric, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_eliminar_lote_cup(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.crm_inventario_cup(uuid, boolean) TO authenticated;

COMMENT ON TABLE public.cup_cards IS '(239) The owner''s CUP sending cards: priority order, daily limit, never a full card number.';
COMMENT ON TABLE public.cup_lots IS '(239) CUP lots loaded on a card with the rate they cost (CUP per USDT); FIFO by loaded_at inside a card.';
COMMENT ON TABLE public.cup_lot_consumptions IS '(239) CUP taken from a lot, by Cuba day. Empty in phase 1; phase 2 writes it.';
COMMENT ON FUNCTION public.crm_guardar_tarjeta_cup(uuid, uuid, text, text, integer, numeric, boolean) IS
  'Admin+ only. Creates (p_card_id NULL) or updates a CUP sending card; NULL keeps the stored value, last4 '''' clears it.';
COMMENT ON FUNCTION public.crm_cargar_lote_cup(uuid, uuid, numeric, numeric, text, timestamptz) IS
  'Admin+ only. Loads a lot of CUP (amount and purchase rate, CUP per USDT) on an active card.';
COMMENT ON FUNCTION public.crm_corregir_lote_cup(uuid, numeric, numeric, text) IS
  'Admin+ only. Corrects amount/rate/note of a lot while nothing has been taken from it.';
COMMENT ON FUNCTION public.crm_eliminar_lote_cup(uuid) IS 'Admin+ only. Deletes a lot while nothing has been taken from it.';
COMMENT ON FUNCTION public.crm_inventario_cup(uuid, boolean) IS
  'Admin+ only. Per card in priority order: balance, FIFO lots, used today and remaining limit for the current Cuba day.';
