-- =====================================================================
-- Assertion for migration 215 (tiered Zelle rate). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Fixtures build their own contacts, conversations and operations; the user and account
-- come from whatsapp_config + profiles.
--
-- odd/tasks/zelle-tiered-rate.md (T1). Zelle is priced by tiers of USD received: 260 GYD per USD for 50-999 USD,
-- 250 for 1,000-1,999, 245 from 2,000. The customer gets the best tier the deposit reaches. From GYD:
-- floor(gyd/245) >= 2000 -> 245; elsif floor(gyd/250) >= 1000 -> 250; else 260. A deposit split between several
-- beneficiaries takes its tier from the TOTAL. Clasica, Tropical, USDT and Mexico keep the single rate.
-- Run it as: BEGIN; \i zelle-tiered-rate.sql; ROLLBACK;
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.zt_conv(p_tag text, OUT o_user uuid, OUT o_acc uuid, OUT o_conv uuid, OUT o_ct uuid)
LANGUAGE plpgsql AS $$
BEGIN
  SELECT p.user_id, p.account_id INTO o_user, o_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (o_user, o_acc, '59900215' || p_tag, 'test215' || p_tag) RETURNING id INTO o_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (o_user, o_acc, o_ct) RETURNING id INTO o_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.zt_op(p_tag text, p_gyd numeric, p_status text DEFAULT 'ready_to_transfer') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE c record; v_op uuid;
BEGIN
  SELECT * INTO c FROM pg_temp.zt_conv(p_tag);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (c.o_acc, c.o_conv, c.o_ct, p_status, 'remesa', 'GYD', p_gyd) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE
  v_op uuid; v_op2 uuid; v_acc uuid; v_admin uuid; v_conv uuid; v_ct uuid; v_user uuid;
  v_rates calculator_rate_versions;
  v_r record; v_j jsonb; v_n numeric; v_cup numeric; v_cupamt numeric; v_e record; v_txt text;
  t0 timestamptz := now() - interval '2 hours';
  -- gyd, expected usd, expected rate
  v_cases numeric[][] := ARRAY[[12999,49,260],[13000,50,260],[249999,961,260],[250000,1000,250],[259740,1038,250],
                               [489999,1959,250],[490000,2000,245],[499999,2040,245]];
  i int;
