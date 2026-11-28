-- =====================================================================
-- 309 -- The WhatsApp "tasa" command writes to the calculator again
--
-- The Cerebro node "Liberar chat" runs one statement with CTEs for `liberar`, `tasa` and `ver_tasas`, and its
-- `nueva_tasa` CTE still did INSERT INTO tasas. Since 113 `tasas` is a UNION view over calculator_rate_versions,
-- so Postgres rejects the whole statement at plan time ("cannot insert into view") and even `liberar` fails.
--
-- cerebro_tasa_whatsapp appends a calculator rate version (copying the current one) with the new value:
--   * 'usd' -> usdt_sell_gyd (GYD per USD, the 260-shaped rate);
--   * 'gyd' -> cup_global_rate.
-- It returns no rows for a missing/unknown currency so the same CTE can live beside `liberar` without side
-- effects, and raises only when a real 'tasa' value is out of the sane range.
-- Assertion: supabase/staging/assertions/tasa-whatsapp.sql. Rollback: ROLLBACK-309-tasa-whatsapp.sql.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cerebro_tasa_whatsapp(p_moneda text, p_valor numeric)
RETURNS TABLE(moneda text, tasa_cup numeric)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_mon text := lower(btrim(coalesce(p_moneda, '')));
  v_acc uuid;
  v_cur public.calculator_rate_versions;
  v_new public.calculator_rate_versions;
BEGIN
  -- Empty, unknown or missing value: this CTE never fires (it runs beside `liberar`).
  IF v_mon NOT IN ('gyd', 'usd') OR p_valor IS NULL THEN
    RETURN;
  END IF;

  IF (v_mon = 'gyd' AND p_valor NOT BETWEEN 0.5 AND 10)
     OR (v_mon = 'usd' AND p_valor NOT BETWEEN 150 AND 500) THEN
    RAISE EXCEPTION 'tasa fuera de rango: % %', v_mon, p_valor USING ERRCODE = '22023';
  END IF;

  SELECT a.id INTO v_acc FROM public.accounts a ORDER BY a.created_at LIMIT 1;
  IF v_acc IS NULL THEN
    RAISE EXCEPTION 'no hay cuenta para escribir la tasa' USING ERRCODE = '22023';
  END IF;

  v_cur := public.calculator_rates_vigentes(v_acc);

  INSERT INTO public.calculator_rate_versions (
    account_id, cup_global_rate, usdt_buy_gyd, usdt_sell_gyd, usdt_sell_cup, efectivo_usd_gyd,
    recarga_costo_usdt, saldo_costo_usdt, zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000,
    recarga_costo_usdt_500, set_by
  ) VALUES (
    v_acc,
    CASE WHEN v_mon = 'gyd' THEN p_valor ELSE v_cur.cup_global_rate END,
    v_cur.usdt_buy_gyd,
    CASE WHEN v_mon = 'usd' THEN p_valor ELSE v_cur.usdt_sell_gyd END,
    v_cur.usdt_sell_cup,
    v_cur.efectivo_usd_gyd,
    v_cur.recarga_costo_usdt,
    v_cur.saldo_costo_usdt,
    v_cur.zelle_sell_gyd,
    v_cur.zelle_sell_gyd_1000,
    v_cur.zelle_sell_gyd_2000,
    v_cur.recarga_costo_usdt_500,
    NULL
  )
  RETURNING * INTO v_new;

  RETURN QUERY SELECT
    v_mon,
    CASE WHEN v_mon = 'usd' THEN v_new.usdt_sell_gyd ELSE v_new.cup_global_rate END;
END;
$function$;

COMMENT ON FUNCTION public.cerebro_tasa_whatsapp(text, numeric) IS
  'Appends a calculator rate version from the WhatsApp admin command (usd -> usdt_sell_gyd, gyd -> '
  'cup_global_rate). Returns no rows when the command is not a rate; 113 made tasas a UNION view, so the old '
  'INSERT INTO tasas could not work.';

REVOKE ALL ON FUNCTION public.cerebro_tasa_whatsapp(text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cerebro_tasa_whatsapp(text, numeric) TO service_role;
