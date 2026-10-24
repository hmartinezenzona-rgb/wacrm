-- 309: the WhatsApp rate command appends a calculator version; no-op for non-rate commands.
DO $$
DECLARE
  v_before integer; v_after integer; v_rows integer;
  v_usd numeric; v_mon text; v_fail text := '';
BEGIN
  SELECT count(*) INTO v_before FROM calculator_rate_versions;

  -- A non-rate command (what `liberar` sends) must write nothing.
  SELECT count(*) INTO v_rows FROM cerebro_tasa_whatsapp('5926762167', NULL);
  IF v_rows <> 0 THEN v_fail := v_fail || ' 1:no-op-roto'; END IF;
  IF (SELECT count(*) FROM calculator_rate_versions) <> v_before THEN
    v_fail := v_fail || ' 2:escribio-sin-tasa';
  END IF;

  -- A rate out of range must raise.
  BEGIN
    PERFORM * FROM cerebro_tasa_whatsapp('usd', 5);
    v_fail := v_fail || ' 3:sin-limite';
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- A valid usd rate appends a version with the new usdt_sell_gyd and copies the rest.
  SELECT tasa_cup, moneda INTO v_usd, v_mon FROM cerebro_tasa_whatsapp('usd', 261);
  IF v_mon <> 'usd' OR v_usd <> 261 THEN
    v_fail := v_fail || ' 4:usd=' || coalesce(v_mon, 'null') || '/' || coalesce(v_usd::text, 'null');
  END IF;
  SELECT count(*) INTO v_after FROM calculator_rate_versions;
  IF v_after <> v_before + 1 THEN
    v_fail := v_fail || ' 5:version=' || v_after || '/' || v_before;
  END IF;
  IF (SELECT usdt_sell_gyd FROM calculator_rates_vigentes((SELECT id FROM accounts ORDER BY created_at LIMIT 1))) <> 261 THEN
    v_fail := v_fail || ' 6:vigente';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
