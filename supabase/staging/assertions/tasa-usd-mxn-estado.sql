-- 298: tolerant ARQ parsing, failure reasons and the estado reader.
DO $$
DECLARE
  v_arr   text := '[{"ask":"18.6697421235","bid":"18.6474810965","book":"usdc_mxn","date":"2026-10-24T15:09:31Z"}]';
  v_data  text := '{"data":[{"bid":"18.65","book":"usdc_mxn"}]}';
  v_tick  text := '{"tickers":[{"rate":"18.66","book":"usdc_mxn"}]}';
  v_price text := '[{"price":"18.67","book":"usdc_mxn"}]';
  v_erapi text := '{"amount":1.0,"base":"USD","date":"2026-10-23","rates":{"MXN":18.7823}}';
  v_fail  text := '';
  v_est   jsonb;
BEGIN
  IF cerebro_parsear_tasa_arq(v_arr::jsonb) IS DISTINCT FROM 18.6474810965 THEN
    v_fail := v_fail || ' 1:array';
  END IF;
  IF cerebro_parsear_tasa_arq(v_data::jsonb) IS DISTINCT FROM 18.65 THEN
    v_fail := v_fail || ' 2:data';
  END IF;
  IF cerebro_parsear_tasa_arq(v_tick::jsonb) IS DISTINCT FROM 18.66 THEN
    v_fail := v_fail || ' 3:tickers-rate';
  END IF;
  IF cerebro_parsear_tasa_arq(v_price::jsonb) IS DISTINCT FROM 18.67 THEN
    v_fail := v_fail || ' 4:price';
  END IF;
  IF cerebro_parsear_tasa_arq(replace(v_arr, 'usdc_mxn', 'usdc_eur')::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 5:libro';
  END IF;
  IF cerebro_parsear_tasa_arq(replace(v_arr, '18.6474810965', '0.5')::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 6:imposible';
  END IF;
  IF cerebro_parsear_tasa_arq('{"nada":true}'::jsonb) IS NOT NULL THEN
    v_fail := v_fail || ' 7:sin-tasa';
  END IF;
  IF cerebro_parsear_tasa_erapi(v_erapi::jsonb) IS DISTINCT FROM 18.7823 THEN
    v_fail := v_fail || ' 8:erapi';
  END IF;

  -- Estado: value, last ARQ attempt, motivo and consecutive ARQ failures.
  PERFORM cerebro_registrar_tasa_usd_mxn(18.5, 'arq', '{"motivo":"ok"}'::jsonb);
  PERFORM cerebro_registrar_tasa_usd_mxn(NULL, 'arq', '{"motivo":"formato","raw":"x"}'::jsonb);
  PERFORM cerebro_registrar_tasa_usd_mxn(18.7, 'erapi', '{"motivo":"ok"}'::jsonb);

  v_est := cerebro_tasa_usd_mxn_estado();
  IF (v_est ->> 'valor')::numeric IS DISTINCT FROM 18.7 OR v_est ->> 'fuente' IS DISTINCT FROM 'erapi' THEN
    v_fail := v_fail || ' 9:valor';
  END IF;
  IF (v_est ->> 'ultimo_arq_ok')::boolean IS DISTINCT FROM false
     OR v_est ->> 'ultimo_motivo' IS DISTINCT FROM 'formato'
     OR (v_est ->> 'fallos_arq_consecutivos')::int IS DISTINCT FROM 1 THEN
    v_fail := v_fail || ' 10:arq-fallo';
  END IF;

  PERFORM cerebro_registrar_tasa_usd_mxn(NULL, 'arq', '{"motivo":"http"}'::jsonb);
  IF (cerebro_tasa_usd_mxn_estado() ->> 'fallos_arq_consecutivos')::int IS DISTINCT FROM 2 THEN
    v_fail := v_fail || ' 11:consecutivos';
  END IF;

  PERFORM cerebro_registrar_tasa_usd_mxn(18.8, 'arq', '{"motivo":"ok"}'::jsonb);
  v_est := cerebro_tasa_usd_mxn_estado();
  IF (v_est ->> 'valor')::numeric IS DISTINCT FROM 18.8
     OR (v_est ->> 'fallos_arq_consecutivos')::int IS DISTINCT FROM 0
     OR (v_est ->> 'ultimo_arq_ok')::boolean IS DISTINCT FROM true THEN
    v_fail := v_fail || ' 12:recuperado';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
