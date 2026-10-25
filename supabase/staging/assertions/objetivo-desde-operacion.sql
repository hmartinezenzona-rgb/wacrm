-- 320: a new shipment retires a stale agreed amount and seeds its own.
-- Fixtures, rolled back.
DO $$
DECLARE
  v_base   record;
  v_c      uuid;
  v_conv   uuid;
  v_op     uuid;
  v_obj    cerebro_objetivo_envio;
  v_fail   text := '';
BEGIN
  PERFORM set_config('wacrm.origin', 'admin', true);
  PERFORM set_config('wacrm.actor', 'prueba-320', true);

  SELECT user_id, contact_id, account_id INTO v_base FROM conversations ORDER BY created_at LIMIT 1;

  -- Caso 1: objetivo viejo sin operacion -> se retira y lo sustituye el monto de la operacion.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_base.user_id, v_base.account_id, '000000032001', 'Prueba 320 A') RETURNING id INTO v_c;
  INSERT INTO conversations (user_id, contact_id, account_id, status)
  VALUES (v_base.user_id, v_c, v_base.account_id, 'open') RETURNING id INTO v_conv;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido, fijado_en)
  VALUES (v_conv, 20020, 'GYD', '77 USD', now() - interval '3 days');

  INSERT INTO remittance_operations (account_id, conversation_id, status)
  VALUES (v_base.account_id, v_conv, 'collecting_information') RETURNING id INTO v_op;

  IF (SELECT cerrado_en FROM cerebro_objetivo_envio WHERE conversation_id = v_conv) IS NULL THEN
    v_fail := v_fail || ' 1:viejo-sigue-abierto';
  END IF;

  UPDATE remittance_operations SET quoted_source_amount = 26000 WHERE id = v_op;
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.cerrado_en IS NOT NULL THEN v_fail := v_fail || ' 2:no-se-creo'; END IF;
  IF v_obj.monto <> 26000 THEN v_fail := v_fail || ' 3:monto'; END IF;
  IF v_obj.operation_id IS DISTINCT FROM v_op THEN v_fail := v_fail || ' 4:sin-operacion'; END IF;

  -- Caso 2: declaracion fresca del cliente -> se respeta.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_base.user_id, v_base.account_id, '000000032002', 'Prueba 320 B') RETURNING id INTO v_c;
  INSERT INTO conversations (user_id, contact_id, account_id, status)
  VALUES (v_base.user_id, v_c, v_base.account_id, 'open') RETURNING id INTO v_conv;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido)
  VALUES (v_conv, 26000, 'GYD', '100 USD');

  INSERT INTO remittance_operations (account_id, conversation_id, status, quoted_source_amount)
  VALUES (v_base.account_id, v_conv, 'collecting_information', 25000) RETURNING id INTO v_op;

  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.cerrado_en IS NOT NULL THEN v_fail := v_fail || ' 5:cerro-fresca'; END IF;
  IF v_obj.monto <> 26000 THEN v_fail := v_fail || ' 6:piso-fresca'; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'remittance_operations_objetivo_desde_op' AND NOT tgisinternal) THEN
    v_fail := v_fail || ' 7:trigger';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
