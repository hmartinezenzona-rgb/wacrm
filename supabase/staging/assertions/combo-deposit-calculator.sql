-- =====================================================================
-- Assertion for migration 209 (a combo deposit lands on the combo; a completed combo feeds the calculator as COMBO).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging (and production after the
-- owner's go-ahead).
--
-- odd/tasks/combos-end-to-end.md (T1b). The MMG deposit of a customer ordering a combo goes to the combo (open, or
-- opened by the deposit when the customer asked for a combo), as a recharge deposit goes to a recharge. The calculator
-- line of a combo is COMBO: facturado = the deposit, invertido = the cost the admin entered (GYD), pending
-- (missing comboCosto) until then.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t209(p_tag text, p_texts text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_i int := 0; v_t text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;  -- not from conversations: staging can have none after a reset
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900209' || p_tag, 'test209' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  FOREACH v_t IN ARRAY p_texts LOOP
    v_i := v_i + 1;
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (v_conv, 'customer', 'text', v_t, now() - make_interval(mins => 30 - v_i));
  END LOOP;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.ops_t209(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || o.quoted_source_amount::int, ';' ORDER BY o.created_at, o.service_type), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE
  v_conv uuid; v_conv2 uuid; v_op uuid; v_e record; v_acc uuid; v_admin uuid; v_res text; v_n int;
  c_verif constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
BEGIN
  -- (211) A typed recharge needs a promo running: these cases run with one.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-209-211'), 'confirmada');
  SELECT w.account_id INTO v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. A deposit with an open combo lands on the combo: no new remesa, service_type stays combo.
  v_conv := pg_temp.conv_t209('01', ARRAY['hola', 'quiero mandar un combo']);
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Maria Perez', '53871234', 'Calle 10 #45, Vedado, La Habana', 'Frente a la bodega azul', '53999888', 30000);
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'combo';
  IF v_op IS NULL THEN RAISE EXCEPTION 'case 1: fixture combo did not open'; END IF;
  PERFORM cerebro_registrar_deposito(v_conv, 30000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv) <> 'combo/deposit_verification/30000' THEN
    RAISE EXCEPTION 'case 1: the deposit must land on the open combo, got %', pg_temp.ops_t209(v_conv); END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 1 THEN
    RAISE EXCEPTION 'case 1: the recipient must stay on the combo'; END IF;

  -- 2. No open op, the customer said combo: the deposit creates a combo operation (not a remesa).
  v_conv2 := pg_temp.conv_t209('02', ARRAY['hola buenas', 'quiero mandar un combo']);
  PERFORM cerebro_registrar_deposito(v_conv2, 25000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv2) <> 'combo/deposit_verification/25000' THEN
    RAISE EXCEPTION 'case 2: a combo conversation must open a combo, got %', pg_temp.ops_t209(v_conv2); END IF;

  -- 2b. The same with the other phrasing: "mandar comida".
  v_conv2 := pg_temp.conv_t209('12', ARRAY['quiero mandar comida para Cuba']);
  PERFORM cerebro_registrar_deposito(v_conv2, 25000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv2) <> 'combo/deposit_verification/25000' THEN
    RAISE EXCEPTION 'case 2b: "mandar comida" must open a combo, got %', pg_temp.ops_t209(v_conv2); END IF;

  -- 3. A plain remesa conversation still creates a remesa (also when it mentions "comida" in passing).
  v_conv2 := pg_temp.conv_t209('03', ARRAY['hola, quiero mandar dinero', 'son 7000 para la comida de mi mama']);
  PERFORM cerebro_registrar_deposito(v_conv2, 7000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv2) <> 'remesa/deposit_verification/7000' THEN
    RAISE EXCEPTION 'case 3: a remesa conversation must still create a remesa, got %', pg_temp.ops_t209(v_conv2); END IF;

  -- 4. A recharge conversation still goes to recarga.
  v_conv2 := pg_temp.conv_t209('04', ARRAY['quiero una recarga']);
  PERFORM cerebro_registrar_deposito(v_conv2, 6200, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv2) <> 'recarga/deposit_verification/6200' THEN
    RAISE EXCEPTION 'case 4: a recharge conversation must still create a recarga, got %', pg_temp.ops_t209(v_conv2); END IF;

  -- 5. Both apply: the OPEN operation wins; with no open operation, recarga as before.
  v_conv2 := pg_temp.conv_t209('05', ARRAY['quiero un combo', 'y tambien una recarga']);
  PERFORM crm_registrar_destinatario_combo(v_conv2, 'Ana Gil', '53111222', NULL, NULL, NULL, NULL);
  PERFORM cerebro_registrar_deposito(v_conv2, 25000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv2) <> 'combo/deposit_verification/25000' THEN
    RAISE EXCEPTION 'case 5a: an open combo beats the recharge text, got %', pg_temp.ops_t209(v_conv2); END IF;
  v_conv2 := pg_temp.conv_t209('15', ARRAY['quiero un combo', 'y tambien una recarga']);
  PERFORM cerebro_registrar_deposito(v_conv2, 6200, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t209(v_conv2) <> 'recarga/deposit_verification/6200' THEN
    RAISE EXCEPTION 'case 5b: with nothing open the recharge wins as before, got %', pg_temp.ops_t209(v_conv2); END IF;

  -- 6. Completing the combo with no cost: a pending COMBO line naming comboCosto.
  -- the deposit was verified (the cross itself is service-agnostic and out of this assertion's scope)
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'COMBO' OR v_e.status IS DISTINCT FROM 'verified_pending'
     OR v_e.missing_inputs IS DISTINCT FROM ARRAY['comboCosto'] THEN
    RAISE EXCEPTION 'case 6: expected a pending COMBO line missing comboCosto, got % % %', v_e.service, v_e.status, v_e.missing_inputs; END IF;
  IF v_e.amount IS DISTINCT FROM 30000 OR v_e.amount_currency IS DISTINCT FROM 'GYD' OR v_e.basis_gyd IS DISTINCT FROM 30000
     OR v_e.facturado_gyd IS NOT NULL OR v_e.invertido_gyd IS NOT NULL THEN
    RAISE EXCEPTION 'case 6: the pending line carries the deposit only, got % % % % %', v_e.amount, v_e.amount_currency, v_e.basis_gyd, v_e.facturado_gyd, v_e.invertido_gyd; END IF;

  -- 7. The admin sets the cost: the line is fed (facturado = deposit, invertido = cost, retorno = difference).
  PERFORM crm_set_combo_costo(v_op, 18000);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.missing_inputs IS NOT NULL
     OR v_e.facturado_gyd IS DISTINCT FROM 30000 OR v_e.invertido_gyd IS DISTINCT FROM 18000 OR v_e.retorno_gyd IS DISTINCT FROM 12000 THEN
    RAISE EXCEPTION 'case 7: expected completed 30000/18000/12000, got % % / % / % / %', v_e.status, v_e.missing_inputs, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd; END IF;
  IF v_e.cost_gyd IS DISTINCT FROM 18000 OR v_e.sale_gyd IS DISTINCT FROM 30000 THEN
    RAISE EXCEPTION 'case 7: the snapshot reads cost / sale, got % / %', v_e.cost_gyd, v_e.sale_gyd; END IF;

  -- 8. Setting it again updates the same line (no duplicate); clearing it makes the line pending again.
  PERFORM crm_set_combo_costo(v_op, 20000);
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_n <> 1 OR v_e.invertido_gyd IS DISTINCT FROM 20000 OR v_e.retorno_gyd IS DISTINCT FROM 10000 THEN
    RAISE EXCEPTION 'case 8: expected ONE line 20000/10000, got % lines, % / %', v_n, v_e.invertido_gyd, v_e.retorno_gyd; END IF;
  PERFORM crm_set_combo_costo(v_op, NULL);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR v_e.missing_inputs IS DISTINCT FROM ARRAY['comboCosto'] THEN
    RAISE EXCEPTION 'case 8: clearing the cost leaves the line pending, got % %', v_e.status, v_e.missing_inputs; END IF;
  -- 8b. A pending COMBO line is resolved by its cost in the panel, never with rates (crm_resolve_pending_entry refuses).
  BEGIN
    PERFORM crm_resolve_pending_entry(v_e.id, '{"usdt_buy_gyd": 230}'::jsonb, 'assert combo resolve');
    RAISE EXCEPTION 'case 8b: a COMBO line was resolved with rates';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM NOT LIKE '%combo%' THEN RAISE EXCEPTION 'case 8b: refused for another reason: %', SQLERRM; END IF;
  END;
  PERFORM crm_set_combo_costo(v_op, 0);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.retorno_gyd IS DISTINCT FROM 30000 THEN
    RAISE EXCEPTION 'case 8: a zero cost is a cost (profit = deposit), got % %', v_e.status, v_e.retorno_gyd; END IF;

  -- 9. Cost entered BEFORE the combo is completed: no line yet; completing feeds it already priced.
  v_conv2 := pg_temp.conv_t209('09', ARRAY['quiero un combo']);
  PERFORM crm_registrar_destinatario_combo(v_conv2, 'Luis Mora', '53222333', 'Calle 1 #2, Holguin', 'Esquina', '53444555', 26000);
  PERFORM cerebro_registrar_deposito(v_conv2, 26000, 'GYD', c_verif, NULL, NULL);
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = v_conv2 AND service_type = 'combo';
  PERFORM crm_set_combo_costo(v_op, 15000);
  IF EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE operation_id = v_op) THEN
    RAISE EXCEPTION 'case 9: an open combo must not feed the calculator'; END IF;
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'COMBO' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.retorno_gyd IS DISTINCT FROM 11000 THEN
    RAISE EXCEPTION 'case 9: expected COMBO completed with profit 11000, got % % %', v_e.service, v_e.status, v_e.retorno_gyd; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
