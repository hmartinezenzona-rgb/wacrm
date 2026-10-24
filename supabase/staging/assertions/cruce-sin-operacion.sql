-- 311: a receipt with no operation is matched and consumed (operation_id NULL).
DO $$
DECLARE
  v_ref text := '311' || lpad((floor(random()*1000000))::text, 6, '0');
  v_res text; v_tocados int; v_consumido timestamptz; v_op uuid;
  v_fail text := '';
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id, crudo)
  VALUES (v_ref, 5000, 'GYD', 'PRUEBA 311', 'prueba', now(), 'prueba-311-' || v_ref, '{}'::jsonb);

  SELECT resultado, deal_actualizado INTO v_res, v_tocados
    FROM cerebro_cruzar_deposito(NULL, v_ref, 5000,
                                 'aaa95c92-63a4-4bc1-a300-1cca6d87c072'::uuid,
                                 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid,
                                 '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b'::uuid,
                                 false);

  IF v_res <> 'verificado' THEN v_fail := v_fail || ' 1:resultado=' || coalesce(v_res,'null'); END IF;
  SELECT consumido_en, operation_id INTO v_consumido, v_op FROM depositos_mmg WHERE trans_id = v_ref;
  IF v_consumido IS NULL THEN v_fail := v_fail || ' 2:no-consumido'; END IF;
  IF v_op IS NOT NULL THEN v_fail := v_fail || ' 3:op-no-nula'; END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
