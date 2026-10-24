-- 297: USD -> MXN parsers, storage rules and the cron jobs.
-- Real payload shapes: ARQ's ticker (source of truth) and open.er-api.com (daily fallback).
DO $$
DECLARE
  v_arq text := '[{"ask":"18.6697421235","bid":"18.6474810965","book":"usdc_mxn","date":"2026-10-24T15:05:05.469408781"}]';
  v_erapi text := '{"amount":1.0,"base":"USD","date":"2026-10-23","rates":{"MXN":18.7823}}';
  v_fail text := '';
  v_latest numeric;
BEGIN
  IF cerebro_parsear_tasa_arq(v_arq::jsonb) IS DISTINCT FROM 18.6474810965 THEN
    v_fail := v_fail || ' 1:arq-bid';
  END IF;
  IF cerebro_parsear_tasa_arq('[]'::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 2:arq-vacio';
  END IF;
  IF cerebro_parsear_tasa_arq(replace(v_arq, 'usdc_mxn', 'usdc_eur')::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 3:arq-libro';
  END IF;
  IF cerebro_parsear_tasa_arq(replace(v_arq, '18.6474810965', '0.5')::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 4:arq-imposible';
  END IF;

  IF cerebro_parsear_tasa_erapi(v_erapi::jsonb) IS DISTINCT FROM 18.7823 THEN
    v_fail := v_fail || ' 5:erapi';
  END IF;
  IF cerebro_parsear_tasa_erapi('{"result":"error"}'::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 6:erapi-vacio';
  END IF;

  PERFORM cerebro_registrar_tasa_usd_mxn(18.5, 'arq');
  PERFORM cerebro_registrar_tasa_usd_mxn(18.7, 'manual');
  IF cerebro_tasa_usd_mxn() IS DISTINCT FROM 18.7 THEN
    v_fail := v_fail || ' 7:vigente';
  END IF;

  -- A failed fetch records a NULL row and never replaces the last good value.
  PERFORM cerebro_registrar_tasa_usd_mxn(NULL, 'arq', '{"error":"prueba"}'::jsonb);
  v_latest := cerebro_tasa_usd_mxn();
  IF v_latest IS DISTINCT FROM 18.7 THEN
    v_fail := v_fail || ' 8:fallo-pisa';
  END IF;
  IF (cerebro_tasa_usd_mxn_info() ->> 'valor')::numeric IS DISTINCT FROM 18.7 THEN
    v_fail := v_fail || ' 9:info';
  END IF;

  IF (SELECT count(*) FROM cron.job WHERE jobname = 'solicitar-tasa-usd-mxn') <> 1 THEN
    v_fail := v_fail || ' 10:cron-solicitar';
  END IF;
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'procesar-tasa-usd-mxn') <> 1 THEN
    v_fail := v_fail || ' 11:cron-procesar';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
