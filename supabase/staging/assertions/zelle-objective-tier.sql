-- =====================================================================
-- Assertion for migration 217 (a requested USD amount keeps its own tier price). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Fixtures build their own contacts, conversations and operations (user and account come from
-- whatsapp_config + profiles); never deals.
--
-- odd/tasks/zelle-tiered-rate.md (T3b). Owner decision: a customer who asks for an amount below a tier pays it at its own
-- tier's price (999 USD = 999 x 260 = 259,740 GYD) and receives what they asked for. When the operation's conversation has an
-- open USD send objective X and the deposit lies in [X*p, (X+1)*p) with p = cerebro_tasa_zelle(X), the Zelle amount is X USD at
-- p. Every other case is unchanged: no objective, or a deposit that does not match it, takes the best GYD tier.
-- Run it as: BEGIN; \i zelle-objective-tier.sql; ROLLBACK;
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.zo_conv(p_tag text, OUT o_user uuid, OUT o_acc uuid, OUT o_conv uuid, OUT o_ct uuid)
LANGUAGE plpgsql AS $$
BEGIN
  SELECT p.user_id, p.account_id INTO o_user, o_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (o_user, o_acc, '59900217' || p_tag, 'test217' || p_tag) RETURNING id INTO o_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (o_user, o_acc, o_ct) RETURNING id INTO o_conv;
END $$;

-- An open GYD remesa with one Zelle beneficiary, optionally with a USD objective set BEFORE the deposit amount lands.
CREATE OR REPLACE FUNCTION pg_temp.zo_op(p_tag text, p_gyd numeric, p_obj_usd numeric DEFAULT NULL, OUT o_op uuid, OUT o_conv uuid)
LANGUAGE plpgsql AS $$
DECLARE c record; v_r record;
BEGIN
  SELECT * INTO c FROM pg_temp.zo_conv(p_tag);
  o_conv := c.o_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency)
  VALUES (c.o_acc, c.o_conv, c.o_ct, 'ready_to_transfer', 'remesa', 'GYD') RETURNING id INTO o_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (o_op, 'zelle', 'Obj Z ' || p_tag, 'objz' || p_tag || '@example.com', 1, 1, 'manual', 'vigente');
  IF p_obj_usd IS NOT NULL THEN
    SELECT * INTO v_r FROM cerebro_fijar_objetivo(c.o_conv, p_obj_usd, 'usd');
    IF v_r.objetivo_gyd IS NULL THEN RAISE EXCEPTION 'fixture: the objective was not fixed (%)', v_r.accion; END IF;
  END IF;
  UPDATE remittance_operations SET quoted_source_amount = p_gyd WHERE id = o_op;
  PERFORM crm_calcular_monto_destino(o_op);
END $$;

DO $$
DECLARE
  v_op uuid; v_conv uuid; v_acc uuid; v_admin uuid; v_r record; v_e record; v_n numeric; v_rates calculator_rate_versions;
  v_cup numeric;
