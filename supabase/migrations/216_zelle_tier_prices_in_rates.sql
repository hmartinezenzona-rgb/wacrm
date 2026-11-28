-- =====================================================================
-- 216 -- Zelle tier prices live in the calculator rate versions (staging first)
--
-- odd/tasks/zelle-tiered-rate.md (T1b). Owner decision (2026-10-05): rates vary, so the three Zelle prices are edited in the
-- Calculator like the other rates, not in cerebro_config. 215 stored them as cerebro_config 'zelle_tiers'; this moves them
-- into calculator_rate_versions (append-only, admin-only through crm_set_calculator_rates, optimistic lock).
--
-- The tier MINIMUMS stay fixed (50, 1,000 and 2,000 USD, owner). Only the prices are data:
--   zelle_sell_gyd        price for the tier that starts at 50 USD (base tier)
--   zelle_sell_gyd_1000   price for the tier that starts at 1,000 USD
--   zelle_sell_gyd_2000   price for the tier that starts at 2,000 USD
-- All three are nullable. FALLBACK when a price is NULL (documented, also mirrored by document-rates.ts):
--   base tier   -> usdt_sell_gyd (crm_tasa_vigente('usd'), the single rate Zelle used before 215)
--   1,000 tier  -> the base tier's resolved price
--   2,000 tier  -> the 1,000 tier's resolved price
-- so an account that never set Zelle prices keeps pricing Zelle at the single rate, with no discount.
--
-- NEW: cerebro_zelle_tiers() -> (min_usd, rate_gyd), the one reader of the prices (current version, fallback applied).
-- REDEFINED: cerebro_zelle_cotizar_gyd and cerebro_tasa_zelle (now read cerebro_zelle_tiers; same selection rule as 215),
-- crm_set_calculator_rates (accepts the three keys). Unchanged: cerebro_zelle_usd_desde_gyd, every Zelle reader switched
-- in 215, calculator_missing_rates (a Zelle line is never pending for lack of a Zelle price: the fallback prices it),
-- the `tasas` view (Zelle prices are not part of the single rate).
-- REMOVED: cerebro_config 'zelle_tiers' (one source of truth; the rollback restores it).
-- SEED: the current version of every account that has none of the three prices gets a NEW version (calculator_rate_versions
-- is append-only) carrying forward its rates plus 260 / 250 / 245, so the staging behaviour is unchanged.
--
-- Guarded by supabase/staging/assertions/zelle-tier-prices.sql (and zelle-tiered-rate.sql, still green)
-- ROLLBACK: ROLLBACK-216-zelle-tier-prices-in-rates.sql
-- =====================================================================

ALTER TABLE calculator_rate_versions
  ADD COLUMN IF NOT EXISTS zelle_sell_gyd      numeric,
  ADD COLUMN IF NOT EXISTS zelle_sell_gyd_1000 numeric,
  ADD COLUMN IF NOT EXISTS zelle_sell_gyd_2000 numeric;

ALTER TABLE calculator_rate_versions
  ADD CONSTRAINT calculator_rate_versions_zelle_sell_gyd_chk
    CHECK (zelle_sell_gyd IS NULL OR (zelle_sell_gyd > 0 AND zelle_sell_gyd < 1e9)),
  ADD CONSTRAINT calculator_rate_versions_zelle_sell_gyd_1000_chk
    CHECK (zelle_sell_gyd_1000 IS NULL OR (zelle_sell_gyd_1000 > 0 AND zelle_sell_gyd_1000 < 1e9)),
  ADD CONSTRAINT calculator_rate_versions_zelle_sell_gyd_2000_chk
    CHECK (zelle_sell_gyd_2000 IS NULL OR (zelle_sell_gyd_2000 > 0 AND zelle_sell_gyd_2000 < 1e9));

COMMENT ON COLUMN calculator_rate_versions.zelle_sell_gyd IS
  'Zelle sale price (GYD per USD) of the tier that starts at 50 USD. NULL falls back to usdt_sell_gyd (216).';
COMMENT ON COLUMN calculator_rate_versions.zelle_sell_gyd_1000 IS
  'Zelle sale price of the tier that starts at 1,000 USD. NULL falls back to the base tier price (216).';
COMMENT ON COLUMN calculator_rate_versions.zelle_sell_gyd_2000 IS
  'Zelle sale price of the tier that starts at 2,000 USD. NULL falls back to the 1,000 tier price (216).';

