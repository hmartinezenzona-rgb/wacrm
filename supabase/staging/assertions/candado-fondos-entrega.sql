-- =====================================================================
-- Assertion for migration 329 (money guards: verified funding + general recipient sums).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Cases, in order:
--   1. ready_to_transfer with no verified deposit -> delivery blocked (RED before 329).
--   2. the same operation with a linked deposit -> delivery passes.
--   3. mixed group: under-funded -> blocked; a second deposit covers it -> both members deliver.
--   4. an unlinked deposit matched by a receipt reference counts as funding (admin path).
--   5. cuban_card recipients 6,000 + 3,000 against 10,000 CUP -> blocked; 4,000 -> passes.
--   6. a recipient whose currency differs from the destination skips the sum gate (phase 1).
--   7. over-funding is allowed and the helper reports it.
--   8. cerebro_saldo_operacion counts the receipt-matched, unlinked deposit.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_op2 uuid;
  v_ok boolean; v_err text; v_status text;
  v_req numeric; v_dep numeric; v_cov boolean; v_obj numeric; v_saldo numeric;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ------------------------------------------------------------------
  -- Case 1: ready to transfer, no verified deposit -> must be blocked.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599329001', 'test329a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 329 A', 'a329@example.com', 100, 'USD', 1, 'vigente', 'manual');

  v_ok := true;
  BEGIN
    PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_ok := false; v_err := SQLERRM;
  END;
  IF v_ok THEN RAISE EXCEPTION 'case 1: delivered without verified funding'; END IF;
  IF v_err NOT LIKE '%verified funding%' THEN RAISE EXCEPTION 'case 1: unexpected error: %', v_err; END IF;
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 1: the blocked delivery changed the status to %', v_status; END IF;

  -- ------------------------------------------------------------------
  -- Case 2: a linked verified deposit lets the same operation deliver.
  -- ------------------------------------------------------------------
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000001', 26000, 'GYD', 'PRUEBA 329', now(), now(), v_op);
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'case 2: not delivered after funding (%): %', v_status, v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 3: mixed group funding is checked as a whole.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599329003', 'test329c') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  v_op2 := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'cuban_card', status = 'ready_to_transfer',
         quoted_source_amount = 10000, quoted_destination_amount = 50000, destination_currency = 'CUP',
         mixed_group_id = v_op
   WHERE id = v_op;
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 13000, quoted_destination_amount = 50, destination_currency = 'USD',
         mixed_group_id = v_op
   WHERE id = v_op2;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source)
  VALUES (v_op, 'cuban_card', 'PRUEBA 329 C1', '9234123456789012', '5355512301', 50000, 'CUP', 1, 'vigente', 'manual');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op2, 'zelle', 'PRUEBA 329 C2', 'c329@example.com', 50, 'USD', 1, 'vigente', 'manual');

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000003', 20000, 'GYD', 'PRUEBA 329', now(), now(), v_op);

  SELECT s.requerido, s.depositado, s.cubierto INTO v_req, v_dep, v_cov
    FROM cerebro_fondos_operacion(v_op2) s;
  IF v_req <> 23000 OR v_dep <> 20000 OR v_cov THEN
    RAISE EXCEPTION 'case 3: helper says required %, deposited %, covered % (expected 23000/20000/false)', v_req, v_dep, v_cov;
  END IF;

  v_ok := true;
  BEGIN
    PERFORM crm_entregar_operacion(v_op2, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_ok := false; v_err := SQLERRM;
  END;
  IF v_ok THEN RAISE EXCEPTION 'case 3: delivered an under-funded group member'; END IF;
  IF v_err NOT LIKE '%verified funding%' THEN RAISE EXCEPTION 'case 3: unexpected error: %', v_err; END IF;

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000004', 3000, 'GYD', 'PRUEBA 329', now(), now(), v_op2);
  PERFORM crm_entregar_operacion(v_op2, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT count(*) INTO v_req FROM remittance_operations
   WHERE id IN (v_op, v_op2) AND status = 'completed';
  IF v_req <> 2 THEN RAISE EXCEPTION 'case 3: % of the 2 group members completed', v_req; END IF;

  -- ------------------------------------------------------------------
  -- Case 4: an unlinked deposit matched by a receipt reference funds the operation.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599329004', 'test329d') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 13000, quoted_destination_amount = 50, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 329 D', 'd329@example.com', 50, 'USD', 1, 'vigente', 'manual');
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda)
  VALUES (v_conv, 13000, 'GYD')
  ON CONFLICT (conversation_id) DO UPDATE SET monto = excluded.monto, moneda = excluded.moneda, cerrado_en = NULL;
  -- The admin typed-TransID path consumes the deposit with operation_id NULL.
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000005', 13000, 'GYD', 'PRUEBA 329', now(), now(), NULL);
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, receipt_status, reference, source)
  VALUES (v_op, v_conv, 'COMP-329-05', 13000, 'GYD', 'EXITOSA', 'Ref: 32900000000005', 'bot');

  SELECT s.objetivo, s.depositado, s.saldo INTO v_obj, v_dep, v_saldo
    FROM cerebro_saldo_operacion(v_op) s;
  IF v_dep <> 13000 OR v_saldo <> 0 THEN
    RAISE EXCEPTION 'case 4: saldo says objective %, deposited %, balance % (expected 13000/13000/0)', v_obj, v_dep, v_saldo;
  END IF;
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'case 4: not delivered after the receipt-matched deposit (%)', v_status; END IF;

  -- ------------------------------------------------------------------
  -- Case 5: the recipient sum gate is not Zelle-only.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599329005', 'test329e') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'cuban_card', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 10000, destination_currency = 'CUP'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source)
  VALUES (v_op, 'cuban_card', 'PRUEBA 329 E1', '9234123456789013', '5355512302', 6000, 'CUP', 1, 'vigente', 'manual'),
         (v_op, 'cuban_card', 'PRUEBA 329 E2', '9234123456789014', '5355512303', 3000, 'CUP', 2, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000006', 26000, 'GYD', 'PRUEBA 329', now(), now(), v_op);

  v_ok := true;
  BEGIN
    PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_ok := false; v_err := SQLERRM;
  END;
  IF v_ok THEN RAISE EXCEPTION 'case 5: delivered cuban_card with recipients adding up to 9000 of 10000'; END IF;
  IF v_err NOT LIKE '%add up to 9000%' THEN RAISE EXCEPTION 'case 5: unexpected error: %', v_err; END IF;

  UPDATE remittance_beneficiaries SET amount = 4000
   WHERE operation_id = v_op AND name = 'PRUEBA 329 E2';
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'case 5: not delivered after completing the recipients (%)', v_status; END IF;

  -- ------------------------------------------------------------------
  -- Case 6: a recipient currency that differs from the destination skips the sum gate.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599329006', 'test329f') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 329 F', 'f329@example.com', 50, 'CUP', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000007', 26000, 'GYD', 'PRUEBA 329', now(), now(), v_op);
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'case 6: the mismatched currency should skip the sum gate (%)', v_status; END IF;

  -- ------------------------------------------------------------------
  -- Case 7: over-funding is allowed and reported.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599329007', 'test329g') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 13000, quoted_destination_amount = 50, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 329 G', 'g329@example.com', 50, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32900000000008', 26000, 'GYD', 'PRUEBA 329', now(), now(), v_op);
  SELECT s.requerido, s.depositado, s.cubierto INTO v_req, v_dep, v_cov
    FROM cerebro_fondos_operacion(v_op) s;
  IF v_req <> 13000 OR v_dep <> 26000 OR NOT v_cov THEN
    RAISE EXCEPTION 'case 7: helper says required %, deposited %, covered % (expected 13000/26000/true)', v_req, v_dep, v_cov;
  END IF;
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
