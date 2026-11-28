-- =====================================================================
-- Assertion for migration 199 (completed recharges reach the calculator as RECARGA). Self-reverting: one DO block
-- that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/panel-other-services.md (R1). The calculator guide's line "• Josefa 1 rec promo (23.1/6.2k/242)" =
-- 1 recharge, cost 23.1 USDT, sale 6,200 GYD, 242 GYD per USDT: invertido 5,590.2, facturado 6,200. Automatic lines
-- mirror it: units = deposit / its precio_recarga price, facturado = units x price, invertido = units x recarga_costo_usdt x
-- usdt_buy_gyd; snapshot cost_gyd = cost (USDT), sale_gyd = price, cup_rate = usdt_buy_gyd, like a manual RECARGA line.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t199(p_tag text, p_gyd numeric, p_numbers text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_i int := 0; v_n text;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900199' || p_tag, 'test199' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'recarga', 'GYD', p_gyd) RETURNING id INTO v_op;
  FOREACH v_n IN ARRAY p_numbers LOOP
    v_i := v_i + 1;
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
    VALUES (v_op, 'recarga', v_n, v_i, v_i, 'manual', 'vigente');
  END LOOP;
  RETURN v_op;
END $$;

DO $$
DECLARE v_acc uuid; v_admin uuid; v_op uuid; v_e record; v_buy numeric;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": 23.1, "usdt_buy_gyd": 242}'::jsonb, NULL);
  v_buy := 242;

  -- 1. Josefa's line: one recharge of 6,200 GYD.
  v_op := pg_temp.op_t199('01', 6200, ARRAY['53871234']);
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'RECARGA' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'case 1: expected RECARGA completed 1, got % % %', v_e.service, v_e.status, v_e.amount; END IF;
  IF v_e.facturado_gyd IS DISTINCT FROM 6200 OR round(v_e.invertido_gyd, 1) IS DISTINCT FROM 5590.2
     OR round(v_e.retorno_gyd, 1) IS DISTINCT FROM 609.8 THEN
    RAISE EXCEPTION 'case 1: facturado/invertido/retorno must be 6200/5590.2/609.8, got %/%/%', v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd; END IF;
  IF v_e.cost_gyd IS DISTINCT FROM 23.1 OR v_e.sale_gyd IS DISTINCT FROM 6200 OR v_e.cup_rate IS DISTINCT FROM v_buy THEN
    RAISE EXCEPTION 'case 1: the snapshot must read like a manual "rec promo" line, got % / % / %', v_e.cost_gyd, v_e.sale_gyd, v_e.cup_rate; END IF;

  -- 2. Two numbers, 12,400 GYD: two recharges.
  v_op := pg_temp.op_t199('02', 12400, ARRAY['53871234', '63123456']);
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.amount IS DISTINCT FROM 2 OR v_e.facturado_gyd IS DISTINCT FROM 12400 THEN
    RAISE EXCEPTION 'case 2: expected 2 recharges / 12,400, got % / %', v_e.amount, v_e.facturado_gyd; END IF;

  -- 3. Cost not set yet: the line is pending and names what is missing.
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": null}'::jsonb, NULL);
  v_op := pg_temp.op_t199('03', 6200, ARRAY['53871234']);
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR NOT ('recargaCostoUsdt' = ANY (v_e.missing_inputs)) THEN
    RAISE EXCEPTION 'case 3: a missing cost leaves the line pending naming recargaCostoUsdt, got % %', v_e.status, v_e.missing_inputs; END IF;

  -- 4. A recharge without numbers is still priced from its kind (service_type), not lost.
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": 23.1}'::jsonb, NULL);
  v_op := pg_temp.op_t199('04', 6200, ARRAY[]::text[]);
  PERFORM crm_cerrar_operacion_manual(v_op);
  IF (SELECT service FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void') IS DISTINCT FROM 'RECARGA' THEN
    RAISE EXCEPTION 'case 4: a recharge without numbers must still reach the calculator as RECARGA'; END IF;

  -- 5. A deposit matching no recharge price (12,520) is pending and names the price.
  v_op := pg_temp.op_t199('05', 12520, ARRAY['53871234', '63123456']);
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR NOT ('recargaPrecioGyd' = ANY (v_e.missing_inputs)) THEN
    RAISE EXCEPTION 'case 5: an odd deposit leaves the line pending naming recargaPrecioGyd, got % %', v_e.status, v_e.missing_inputs; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
