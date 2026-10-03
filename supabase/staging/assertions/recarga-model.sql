-- =====================================================================
-- Assertion for migration 198 (the recharge data model). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/panel-other-services.md (R1). Owner, 2026-10-03: one Etecsa promotion at a time; its price is set by the
-- promotion's main balance (500 CUP -> 5,200 GYD; 600 CUP -> 6,200 GYD); one Cuban number per recharge; the cost per
-- recharge is in USDT (23.1 in the calculator guide; confirmation pending with the admin) and lives in the calculator
-- rates. The price comes from precio_recarga (500 -> 5,200, 600 -> 6,200): a deposit pays the price it is a multiple of.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t198(p_tag text, p_gyd numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900198' || p_tag, 'test198' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'recarga', 'GYD', p_gyd) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE v_acc uuid; v_admin uuid; v_rates calculator_rate_versions; v_before calculator_rate_versions; v_op uuid;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_before := calculator_rates_vigentes(v_acc);

  -- 1. The cost per recharge is a calculator rate; the price and the count come from the deposit.
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": 23.1}'::jsonb, NULL);
  v_rates := calculator_rates_vigentes(v_acc);
  IF cerebro_recarga_precio(12400) IS DISTINCT FROM 6200 OR cerebro_recarga_unidades(12400) IS DISTINCT FROM 2
     OR cerebro_recarga_precio(10400) IS DISTINCT FROM 5200 OR cerebro_recarga_precio(12520) IS NOT NULL THEN
    RAISE EXCEPTION 'case 1: price/count from the deposit wrong: % % % %', cerebro_recarga_precio(12400), cerebro_recarga_unidades(12400),
      cerebro_recarga_precio(10400), cerebro_recarga_precio(12520); END IF;
  IF v_rates.recarga_costo_usdt IS DISTINCT FROM 23.1
     OR v_rates.usdt_buy_gyd IS DISTINCT FROM v_before.usdt_buy_gyd OR v_rates.efectivo_usd_gyd IS DISTINCT FROM v_before.efectivo_usd_gyd THEN
    RAISE EXCEPTION 'case 1: the recharge rates must be stored and the others kept'; END IF;

  -- 2. One Cuban number per recharge: 12,400 GYD at 6,200 = 2 recharges, so 2 valid numbers make it complete.
  v_op := pg_temp.op_t198('01', 12400);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
  VALUES (v_op, 'recarga', '53871234', 1, 1, 'manual', 'vigente');
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 2: one number for two recharges is not complete'; END IF;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
  VALUES (v_op, 'recarga', '63123456', 2, 2, 'manual', 'vigente');
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 2: two valid numbers for two recharges are complete'; END IF;

  -- 3. A number that is not a Cuban mobile does not count.
  v_op := pg_temp.op_t198('02', 6200);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
  VALUES (v_op, 'recarga', '78123456', 1, 1, 'manual', 'vigente');
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 3: a landline is not a recharge number'; END IF;

  -- 4. A deposit matching no price (12,520): a recharge with at least one valid number is complete (no count to compare).
  UPDATE remittance_operations SET quoted_source_amount = 12520 WHERE id = v_op;
  UPDATE remittance_beneficiaries SET phone = '53871234' WHERE operation_id = v_op;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 4: one valid number completes when the count is unknown'; END IF;

  -- 5. Remesas are untouched: a card without phone is still incomplete.
  UPDATE remittance_operations SET service_type = 'remesa' WHERE id = v_op;
  UPDATE remittance_beneficiaries SET beneficiary_type = 'cuban_card', card_number = '9235123487781111', phone = NULL WHERE operation_id = v_op;
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 5: a card without phone stays incomplete'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
