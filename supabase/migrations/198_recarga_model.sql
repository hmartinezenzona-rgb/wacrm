-- =====================================================================
-- 198 — The recharge data model (staging first)
--
-- odd/tasks/panel-other-services.md (R1). Owner, 2026-10-03: recharges are sold on Etecsa promotions, ONE at a time;
-- the price follows the promotion's main balance (500 CUP -> 5,200 GYD, 600 CUP -> 6,200 GYD); one Cuban number per
-- recharge; the cost per recharge is in USDT (the calculator guide's example: 23.1 USDT at 242 GYD/USDT; the admin
-- confirms the figures). So:
--   - calculator_rate_versions gains recarga_precio_gyd (the current promotion's price; NULL = no promotion now) and
--     recarga_costo_usdt; crm_set_calculator_rates accepts both (one place, like efectivo_usd_gyd);
--   - beneficiary type 'recarga' (one row per number, the number in phone);
--   - crm_beneficiarios_completos: for a service_type 'recarga' operation, every current row is a 'recarga' with a
--     valid Cuban mobile and there are as many as recharges (deposit / price; with no price, at least one). Every other
--     operation keeps the 188 rule.
-- New rows only seed nothing: the owner sets the price and the cost in the Calculator.
--
-- Guarded by supabase/staging/assertions/recarga-model.sql.
-- ROLLBACK: ROLLBACK-198-recarga-model.sql
-- =====================================================================
ALTER TABLE public.calculator_rate_versions
  ADD COLUMN IF NOT EXISTS recarga_precio_gyd numeric CHECK (recarga_precio_gyd IS NULL OR (recarga_precio_gyd > 0 AND recarga_precio_gyd < 1e9)),
  ADD COLUMN IF NOT EXISTS recarga_costo_usdt numeric CHECK (recarga_costo_usdt IS NULL OR (recarga_costo_usdt > 0 AND recarga_costo_usdt < 1e6));
COMMENT ON COLUMN public.calculator_rate_versions.recarga_precio_gyd IS '198. GYD price of one recharge on the current Etecsa promotion (5,200 for 500 CUP, 6,200 for 600 CUP); NULL = no promotion now.';
COMMENT ON COLUMN public.calculator_rate_versions.recarga_costo_usdt IS '198. Cost of one recharge in USDT (priced in GYD with usdt_buy_gyd).';

ALTER TABLE public.remittance_beneficiaries DROP CONSTRAINT rb_type_chk;
ALTER TABLE public.remittance_beneficiaries ADD CONSTRAINT rb_type_chk
  CHECK (beneficiary_type = ANY (ARRAY['cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'efectivo_usd', 'recarga']));

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
                     'recarga_precio_gyd', 'recarga_costo_usdt') THEN
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
    recarga_precio_gyd, recarga_costo_usdt, set_by
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
    -- (198) The current recharge promotion's price (NULL = no promotion now) and the cost per recharge in USDT.
    CASE WHEN p_rates ? 'recarga_precio_gyd'
         THEN (p_rates ->> 'recarga_precio_gyd')::numeric ELSE v_current.recarga_precio_gyd END,
    CASE WHEN p_rates ? 'recarga_costo_usdt'
         THEN (p_rates ->> 'recarga_costo_usdt')::numeric ELSE v_current.recarga_costo_usdt END,
    auth.uid()
  )
  RETURNING * INTO v_new;

  RETURN v_new;
END;
$function$;

CREATE OR REPLACE FUNCTION public.crm_beneficiarios_completos(p_operation_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  -- (198) A recharge: every current row is a 'recarga' with a valid Cuban mobile, and there are as many as
  -- recharges (deposit / the current promotion's price; with no price set, at least one).
  SELECT coalesce((SELECT CASE WHEN o.service_type = 'recarga' THEN
           (SELECT count(*) > 0
                   AND bool_and(b.beneficiary_type = 'recarga'
                                AND coalesce(cerebro_norm_celular_cu(b.phone), '') ~ '^[0-9]{8}$')
                   AND count(*) >= coalesce(floor(o.quoted_source_amount
                                                  / NULLIF((calculator_rates_vigentes(o.account_id)).recarga_precio_gyd, 0)), 0)
              FROM remittance_beneficiaries b
             WHERE b.operation_id = o.id AND b.status = 'vigente')
         ELSE (
    SELECT
      count(*) > 0
      AND bool_and(
        CASE
          WHEN beneficiary_type = 'zelle' THEN
            btrim(coalesce(name, '')) <> '' AND btrim(coalesce(zelle_account, '')) <> ''
          -- (188) A cash recipient has no card: phone, address and ID-card photo (150).
          WHEN beneficiary_type = 'efectivo_usd' THEN
            btrim(coalesce(phone, '')) <> '' AND btrim(coalesce(address, '')) <> ''
            AND btrim(coalesce(id_photo_wamid, '')) <> ''
          ELSE
            btrim(coalesce(card_number, '')) <> '' AND btrim(coalesce(phone, '')) <> ''
        END
      )
    FROM remittance_beneficiaries
    WHERE operation_id = p_operation_id
      AND status = 'vigente'
         ) END
    FROM remittance_operations o
   WHERE o.id = p_operation_id), false);
$function$;