BEGIN
  -- 1. Objective 999 USD + 259,740 GYD deposit: 999 USD at 260 (not 1,038 at 250).
  SELECT * INTO v_r FROM pg_temp.zo_op('01', 259740, 999); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r, b.amount ba INTO v_r
    FROM remittance_operations o JOIN remittance_beneficiaries b ON b.operation_id = o.id AND b.status = 'vigente' WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 999 OR v_r.r IS DISTINCT FROM 260 OR v_r.ba IS DISTINCT FROM 999 THEN
    RAISE EXCEPTION 'case 1: objective 999 + 259,740 GYD must be 999 USD at 260, got % at % (beneficiary %)', v_r.a, v_r.r, v_r.ba; END IF;
  -- the same when the deposit lands first and the objective is fixed afterwards, then the amount is recomputed
  SELECT * INTO v_r FROM pg_temp.zo_op('02', 259740); v_op := v_r.o_op; v_conv := v_r.o_conv;
  SELECT quoted_destination_amount INTO v_n FROM remittance_operations WHERE id = v_op;
  IF v_n IS DISTINCT FROM 1038 THEN RAISE EXCEPTION 'case 1: before the objective 259,740 GYD is 1038 USD, got %', v_n; END IF;
  PERFORM cerebro_fijar_objetivo(v_conv, 999, 'usd');
  UPDATE remittance_operations SET quoted_destination_amount = NULL, quoted_destination_rate = NULL, quoted_destination_origin = NULL WHERE id = v_op;
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 999 OR v_r.r IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 1: objective fixed after the deposit must give 999 at 260, got % at %', v_r.a, v_r.r; END IF;

  -- 2. No objective: 259,740 GYD stays 1,038 USD at 250.
  SELECT * INTO v_r FROM pg_temp.zo_op('03', 259740); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1038 OR v_r.r IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 2: no objective, 259,740 GYD must be 1038 USD at 250, got % at %', v_r.a, v_r.r; END IF;

  -- 3. Objective 1,000 + 250,000: 1,000 at 250. 4. Objective 500 + 130,000: 500 at 260.
  SELECT * INTO v_r FROM pg_temp.zo_op('04', 250000, 1000); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1000 OR v_r.r IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 3: objective 1000 + 250,000 GYD must be 1000 at 250, got % at %', v_r.a, v_r.r; END IF;
  SELECT * INTO v_r FROM pg_temp.zo_op('05', 130000, 500); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 500 OR v_r.r IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 4: objective 500 + 130,000 GYD must be 500 at 260, got % at %', v_r.a, v_r.r; END IF;

  -- 5. A deposit that does not match the objective keeps the existing behaviour: the best GYD tier of the deposit.
  --    999 + 300,000 -> 1,200 USD at 250 (more than asked); 999 + 260,000 (just above the 999 window) -> 1,040 at 250;
  --    999 + 259,739 (just below it) -> 1,038 at 250; 999 + 200,000 -> 769 at 260 (less than asked).
  SELECT * INTO v_r FROM pg_temp.zo_op('06', 300000, 999); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1200 OR v_r.r IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 5: objective 999 + 300,000 GYD (not matching) must keep the GYD tier 1200 at 250, got % at %', v_r.a, v_r.r; END IF;
  SELECT * INTO v_r FROM pg_temp.zo_op('07', 260000, 999); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1040 OR v_r.r IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 5: objective 999 + 260,000 GYD must keep 1040 at 250, got % at %', v_r.a, v_r.r; END IF;
  SELECT * INTO v_r FROM pg_temp.zo_op('08', 259739, 999); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 1038 OR v_r.r IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'case 5: objective 999 + 259,739 GYD must keep 1038 at 250, got % at %', v_r.a, v_r.r; END IF;
  SELECT * INTO v_r FROM pg_temp.zo_op('09', 200000, 999); v_op := v_r.o_op;
  SELECT o.quoted_destination_amount a, o.quoted_destination_rate r INTO v_r FROM remittance_operations o WHERE o.id = v_op;
  IF v_r.a IS DISTINCT FROM 769 OR v_r.r IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 5: objective 999 + 200,000 GYD must keep 769 at 260, got % at %', v_r.a, v_r.r; END IF;

  -- 6. A closed objective or a GYD objective changes nothing.
  SELECT * INTO v_r FROM pg_temp.zo_op('10', 259740, 999); v_op := v_r.o_op; v_conv := v_r.o_conv;
  UPDATE cerebro_objetivo_envio SET cerrado_en = now() WHERE conversation_id = v_conv;
  UPDATE remittance_operations SET quoted_destination_amount = NULL, quoted_destination_rate = NULL, quoted_destination_origin = NULL WHERE id = v_op;
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT quoted_destination_amount INTO v_n FROM remittance_operations WHERE id = v_op;
  IF v_n IS DISTINCT FROM 1038 THEN RAISE EXCEPTION 'case 6: a closed objective must not apply, got % USD', v_n; END IF;

  -- 7. Clasica keeps the single rate whatever the objective says.
  v_cup := crm_tasa_vigente('usd');
  SELECT * INTO v_r FROM pg_temp.zo_op('11', 259740, 999); v_op := v_r.o_op;
  UPDATE remittance_beneficiaries SET beneficiary_type = 'clasica', zelle_account = NULL, card_number = '9227123412341299', phone = '52725099' WHERE operation_id = v_op;
  UPDATE remittance_operations SET quoted_destination_amount = NULL, quoted_destination_rate = NULL, quoted_destination_origin = NULL WHERE id = v_op;
  PERFORM crm_calcular_monto_destino(v_op);
  SELECT quoted_destination_amount a, quoted_destination_rate r INTO v_r FROM remittance_operations WHERE id = v_op;
  IF v_r.a IS DISTINCT FROM floor(259740 / v_cup) OR v_r.r IS DISTINCT FROM v_cup THEN
    RAISE EXCEPTION 'case 7: Clasica keeps the single rate, got % at %', v_r.a, v_r.r; END IF;

  -- 8. The calculator: a completed 259,740 GYD Zelle with the 999 objective bills 259,740 (999 USD at 260).
  SELECT account_id INTO v_acc FROM whatsapp_config LIMIT 1;
  v_rates := calculator_rates_vigentes(v_acc);
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM pg_temp.zo_op('12', 259740, 999); v_op := v_r.o_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'ZELLE' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 999
     OR v_e.usdt_sell_gyd IS DISTINCT FROM 260 OR v_e.facturado_gyd IS DISTINCT FROM 259740 THEN
    RAISE EXCEPTION 'case 8: ZELLE line must be 999 USD billed 259740 at 260, got % % % % %',
      v_e.service, v_e.status, v_e.amount, v_e.usdt_sell_gyd, v_e.facturado_gyd; END IF;
  -- and without the objective the same deposit bills 1,038 x 250
  SELECT * INTO v_r FROM pg_temp.zo_op('13', 259740); v_op := v_r.o_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.amount IS DISTINCT FROM 1038 OR v_e.usdt_sell_gyd IS DISTINCT FROM 250 OR v_e.facturado_gyd IS DISTINCT FROM 259500 THEN
    RAISE EXCEPTION 'case 8: no objective, ZELLE line must be 1038 USD billed 259500 at 250, got % % %', v_e.amount, v_e.usdt_sell_gyd, v_e.facturado_gyd; END IF;

  -- 9. A pending ZELLE line resolved later follows the objective too.
  SELECT * INTO v_r FROM pg_temp.zo_op('14', 259740, 999); v_op := v_r.o_op;
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, service, amount, amount_currency,
                                             missing_inputs, completed_at)
  SELECT account_id, 'completed_operation', 'verified_pending', id, current_date, 'ZELLE', 259740, 'USD', ARRAY['usdtSellGyd'], now()
    FROM remittance_operations WHERE id = v_op
  RETURNING * INTO v_e;
  PERFORM crm_resolve_pending_entry(v_e.id, '{"usdt_sell_gyd": 260, "usdt_buy_gyd": 240}'::jsonb, 'objective tier');
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_e.id;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 999 OR v_e.facturado_gyd IS DISTINCT FROM 259740
     OR v_e.usdt_sell_gyd IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'case 9: pending ZELLE must resolve to 999 USD billed 259740 at 260, got % % % %',
      v_e.status, v_e.amount, v_e.facturado_gyd, v_e.usdt_sell_gyd; END IF;

  -- 10. The Zelle remainder of a split deposit: 259,740 GYD with the 999 objective, a 100 USD Clasica share (26,000 GYD at the
  --     single rate 260) leaves 233,740 GYD = 899 USD at 260 (the tier of the TOTAL is the objective's).
  SELECT * INTO v_r FROM pg_temp.zo_op('15', 259740, 999); v_op := v_r.o_op;
  UPDATE remittance_beneficiaries SET zelle_account = 'restz217@example.com' WHERE operation_id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, amount_origin, position, block_index, source, status)
  VALUES (v_op, 'clasica', 'Card C217', '9227123412341288', '52725088', 100, 'USD', 'manual', 2, 2, 'manual', 'vigente');
  v_n := crm_monto_resto_zelle(v_op);
  IF v_n IS DISTINCT FROM floor((259740 - 100 * crm_tasa_vigente('usd')) / 260) THEN
    RAISE EXCEPTION 'case 10: the Zelle remainder must be priced at 260 (the objective tier), got % USD', v_n; END IF;

  -- 11. The bot's beneficiary resolver pairs "999 zelle" with the 259,740 GYD operation that carries the 999 objective.
  SELECT * INTO v_r FROM pg_temp.zo_conv('16');
  v_conv := v_r.o_conv; v_acc := v_r.o_acc;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_r.o_acc, v_conv, v_r.o_ct, 'ready_to_transfer', 'remesa', 'GYD', 259740) RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Obj Z 16', 'objz16@example.com', 1, 1, 'manual', 'vigente');
  PERFORM cerebro_fijar_objetivo(v_conv, 999, 'usd');
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'image', NULL, now() - interval '2 seconds'),
    (v_conv, 'customer', 'text', '999 zelle', now() + interval '10 seconds'),
    (v_conv, 'customer', 'text', '786 344 7729 Jose Carlos Zayas', now() + interval '25 seconds');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'], '7863447729');
  IF v_r.operation_id IS DISTINCT FROM v_op OR v_r.resultado <> 'unica' THEN
    RAISE EXCEPTION 'case 11: "999 zelle" must resolve to the 259,740 GYD operation, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
