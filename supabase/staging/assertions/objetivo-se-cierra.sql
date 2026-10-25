-- 319: the agreed amount closes when its shipment ends (trigger) and survives
-- while the conversation still has an active operation. Fixtures, rolled back.
DO $$
DECLARE
  v_base    record;
  v_conv_a  uuid;
  v_conv_b  uuid;
  v_op_a    uuid;
  v_contact_a uuid;
  v_contact_b uuid;
  v_ok      boolean;
  v_fail    text := '';
BEGIN
  -- The status guard treats a bare session as automation and swallows the change (trg_admin_guard_operations_status).
  PERFORM set_config('wacrm.origin', 'admin', true);
  PERFORM set_config('wacrm.actor', 'prueba-319', true);

  SELECT user_id, contact_id, account_id INTO v_base FROM conversations ORDER BY created_at LIMIT 1;
  IF v_base.account_id IS NULL THEN RAISE EXCEPTION 'FAIL: sin conversaciones de base'; END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_base.user_id, v_base.account_id, '000000031901', 'Prueba 319 A') RETURNING id INTO v_contact_a;
  INSERT INTO conversations (user_id, contact_id, account_id, status)
  VALUES (v_base.user_id, v_contact_a, v_base.account_id, 'open') RETURNING id INTO v_conv_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status)
  VALUES (v_base.account_id, v_conv_a, 'ready_to_transfer') RETURNING id INTO v_op_a;
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido, operation_id)
  VALUES (v_conv_a, 1000, 'GYD', 'prueba 319', v_op_a);

  -- Con una operacion activa el objetivo se queda abierto.
  v_ok := cerebro_objetivo_cerrar_si_cerrada(v_conv_a);
  IF v_ok THEN v_fail := v_fail || ' 1:cerro-con-activa'; END IF;
  IF (SELECT cerrado_en FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_a) IS NOT NULL THEN
    v_fail := v_fail || ' 2:activa-cerrada';
  END IF;

  -- Al completarse la unica operacion, el trigger lo cierra.
  UPDATE remittance_operations SET status = 'completed' WHERE id = v_op_a;
  IF (SELECT cerrado_en FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_a) IS NULL THEN
    v_fail := v_fail || ' 3:trigger-no-cerro';
  END IF;

  -- La funcion tambien lo cierra cuando ya no queda nada activo.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_base.user_id, v_base.account_id, '000000031902', 'Prueba 319 B') RETURNING id INTO v_contact_b;
  INSERT INTO conversations (user_id, contact_id, account_id, status)
  VALUES (v_base.user_id, v_contact_b, v_base.account_id, 'open') RETURNING id INTO v_conv_b;
  INSERT INTO remittance_operations (account_id, conversation_id, status)
  VALUES (v_base.account_id, v_conv_b, 'cancelled');
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido)
  VALUES (v_conv_b, 1000, 'GYD', 'prueba 319');
  v_ok := cerebro_objetivo_cerrar_si_cerrada(v_conv_b);
  IF NOT v_ok THEN v_fail := v_fail || ' 4:no-cerro'; END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgname = 'remittance_operations_cierra_objetivo' AND NOT tgisinternal) THEN
    v_fail := v_fail || ' 5:trigger';
  END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
