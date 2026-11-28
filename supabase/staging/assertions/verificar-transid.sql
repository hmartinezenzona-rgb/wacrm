-- 312: a written TransID verifies and consumes; a used one says YA RECLAMADO.
DO $$
DECLARE
  v_ref text := '312' || lpad((floor(random()*1000000))::text, 6, '0');
  v_txt text; v_consumido timestamptz; v_op uuid; v_fail text := '';
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id, crudo)
  VALUES (v_ref, 5000, 'GYD', 'PRUEBA 312', 'prueba', now() - interval '1 hour', 'prueba-312-' || v_ref, '{}'::jsonb);

  v_txt := cerebro_verificar_transid(v_ref);
  IF v_txt NOT LIKE 'VERIFICADO%' THEN v_fail := v_fail || ' 1:texto=' || left(v_txt, 40); END IF;
  SELECT consumido_en, operation_id INTO v_consumido, v_op FROM depositos_mmg WHERE trans_id = v_ref;
  IF v_consumido IS NULL THEN v_fail := v_fail || ' 2:no-consumido'; END IF;
  IF v_op IS NOT NULL THEN v_fail := v_fail || ' 3:op-no-nula'; END IF;

  v_txt := cerebro_verificar_transid(v_ref);
  IF v_txt NOT LIKE 'YA RECLAMADO%' THEN v_fail := v_fail || ' 4:segunda=' || left(v_txt, 40); END IF;

  v_txt := cerebro_verificar_transid('99999999999999');
  IF v_txt NOT LIKE 'SIN CRUCE%' THEN v_fail := v_fail || ' 5:inexistente=' || left(v_txt, 40); END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