-- The tiers in force: fixed minimums, prices from the newest rate version (carried forward by crm_set_calculator_rates),
-- fallbacks applied. No rows when not even the single rate exists. service_role only, like the other cerebro helpers.
CREATE OR REPLACE FUNCTION public.cerebro_zelle_tiers()
RETURNS TABLE(min_usd numeric, rate_gyd numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v  calculator_rate_versions;
  r1 numeric;
  r2 numeric;
  r3 numeric;
BEGIN
  SELECT * INTO v FROM calculator_rate_versions ORDER BY effective_at DESC, id DESC LIMIT 1;
  r1 := coalesce(v.zelle_sell_gyd, crm_tasa_vigente('usd'));
  IF r1 IS NULL OR r1 <= 0 THEN RETURN; END IF;
  r2 := coalesce(v.zelle_sell_gyd_1000, r1);
  r3 := coalesce(v.zelle_sell_gyd_2000, r2);
  RETURN QUERY VALUES (50::numeric, r1), (1000::numeric, r2), (2000::numeric, r3);
END $function$;

REVOKE ALL ON FUNCTION public.cerebro_zelle_tiers() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_zelle_tiers() TO service_role;

-- Tier of a deposit in GYD: the best tier whose floor(gyd / price) reaches its minimum USD; below the lowest tier, the
-- lowest tier's price. Returns the USD (whole units, rounded DOWN) and the rate. No row for a missing or non-positive
-- deposit, or when no rate exists at all.
CREATE OR REPLACE FUNCTION public.cerebro_zelle_cotizar_gyd(p_gyd numeric)
RETURNS TABLE(usd numeric, tasa numeric)
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rate numeric;
BEGIN
  IF p_gyd IS NULL OR p_gyd <= 0 THEN RETURN; END IF;
  SELECT t.rate_gyd INTO v_rate FROM cerebro_zelle_tiers() t
   WHERE floor(p_gyd / t.rate_gyd) >= t.min_usd ORDER BY t.min_usd DESC LIMIT 1;
  IF v_rate IS NULL THEN
    SELECT t.rate_gyd INTO v_rate FROM cerebro_zelle_tiers() t ORDER BY t.min_usd ASC LIMIT 1;
  END IF;
  IF v_rate IS NULL OR v_rate <= 0 THEN RETURN; END IF;
  RETURN QUERY SELECT floor(p_gyd / v_rate), v_rate;
END $function$;

-- Rate for an amount of USD received (the customer asks for N USD): the highest tier N reaches; below the lowest tier,
-- the lowest tier's price.
CREATE OR REPLACE FUNCTION public.cerebro_tasa_zelle(p_usd numeric)
RETURNS numeric
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_rate numeric;
BEGIN
  IF p_usd IS NULL OR p_usd <= 0 THEN RETURN NULL; END IF;
  SELECT t.rate_gyd INTO v_rate FROM cerebro_zelle_tiers() t
   WHERE p_usd >= t.min_usd ORDER BY t.min_usd DESC LIMIT 1;
  IF v_rate IS NULL THEN
    SELECT t.rate_gyd INTO v_rate FROM cerebro_zelle_tiers() t ORDER BY t.min_usd ASC LIMIT 1;
  END IF;
  RETURN v_rate;
END $function$;

-- The only write path accepts the three prices (same validation, carried forward when absent, NULL clears).
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
                     'recarga_costo_usdt', 'zelle_sell_gyd', 'zelle_sell_gyd_1000', 'zelle_sell_gyd_2000') THEN
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
    recarga_costo_usdt, zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000, set_by
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

-- Seed: one new version per account whose current version has no Zelle price, carrying every rate forward.
INSERT INTO calculator_rate_versions (account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup,
                                      efectivo_usd_gyd, recarga_costo_usdt, zelle_sell_gyd, zelle_sell_gyd_1000,
                                      zelle_sell_gyd_2000, set_by)
SELECT c.account_id, c.cup_global_rate, c.usdt_buy_gyd, c.usdt_sell_gyd, c.usdt_sell_cup, c.efectivo_usd_gyd,
       c.recarga_costo_usdt, 260, 250, 245, NULL
  FROM (SELECT DISTINCT account_id FROM calculator_rate_versions) a,
       LATERAL calculator_rates_vigentes(a.account_id) c
 WHERE c.zelle_sell_gyd IS NULL AND c.zelle_sell_gyd_1000 IS NULL AND c.zelle_sell_gyd_2000 IS NULL;

-- One source of truth: the 215 configuration is gone.
DELETE FROM cerebro_config WHERE clave = 'zelle_tiers';
