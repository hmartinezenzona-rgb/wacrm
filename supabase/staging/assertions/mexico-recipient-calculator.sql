-- 294: an operation whose recipients are mexico_cuenta / mexico_retiro resolves to the CLASICA calculator service.
DO $$
DECLARE
  v_acc uuid; v_conv uuid; v_contact uuid; v_op uuid := gen_random_uuid(); v_fail text := '';
  v_row remittance_operations;
BEGIN
  IF calculator_service_for_operation('mexico_cuenta') IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail || ' 1:mexico_cuenta'; END IF;
  IF calculator_service_for_operation('mexico_retiro') IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail || ' 2:mexico_retiro'; END IF;
  IF calculator_service_for_operation('mexico') IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail || ' 3:mexico'; END IF;
  IF calculator_service_for_operation('cuban_card') IS DISTINCT FROM 'CUP' THEN v_fail := v_fail || ' 4:cup unchanged'; END IF;

  SELECT c.account_id, c.id, c.contact_id INTO v_acc, v_conv, v_contact FROM conversations c LIMIT 1;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, source_country,
    source_currency, destination_currency, delivery_method, quoted_source_amount, quoted_destination_amount)
  VALUES (v_op, v_acc, v_conv, v_contact, 'ready_to_transfer', 'mexico', 'GY', 'GYD', 'USD', 'clasica', 26000, 100);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, clabe, bank_name, amount, currency, status, position, source)
  VALUES (v_op, 'mexico_cuenta', 'PRUEBA Uno', '012345678901234567', 'Mercado Pago', 50, 'USD', 'vigente', 1, 'admin_addition'),
         (v_op, 'mexico_cuenta', 'PRUEBA Dos', '012345678901234568', 'Mercado Pago', 50, 'USD', 'vigente', 2, 'admin_addition');
  IF calculator_resolve_operation_service(v_op, 'clasica') IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail || ' 5:resolve'; END IF;

  -- The real defect path: an unknown recipient type made calculator_operation_parts return no part at all
  -- (v_n_unknown > 0 -> RETURN), so the feed had nothing to write.
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF NOT EXISTS (SELECT 1 FROM calculator_operation_parts(v_row, calculator_rates_vigentes(v_acc)) p
                  WHERE p.service = 'CLASICA' AND p.basis = 26000) THEN v_fail := v_fail || ' 6:parts'; END IF;

  IF v_fail <> '' THEN RAISE EXCEPTION 'FAIL:%', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