BEGIN
  -- 1. The helpers at the tier boundaries (GYD -> USD and rate).
  FOR i IN 1 .. array_length(v_cases, 1) LOOP
    IF cerebro_zelle_usd_desde_gyd(v_cases[i][1]) IS DISTINCT FROM v_cases[i][2] THEN
      RAISE EXCEPTION 'case 1: % GYD must give % USD, got %', v_cases[i][1], v_cases[i][2], cerebro_zelle_usd_desde_gyd(v_cases[i][1]); END IF;
    SELECT * INTO v_r FROM cerebro_zelle_cotizar_gyd(v_cases[i][1]);
    IF v_r.usd IS DISTINCT FROM v_cases[i][2] OR v_r.tasa IS DISTINCT FROM v_cases[i][3] THEN
      RAISE EXCEPTION 'case 1: % GYD must quote % USD at %, got % at %', v_cases[i][1], v_cases[i][2], v_cases[i][3], v_r.usd, v_r.tasa; END IF;
  END LOOP;
  -- the rate for a USD amount
  IF cerebro_tasa_zelle(50) <> 260 OR cerebro_tasa_zelle(999) <> 260 OR cerebro_tasa_zelle(1000) <> 250
     OR cerebro_tasa_zelle(1999) <> 250 OR cerebro_tasa_zelle(2000) <> 245 OR cerebro_tasa_zelle(5000) <> 245
     OR cerebro_tasa_zelle(49) <> 260 THEN
    RAISE EXCEPTION 'case 1: cerebro_tasa_zelle tiers wrong: 50->% 999->% 1000->% 1999->% 2000->% 49->%',
      cerebro_tasa_zelle(50), cerebro_tasa_zelle(999), cerebro_tasa_zelle(1000), cerebro_tasa_zelle(1999), cerebro_tasa_zelle(2000), cerebro_tasa_zelle(49); END IF;
  IF cerebro_zelle_usd_desde_gyd(NULL) IS NOT NULL OR cerebro_tasa_zelle(NULL) IS NOT NULL THEN RAISE EXCEPTION 'case 1: NULL in, NULL out'; END IF;

  -- 2. A single Zelle beneficiary: the amount follows the tier of the deposit (Yoandrys: 250,000 -> 1,000 USD at 250).
  v_op := pg_temp.zt_op('02', 250000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Tier A', 'tiera@example.com', 1, 1, 'manual', 'vigente');
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r, b.amount ba INTO v_r
    FROM remittance_operations o JOIN remittance_beneficiaries b ON b.operation_id = o.id AND b.status = 'vigente' WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1000 OR v_r.r IS DISTINCT FROM 250 OR v_r.ba IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'case 2: Zelle 250,000 GYD must be 1000 USD at 250, got % at % (beneficiary %)', v_r.a, v_r.r, v_r.ba; END IF;
  -- just below the tier it stays at 260
  v_op := pg_temp.zt_op('03', 249999);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Tier B', 'tierb@example.com', 1, 1, 'manual', 'vigente');
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 961 OR v_r.r IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 3: Zelle 249,999 GYD must be 961 USD at 260, got % at %', v_r.a, v_r.r; END IF;

  -- 4. Clasica and Tropical keep the single rate (250,000 GYD is 961 at 260, not 1000 at 250).
  v_cup := crm_tasa_vigente('usd');
  v_op := pg_temp.zt_op('04', 250000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'clasica', 'Card C', '9227123412341234', '52725088', 1, 1, 'manual', 'vigente');
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM floor(250000 / v_cup) OR v_r.r IS DISTINCT FROM v_cup THEN
    RAISE EXCEPTION 'case 4: Clasica must keep the single rate % (% USD), got % at %', v_cup, floor(250000 / v_cup), v_r.a, v_r.r; END IF;
  v_op := pg_temp.zt_op('05', 250000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'tropical', 'Card T', '9227123412341235', '52725089', 1, 1, 'manual', 'vigente');
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM floor(250000 / v_cup) OR v_r.r IS DISTINCT FROM v_cup THEN
    RAISE EXCEPTION 'case 4: Tropical must keep the single rate, got % at %', v_r.a, v_r.r; END IF;

  -- 5. A split deposit takes the tier from its TOTAL: 600 + 400 USD = 1,000 USD for 250,000 GYD is accepted, and the
  --    old 260 split (961 USD = 600 + 361) is not.
  v_op := pg_temp.zt_op('06', 250000);
  v_j := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"9542184382","nombre":"A B","monto":600,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"8132794817","nombre":"C D","monto":361,"moneda":"USD"}]');
  IF (v_j->>'aplicado')::boolean OR v_j->>'motivo' <> 'suma_no_cuadra' THEN
    RAISE EXCEPTION 'case 5: 961 USD must not cover a 250,000 GYD deposit, got %', v_j; END IF;
  v_j := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"9542184382","nombre":"A B","monto":600,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"8132794817","nombre":"C D","monto":400,"moneda":"USD"}]');
  IF NOT (v_j->>'aplicado')::boolean THEN RAISE EXCEPTION 'case 5: 600 + 400 USD must cover 250,000 GYD, got %', v_j; END IF;
  -- just below the tier the sum is 961
  v_op := pg_temp.zt_op('07', 249999);
  v_j := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"9542184382","nombre":"A B","monto":600,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"8132794817","nombre":"C D","monto":361,"moneda":"USD"}]');
  IF NOT (v_j->>'aplicado')::boolean THEN RAISE EXCEPTION 'case 5: 600 + 361 USD must cover 249,999 GYD, got %', v_j; END IF;

  -- 6. Mixed Zelle + CUP card on a 250,000 deposit: the Zelle part is priced at 250 (500 USD = 125,000 GYD), the card
  --    carries the other 125,000 GYD.
  v_cup := crm_tasa_vigente('gyd');
  v_cupamt := round(125000 * v_cup);
  v_op := pg_temp.zt_op('08', 250000);
  v_j := cerebro_aplicar_reparto(v_op, jsonb_build_array(
           jsonb_build_object('tipo','zelle','cuenta','9542184382','nombre','A B','monto',500,'moneda','USD'),
           jsonb_build_object('tipo','cuban_card','cuenta','9227123412341299','celular','52725099','nombre','E F','monto',v_cupamt,'moneda','CUP')));
  IF NOT (v_j->>'aplicado')::boolean THEN
    RAISE EXCEPTION 'case 6: Zelle 500 USD at 250 + card 125,000 GYD must cover 250,000 GYD, got %', v_j; END IF;

  -- 7. The Zelle remainder next to a USD card share uses the tier of the deposit total: 250,000 - 100 USD x 260 = 224,000
  --    GYD -> 896 USD at 250.
  v_op := pg_temp.zt_op('09', 250000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, amount_origin, position, block_index, source, status)
  VALUES (v_op, 'clasica', 'Card C', '9227123412341236', '52725090', 100, 'USD', 'manual', 1, 1, 'manual', 'vigente');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Rest Z', 'restz@example.com', 2, 2, 'manual', 'vigente');
  v_n := crm_monto_resto_zelle(v_op);
  IF v_n IS DISTINCT FROM 896 THEN RAISE EXCEPTION 'case 7: the Zelle remainder must be 896 USD, got %', v_n; END IF;

  -- 8. The bot's beneficiary resolver pairs "1000 zelle" with the 250,000 GYD operation.
  SELECT * INTO v_r FROM pg_temp.zt_conv('10');
  v_conv := v_r.o_conv; v_user := v_r.o_user; v_acc := v_r.o_acc; v_ct := v_r.o_ct;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 26000, t0 - interval '1 hour') RETURNING id INTO v_op2;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, created_at)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 250000, t0 + interval '45 seconds') RETURNING id INTO v_op;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'image', NULL, t0 - interval '2 seconds'),
    (v_conv, 'customer', 'text', '1000 zelle', t0 + interval '10 seconds'),
    (v_conv, 'customer', 'text', '786 344 7729 Jose Carlos Zayas', t0 + interval '25 seconds');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'], '7863447729');
  IF v_r.operation_id IS DISTINCT FROM v_op OR v_r.resultado <> 'unica' THEN
    RAISE EXCEPTION 'case 8: "1000 zelle" must resolve to the 250,000 GYD operation, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo; END IF;

  -- 9. The target the customer asks for in USD is priced by tier: 1,000 USD -> 250,000 GYD; 999 -> 259,740 at 260;
  --    2,000 -> 490,000 at 245.
  SELECT * INTO v_r FROM pg_temp.zt_conv('11');
  v_conv := v_r.o_conv;
  v_op := pg_temp.zt_op('12', 1000);
  UPDATE remittance_operations SET conversation_id = v_conv, contact_id = v_r.o_ct WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Obj Z', 'objz@example.com', 1, 1, 'manual', 'vigente');
  SELECT * INTO v_r FROM cerebro_fijar_objetivo(v_conv, 1000, 'usd');
  IF v_r.objetivo_gyd IS DISTINCT FROM 250000 THEN RAISE EXCEPTION 'case 9: 1000 USD must fix 250,000 GYD, got % (%)', v_r.objetivo_gyd, v_r.accion; END IF;
  SELECT * INTO v_r FROM cerebro_fijar_objetivo(v_conv, 999, 'usd');
  IF v_r.objetivo_gyd IS DISTINCT FROM 259740 THEN RAISE EXCEPTION 'case 9: 999 USD must fix 259,740 GYD, got %', v_r.objetivo_gyd; END IF;
  SELECT * INTO v_r FROM cerebro_fijar_objetivo(v_conv, 2000, 'usd');
  IF v_r.objetivo_gyd IS DISTINCT FROM 490000 THEN RAISE EXCEPTION 'case 9: 2000 USD must fix 490,000 GYD, got %', v_r.objetivo_gyd; END IF;
  SELECT * INTO v_r FROM cerebro_fijar_objetivo(v_conv, 100000, 'gyd');
  IF v_r.objetivo_gyd IS DISTINCT FROM 100000 THEN RAISE EXCEPTION 'case 9: a GYD target is untouched, got %', v_r.objetivo_gyd; END IF;

  -- 10. The calculator: a completed 250,000 GYD Zelle bills 250,000 at 250 (1,000 USD), invested at the buy rate.
  SELECT account_id INTO v_acc FROM whatsapp_config LIMIT 1;
  v_rates := calculator_rates_vigentes(v_acc);
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_op := pg_temp.zt_op('13', 250000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Cal Z', 'calz@example.com', 1, 1, 'manual', 'vigente');
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'ZELLE' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 1000
     OR v_e.usdt_sell_gyd IS DISTINCT FROM 250 OR v_e.facturado_gyd IS DISTINCT FROM 250000
     OR v_e.invertido_gyd IS DISTINCT FROM 1000 * v_rates.usdt_buy_gyd THEN
    RAISE EXCEPTION 'case 10: ZELLE line must be 1000 USD billed 250000 at 250, got % % % % % %',
      v_e.service, v_e.status, v_e.amount, v_e.usdt_sell_gyd, v_e.facturado_gyd, v_e.invertido_gyd; END IF;
  -- Clasica keeps the single rate in the calculator.
  v_op := pg_temp.zt_op('14', 250000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'clasica', 'Cal C', '9227123412341237', '52725091', 1, 1, 'manual', 'vigente');
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'CLASICA' OR v_e.amount IS DISTINCT FROM floor(250000 / v_rates.usdt_sell_gyd)
     OR v_e.usdt_sell_gyd IS DISTINCT FROM v_rates.usdt_sell_gyd THEN
    RAISE EXCEPTION 'case 10: CLASICA must keep the single rate, got % % %', v_e.service, v_e.amount, v_e.usdt_sell_gyd; END IF;

  -- 11. A pending ZELLE line resolved later is priced by tier too.
  v_op := pg_temp.zt_op('15', 250000);
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, service, amount, amount_currency,
                                             missing_inputs, completed_at)
  SELECT account_id, 'completed_operation', 'verified_pending', id, current_date, 'ZELLE', 250000, 'USD', ARRAY['usdtSellGyd'], now()
    FROM remittance_operations WHERE id = v_op
  RETURNING * INTO v_e;
  PERFORM crm_resolve_pending_entry(v_e.id, '{"usdt_sell_gyd": 260, "usdt_buy_gyd": 240}'::jsonb, 'tiered zelle');
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_e.id;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 1000 OR v_e.facturado_gyd IS DISTINCT FROM 250000
     OR v_e.invertido_gyd IS DISTINCT FROM 240000 OR v_e.usdt_sell_gyd IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 11: pending ZELLE must resolve to 1000 USD billed 250000 at 250, got % % % % %',
      v_e.status, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd, v_e.usdt_sell_gyd; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
