-- =====================================================================
-- Assertion for migration 242 (recharge cost by promotion tier + per-operation cost edit). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. STAGING only; pending staging run (T5). Needs 198..242 applied.
--
-- odd/tasks/recarga-saldo-costs.md. Owner: 500 tier costs 19.5 USDT (sold 5,200), 600 tier 23.1 (22.8 on a good day, sold 6,200),
-- USDT bought at 240; saldo 1.6 or 2 USDT per 360 CUP package, sold 1,000.
--   case 1 a 500-tier chat recharge (5,200) with recarga_costo_usdt_500 19.5 / buy 240: invertido 4,680, retorno 520, cost_gyd 19.5
--   case 2 a 600-tier recharge (6,200) keeps recarga_costo_usdt: 23.1 x 240 = 5,544, retorno 656, cost_gyd 23.1
--   case 3 the 500 rate NULL: a 500-tier recharge falls back to recarga_costo_usdt (pre-242 behaviour)
--   case 4 edit a 600-tier chat recharge to 22.8: invertido 5,472, retorno 728, facturado, amount untouched, cost_gyd 22.8, no audit row
--   case 5 edit the 500-tier one to 19 with a new buy 238: invertido 4,522
--   case 6 edit a chat saldo (3 packages, 1,000 each) to 1.6: invertido 3 x 1.6 x 240 = 1,152, retorno 1,848
--   case 7 manual lines: "rec promo(23.1/6.2k/240)" x1 with buy 240 and no cost -> cost read from the line (5,544); explicit 22.8 -> 5,472;
--          manual saldo "(2/1k/240)" x3 edited to 1.6 -> 1,152; an unreadable line with no cost -> 22023
--   case 8 refusals: non-positive cost (22023), non-admin (42501)
--   case 9 crm_set_calculator_rates accepts recarga_costo_usdt_500, carries it forward, refuses <= 0
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t242(p_tag text, p_gyd numeric, p_numbers text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_i int := 0; v_n text;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900242' || p_tag, 'test242' || p_tag) RETURNING id INTO v_ct;
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
DECLARE
  v_acc uuid; v_admin uuid; v_agent uuid; v_op500 uuid; v_op600 uuid; v_op3 uuid; v_e remittance_calculator_entries; v_id500 uuid; v_id600 uuid;
  v_saldo uuid; v_m1 uuid; v_m2 uuid; v_m3 uuid; v_audits int; v_state text; v_r calculator_rate_versions; v_ok boolean;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  SELECT p.user_id INTO v_agent FROM profiles p WHERE p.account_id = v_acc AND p.account_role = 'agent' LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- case 9 (first: it sets the rates the rest use)
  v_r := crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": 23.1, "recarga_costo_usdt_500": 19.5, "usdt_buy_gyd": 240}'::jsonb, NULL);
  IF v_r.recarga_costo_usdt_500 IS DISTINCT FROM 19.5 OR v_r.recarga_costo_usdt IS DISTINCT FROM 23.1 THEN
    RAISE EXCEPTION 'case 9: both recharge costs must be stored, got % / %', v_r.recarga_costo_usdt_500, v_r.recarga_costo_usdt; END IF;
  v_r := crm_set_calculator_rates(v_acc, '{"usdt_buy_gyd": 240}'::jsonb, NULL);
  IF v_r.recarga_costo_usdt_500 IS DISTINCT FROM 19.5 THEN RAISE EXCEPTION 'case 9: the 500 cost must carry forward, got %', v_r.recarga_costo_usdt_500; END IF;
  BEGIN PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt_500": 0}'::jsonb, NULL); v_ok := true;
  EXCEPTION WHEN sqlstate '22023' THEN v_ok := false; END;
  IF v_ok THEN RAISE EXCEPTION 'case 9: a zero 500 cost must be refused'; END IF;

  -- case 1
  v_op500 := pg_temp.op_t242('01', 5200, ARRAY['53871234']);
  PERFORM crm_cerrar_operacion_manual(v_op500);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op500 AND status <> 'void';
  v_id500 := v_e.id;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.facturado_gyd IS DISTINCT FROM 5200 OR v_e.invertido_gyd IS DISTINCT FROM 4680
     OR v_e.retorno_gyd IS DISTINCT FROM 520 OR v_e.cost_gyd IS DISTINCT FROM 19.5 THEN
    RAISE EXCEPTION 'case 1: 500 tier must be 5200/4680/520 cost 19.5, got % % % % %', v_e.status, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.cost_gyd; END IF;

  -- case 2
  v_op600 := pg_temp.op_t242('02', 6200, ARRAY['53871235']);
  PERFORM crm_cerrar_operacion_manual(v_op600);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op600 AND status <> 'void';
  v_id600 := v_e.id;
  IF v_e.invertido_gyd IS DISTINCT FROM 5544 OR v_e.retorno_gyd IS DISTINCT FROM 656 OR v_e.cost_gyd IS DISTINCT FROM 23.1 THEN
    RAISE EXCEPTION 'case 2: 600 tier must be 5544/656 cost 23.1, got % % %', v_e.invertido_gyd, v_e.retorno_gyd, v_e.cost_gyd; END IF;

  -- case 3
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt_500": null}'::jsonb, NULL);
  v_op3 := pg_temp.op_t242('03', 5200, ARRAY['53871236']);
  PERFORM crm_cerrar_operacion_manual(v_op3);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op3 AND status <> 'void';
  IF v_e.invertido_gyd IS DISTINCT FROM 5544 OR v_e.cost_gyd IS DISTINCT FROM 23.1 THEN
    RAISE EXCEPTION 'case 3: with no 500 rate the 500 tier falls back to 23.1, got % %', v_e.invertido_gyd, v_e.cost_gyd; END IF;

  -- case 4
  SELECT count(*) INTO v_audits FROM remittance_admin_audit WHERE row_id = v_id600;
  SELECT * INTO v_e FROM crm_corregir_tasas_entrada_calculadora(v_id600, NULL, NULL, 22.8);
  IF v_e.invertido_gyd IS DISTINCT FROM 5472 OR v_e.retorno_gyd IS DISTINCT FROM 728 OR v_e.cost_gyd IS DISTINCT FROM 22.8
     OR v_e.facturado_gyd IS DISTINCT FROM 6200 OR v_e.amount IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'case 4: edit to 22.8 must give 5472/728, facturado 6200, got % % % % %', v_e.invertido_gyd, v_e.retorno_gyd, v_e.cost_gyd, v_e.facturado_gyd, v_e.amount; END IF;
  IF (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_id600) IS DISTINCT FROM v_audits THEN RAISE EXCEPTION 'case 4: the edit must write no audit row'; END IF;

  -- case 5 (the 500-tier entry of case 1)
  SELECT * INTO v_e FROM crm_corregir_tasas_entrada_calculadora(v_id500, 238, NULL, 19);
  IF v_e.invertido_gyd IS DISTINCT FROM 4522 OR v_e.usdt_buy_gyd IS DISTINCT FROM 238 OR v_e.cost_gyd IS DISTINCT FROM 19 THEN
    RAISE EXCEPTION 'case 5: 19 x 238 = 4522, got % % %', v_e.invertido_gyd, v_e.usdt_buy_gyd, v_e.cost_gyd; END IF;

  -- case 6 (chat saldo fixture: 3 packages of 1,000 GYD, amount in saldo units)
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, cost_gyd, sale_gyd, basis_gyd)
  VALUES (v_acc, 'completed_operation', 'completed', v_op3, current_date, 'SALDO 242', 'SALDO_MOVIL', 1080, 'SM',
    3, 240, 240, 1000, 3000, 1440, 1560, now(), 2, 1000, 3000) RETURNING id INTO v_saldo;
  SELECT * INTO v_e FROM crm_corregir_tasas_entrada_calculadora(v_saldo, NULL, NULL, 1.6);
  IF v_e.invertido_gyd IS DISTINCT FROM 1152 OR v_e.retorno_gyd IS DISTINCT FROM 1848 OR v_e.cost_gyd IS DISTINCT FROM 1.6 THEN
    RAISE EXCEPTION 'case 6: saldo 1.6 must give 1152/1848, got % % %', v_e.invertido_gyd, v_e.retorno_gyd, v_e.cost_gyd; END IF;

  -- case 7 (manual lines as the Calculator registers them: no snapshot)
  SELECT (e ->> 'id')::uuid INTO v_m1 FROM jsonb_array_elements(crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Onaisy', 'service', 'RECARGA', 'currency', 'REC', 'amount', 1, 'facturado_gyd', 6200, 'invertido_gyd', 5544, 'retorno_gyd', 656,
    'date', to_char(current_date, 'YYYY-MM-DD'), 'raw_line', '• Onaisy 1 rec promo(23.1/6.2k/240)')))) e;
  SELECT * INTO v_e FROM crm_corregir_tasas_entrada_calculadora(v_m1, 240, NULL, NULL);
  IF v_e.invertido_gyd IS DISTINCT FROM 5544 OR v_e.cost_gyd IS DISTINCT FROM 23.1 THEN
    RAISE EXCEPTION 'case 7: cost read from the line (23.1 x 240 = 5544), got % %', v_e.invertido_gyd, v_e.cost_gyd; END IF;
  SELECT * INTO v_e FROM crm_corregir_tasas_entrada_calculadora(v_m1, NULL, NULL, 22.8);
  IF v_e.invertido_gyd IS DISTINCT FROM 5472 OR v_e.retorno_gyd IS DISTINCT FROM 728 OR v_e.facturado_gyd IS DISTINCT FROM 6200 THEN
    RAISE EXCEPTION 'case 7: manual recarga at 22.8 must give 5472/728, got % % %', v_e.invertido_gyd, v_e.retorno_gyd, v_e.facturado_gyd; END IF;
  SELECT (e ->> 'id')::uuid INTO v_m2 FROM jsonb_array_elements(crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Carlos', 'service', 'SALDO_MOVIL', 'currency', 'SM', 'amount', 3, 'facturado_gyd', 3000, 'invertido_gyd', 1440, 'retorno_gyd', 1560,
    'date', to_char(current_date, 'YYYY-MM-DD'), 'raw_line', '• Carlos 3 saldo movil (2/1k/240)')))) e;
  SELECT * INTO v_e FROM crm_corregir_tasas_entrada_calculadora(v_m2, 240, NULL, 1.6);
  IF v_e.invertido_gyd IS DISTINCT FROM 1152 OR v_e.retorno_gyd IS DISTINCT FROM 1848 THEN
    RAISE EXCEPTION 'case 7: manual saldo at 1.6 must give 1152/1848, got % %', v_e.invertido_gyd, v_e.retorno_gyd; END IF;
  SELECT (e ->> 'id')::uuid INTO v_m3 FROM jsonb_array_elements(crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Raro', 'service', 'RECARGA', 'currency', 'REC', 'amount', 1, 'facturado_gyd', 6200, 'invertido_gyd', 5544, 'retorno_gyd', 656,
    'date', to_char(current_date, 'YYYY-MM-DD'), 'raw_line', '• Raro 1 rec promo')))) e;
  BEGIN PERFORM crm_corregir_tasas_entrada_calculadora(v_m3, 240, NULL, NULL); v_ok := true;
  EXCEPTION WHEN sqlstate '22023' THEN v_ok := false; END;
  IF v_ok THEN RAISE EXCEPTION 'case 7: a manual recarga with no readable cost and none sent must be refused'; END IF;

  -- case 8
  BEGIN PERFORM crm_corregir_tasas_entrada_calculadora(v_id600, NULL, NULL, 0); v_ok := true;
  EXCEPTION WHEN sqlstate '22023' THEN v_ok := false; END;
  IF v_ok THEN RAISE EXCEPTION 'case 8: a zero cost must be refused'; END IF;
  IF v_agent IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent, 'role', 'authenticated')::text, true);
    BEGIN PERFORM crm_corregir_tasas_entrada_calculadora(v_id600, NULL, NULL, 20); v_ok := true;
    EXCEPTION WHEN sqlstate '42501' THEN v_ok := false; END;
    IF v_ok THEN RAISE EXCEPTION 'case 8: a non-admin must be refused'; END IF;
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
