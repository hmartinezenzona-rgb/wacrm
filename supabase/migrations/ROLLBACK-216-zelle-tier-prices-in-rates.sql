-- ROLLBACK of 216_zelle_tier_prices_in_rates.sql: restores crm_set_calculator_rates, cerebro_zelle_cotizar_gyd and cerebro_tasa_zelle exactly as before 216
-- (pg_get_functiondef md5 on staging, 2026-10-05: crm_set_calculator_rates 019e7e7663f2ec71f1a57483d9a7c862, cerebro_zelle_cotizar_gyd 708f51e60d9c74be6b852a4e647d073f, cerebro_tasa_zelle 379775ef768bc4241c11dfa8efd0f40d;
-- cerebro_zelle_usd_desde_gyd 8fa6f69dcdeacddca64b3238f3fdbeff was not touched), drops cerebro_zelle_tiers and the three Zelle price columns, and restores the cerebro_config 'zelle_tiers' setting.
-- Rate versions are append-only: the version 216 appended to seed the prices stays (same rates as the one before it, without the three columns). Zelle pricing returns to the 215 configuration (260/250/245);
-- prices an admin typed in the meantime are lost with the columns. Entries already written keep their stored figures.
INSERT INTO cerebro_config (clave, valor, descripcion) VALUES
  ('zelle_tiers', '[{"min_usd":50,"rate_gyd":260},{"min_usd":1000,"rate_gyd":250},{"min_usd":2000,"rate_gyd":245}]',
   'Zelle sale rate by tier of USD received: [{min_usd, rate_gyd}]. 260 for 50-999 USD, 250 for 1,000-1,999, 245 from 2,000 (215).')
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION public.cerebro_tasa_zelle(p_usd numeric)
 RETURNS numeric
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tiers jsonb;
  v_rate  numeric;
BEGIN
  IF p_usd IS NULL OR p_usd <= 0 THEN RETURN NULL; END IF;
  BEGIN
    v_tiers := NULLIF(cerebro_config_get('zelle_tiers'), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN v_tiers := NULL;
  END;
  IF v_tiers IS NOT NULL AND jsonb_typeof(v_tiers) = 'array' AND jsonb_array_length(v_tiers) > 0 THEN
    SELECT t.rate_gyd INTO v_rate
      FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
     WHERE t.rate_gyd > 0 AND p_usd >= t.min_usd
     ORDER BY t.min_usd DESC LIMIT 1;
    IF v_rate IS NULL THEN
      SELECT t.rate_gyd INTO v_rate
        FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
       WHERE t.rate_gyd > 0 ORDER BY t.min_usd ASC LIMIT 1;
    END IF;
  END IF;
  RETURN coalesce(v_rate, crm_tasa_vigente('usd'));
END $function$
;
CREATE OR REPLACE FUNCTION public.cerebro_zelle_cotizar_gyd(p_gyd numeric)
 RETURNS TABLE(usd numeric, tasa numeric)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_tiers jsonb;
  v_rate  numeric;
BEGIN
  IF p_gyd IS NULL OR p_gyd <= 0 THEN RETURN; END IF;
  BEGIN
    v_tiers := NULLIF(cerebro_config_get('zelle_tiers'), '')::jsonb;
  EXCEPTION WHEN OTHERS THEN v_tiers := NULL;
  END;
  IF v_tiers IS NOT NULL AND jsonb_typeof(v_tiers) = 'array' AND jsonb_array_length(v_tiers) > 0 THEN
    SELECT t.rate_gyd INTO v_rate
      FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
     WHERE t.rate_gyd > 0 AND floor(p_gyd / t.rate_gyd) >= t.min_usd
     ORDER BY t.min_usd DESC LIMIT 1;
    IF v_rate IS NULL THEN
      SELECT t.rate_gyd INTO v_rate
        FROM jsonb_to_recordset(v_tiers) AS t(min_usd numeric, rate_gyd numeric)
       WHERE t.rate_gyd > 0 ORDER BY t.min_usd ASC LIMIT 1;
    END IF;
  END IF;
  v_rate := coalesce(v_rate, crm_tasa_vigente('usd'));
  IF v_rate IS NULL OR v_rate <= 0 THEN RETURN; END IF;
  RETURN QUERY SELECT floor(p_gyd / v_rate), v_rate;
END $function$
;
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
                     'recarga_costo_usdt') THEN
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
    recarga_costo_usdt, set_by
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
    auth.uid()
  )
  RETURNING * INTO v_new;

  RETURN v_new;
END;
$function$
;

DROP FUNCTION IF EXISTS public.cerebro_zelle_tiers();
ALTER TABLE calculator_rate_versions
  DROP CONSTRAINT IF EXISTS calculator_rate_versions_zelle_sell_gyd_chk,
  DROP CONSTRAINT IF EXISTS calculator_rate_versions_zelle_sell_gyd_1000_chk,
  DROP CONSTRAINT IF EXISTS calculator_rate_versions_zelle_sell_gyd_2000_chk;
ALTER TABLE calculator_rate_versions
  DROP COLUMN IF EXISTS zelle_sell_gyd,
  DROP COLUMN IF EXISTS zelle_sell_gyd_1000,
  DROP COLUMN IF EXISTS zelle_sell_gyd_2000;
DELETE FROM supabase_migrations.schema_migrations WHERE version = '216';
