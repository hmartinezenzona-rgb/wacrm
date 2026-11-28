-- 317: the USD-MXN rate is stored net of ARQ's fee. Self-reverting.
DO $$
DECLARE
  v_fail text := '';
  v_pct  text;
  v_e    jsonb;
BEGIN
  SELECT valor INTO v_pct FROM cerebro_config WHERE clave = 'tasa_mxn_comision_pct';
  IF v_pct IS DISTINCT FROM '0.5' THEN v_fail := v_fail || ' 1:config'; END IF;

  -- The owner's own numbers: bid 18.6474810965 minus 0.5% = 18.5542 in ARQ's app.
  IF cerebro_tasa_mxn_neta(18.6474810965, 0.5) <> 18.554244 THEN v_fail := v_fail || ' 2:neta'; END IF;
  IF cerebro_tasa_mxn_neta(18.6474810965, 0) <> 18.647481 THEN v_fail := v_fail || ' 3:sin-comision'; END IF;
  IF cerebro_tasa_mxn_neta(NULL, 0.5) IS NOT NULL THEN v_fail := v_fail || ' 4:nulo'; END IF;

  v_e := cerebro_tasa_usd_mxn_estado();
  IF NOT (v_e ? 'bruto') THEN v_fail := v_fail || ' 5:bruto'; END IF;
  IF NOT (v_e ? 'comision_pct') THEN v_fail := v_fail || ' 6:comision'; END IF;
  IF v_e ? 'valor' AND (v_e->>'valor') IS NOT NULL AND (v_e->>'bruto') IS NOT NULL THEN
    IF (v_e->>'valor')::numeric > (v_e->>'bruto')::numeric THEN v_fail := v_fail || ' 7:neto-mayor'; END IF;
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
