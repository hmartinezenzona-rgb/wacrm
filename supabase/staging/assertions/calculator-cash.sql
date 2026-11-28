-- =====================================================================
-- Assertion for migration 193 (cash deliveries reach the calculator). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/remesa-closing-and-cash.md (A6). Admin via owner, 2026-10-03: a cash dollar costs the same as a Zelle /
-- Clasica / Tropical dollar (usdt_buy_gyd, 240 today); only the sale price differs (efectivo_usd_gyd, 290 vs
-- usdt_sell_gyd 260). So a completed efectivo_usd remesa feeds a new service EFECTIVO: amount = floor(GYD / efectivo
-- rate) USD, facturado = amount x efectivo rate, invertido = amount x buy rate. Expected values are computed from the
-- live calculator rates so the assertion holds whatever the rates are.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t193(p_tag text, p_gyd numeric, p_method text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900193' || p_tag, 'test193' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', p_gyd, p_method) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE
  v_acc uuid; v_admin uuid; v_rates calculator_rate_versions; v_op uuid; v_e record; v_usd numeric;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  v_rates := calculator_rates_vigentes(v_acc);
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. The cash method maps to the EFECTIVO service.
  IF calculator_service_for_operation('efectivo_usd') IS DISTINCT FROM 'EFECTIVO' THEN
    RAISE EXCEPTION 'case 1: efectivo_usd must map to EFECTIVO, got %', calculator_service_for_operation('efectivo_usd'); END IF;

  -- 2. A completed cash remesa (Bruce's shape: 29,000 GYD) is priced at the cash rate and the shared buy rate.
  v_op := pg_temp.op_t193('01', 29000, 'efectivo_usd');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, id_photo_wamid, position, block_index, source, status)
  VALUES (v_op, 'efectivo_usd', 'Anabel', '53904458', 'Cerro', 'wamid.t193', 1, 1, 'manual', 'vigente');
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  v_usd := floor(29000 / v_rates.efectivo_usd_gyd);
  IF v_e.service IS DISTINCT FROM 'EFECTIVO' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM v_usd
     OR v_e.amount_currency IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case 2: expected EFECTIVO completed % USD, got % % % %', v_usd, v_e.service, v_e.status, v_e.amount, v_e.amount_currency; END IF;
  IF v_e.facturado_gyd IS DISTINCT FROM v_usd * v_rates.efectivo_usd_gyd OR v_e.invertido_gyd IS DISTINCT FROM v_usd * v_rates.usdt_buy_gyd
     OR v_e.retorno_gyd IS DISTINCT FROM v_usd * (v_rates.efectivo_usd_gyd - v_rates.usdt_buy_gyd)
     OR v_e.usdt_sell_gyd IS DISTINCT FROM v_rates.efectivo_usd_gyd THEN
    RAISE EXCEPTION 'case 2: facturado/invertido/retorno/sell rate wrong: % / % / % / %', v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.usdt_sell_gyd; END IF;

  -- 3. Zelle is untouched: still the Zelle sale rate.
  v_op := pg_temp.op_t193('02', 26000, 'zelle');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Ana', 'ana@example.com', 1, 1, 'manual', 'vigente');
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'ZELLE' OR v_e.amount IS DISTINCT FROM floor(26000 / v_rates.usdt_sell_gyd)
     OR v_e.usdt_sell_gyd IS DISTINCT FROM v_rates.usdt_sell_gyd THEN
    RAISE EXCEPTION 'case 3: Zelle must keep its own sale rate, got % % %', v_e.service, v_e.amount, v_e.usdt_sell_gyd; END IF;

  -- 4. A pending EFECTIVO line is resolved with the CASH rate, not the Zelle one.
  v_op := pg_temp.op_t193('03', 29000, 'efectivo_usd');
  -- the operation stays open (no feed); the pending line is inserted as the feed writes one when a rate is missing
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, service, amount, amount_currency,
                                             missing_inputs, completed_at)
  VALUES (v_acc, 'completed_operation', 'verified_pending', v_op, current_date, 'EFECTIVO', 29000, 'USD', ARRAY['efectivoUsdGyd'], now())
  RETURNING * INTO v_e;
  PERFORM crm_resolve_pending_entry(v_e.id, '{"efectivo_usd_gyd": 290, "usdt_buy_gyd": 240}'::jsonb, 'precio del efectivo');
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_e.id;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 100 OR v_e.facturado_gyd IS DISTINCT FROM 29000
     OR v_e.invertido_gyd IS DISTINCT FROM 24000 THEN
    RAISE EXCEPTION 'case 4: resolve must price cash at 290/240, got % % % %', v_e.status, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
