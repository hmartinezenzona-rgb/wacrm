-- 318: both rate jobs run around the clock. Self-reverting.
DO $$
DECLARE
  v_s1 text;
  v_s2 text;
BEGIN
  SELECT schedule INTO v_s1 FROM cron.job WHERE jobname = 'solicitar-tasa-usd-mxn';
  SELECT schedule INTO v_s2 FROM cron.job WHERE jobname = 'procesar-tasa-usd-mxn';
  IF v_s1 IS DISTINCT FROM '*/30 * * * *' THEN RAISE EXCEPTION 'FAIL: solicitar %', v_s1; END IF;
  IF v_s2 IS DISTINCT FROM '2,32 * * * *' THEN RAISE EXCEPTION 'FAIL: procesar %', v_s2; END IF;
  IF (SELECT count(*) FROM cron.job WHERE jobname IN ('solicitar-tasa-usd-mxn', 'procesar-tasa-usd-mxn')) <> 2 THEN
    RAISE EXCEPTION 'FAIL: jobs duplicados o ausentes';
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
