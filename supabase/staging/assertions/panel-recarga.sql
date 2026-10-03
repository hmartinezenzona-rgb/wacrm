-- =====================================================================
-- Assertion for migration 200 (recharges in the Operations panel). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/panel-other-services.md (R1). The panel listed only remesas; a manual close without beneficiary could not
-- say "recharge" (Yosvany 54c25086, production); a recharge number could not be added by hand.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t200(p_tag text, p_type text, p_status text, p_gyd numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900200' || p_tag, 'test200' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, p_status, p_type, 'GYD', p_gyd) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE v_acc uuid; v_admin uuid; v_op uuid; v_conv uuid; v_n int; v_ok boolean; v_r record;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. The panel lists an open recharge and its service type.
  v_op := pg_temp.op_t200('01', 'recarga', 'ready_to_transfer', 6200);
  SELECT conversation_id INTO v_conv FROM remittance_operations WHERE id = v_op;
  SELECT * INTO v_r FROM crm_operaciones_de_conversacion(v_conv) WHERE operation_id = v_op;
  IF v_r.operation_id IS NULL OR v_r.operation_service_type IS DISTINCT FROM 'recarga' THEN
    RAISE EXCEPTION 'case 1: the panel must list the recharge'; END IF;

  -- 2. A recharge number is added by hand (no card, no amount needed); a non-mobile is refused.
  PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "recarga", "phone": "53871234"}'::jsonb);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'recarga'
        AND phone = '53871234') <> 1 THEN RAISE EXCEPTION 'case 2: the number must be added'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "recarga", "phone": "78123456"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 2: a landline must be refused'; END IF;
  -- and a card cannot be added to a recharge
  v_ok := false;
  BEGIN PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "cuban_card", "card_number": "9235123487781111", "amount": 1, "currency": "CUP"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 2: a card on a recharge must be refused'; END IF;

  -- 3. Yosvany's shape: a remesa without beneficiary closed manually as a RECHARGE becomes one and reaches the calculator.
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": 23.1}'::jsonb, NULL);
  v_op := pg_temp.op_t200('03', 'remesa', 'ready_to_transfer', 6200);
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, false, 'recarga');
  SELECT o.service_type AS t, o.delivery_method AS m, e.service AS s INTO v_r
    FROM remittance_operations o LEFT JOIN remittance_calculator_entries e ON e.operation_id = o.id AND e.status <> 'void'
   WHERE o.id = v_op;
  IF v_r.t IS DISTINCT FROM 'recarga' OR v_r.m IS NOT NULL OR v_r.s IS DISTINCT FROM 'RECARGA' THEN
    RAISE EXCEPTION 'case 3: expected recarga / no method / RECARGA, got % / % / %', v_r.t, v_r.m, v_r.s; END IF;

  -- 4. Remesas still list and still refuse a recharge number.
  v_op := pg_temp.op_t200('04', 'remesa', 'collecting_information', 0);
  v_ok := false;
  BEGIN PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "recarga", "phone": "53871234"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4: a recharge number on a remesa must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
