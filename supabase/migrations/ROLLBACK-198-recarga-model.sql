-- ROLLBACK of 198_recarga_model.sql. Fails on purpose while 'recarga' beneficiaries exist (the CHECK rejects them).
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
    IF v_key NOT IN ('cup_global_rate', 'usdt_buy_gyd', 'usdt_sell_gyd', 'usdt_sell_cup', 'efectivo_usd_gyd') THEN
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
    account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, efectivo_usd_gyd, set_by
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
    AND status = 'vigente';
$function$;

ALTER TABLE public.remittance_beneficiaries DROP CONSTRAINT rb_type_chk;
ALTER TABLE public.remittance_beneficiaries ADD CONSTRAINT rb_type_chk
  CHECK (beneficiary_type = ANY (ARRAY['cuban_card', 'zelle', 'clasica', 'tropical', 'multiple_distribution', 'efectivo_usd']));
ALTER TABLE public.calculator_rate_versions DROP COLUMN IF EXISTS recarga_precio_gyd, DROP COLUMN IF EXISTS recarga_costo_usdt;
