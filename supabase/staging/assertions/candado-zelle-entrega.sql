-- =====================================================================
-- Assertion for migration 328 (Zelle delivery gate: recipients must add up).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
  v_ok boolean; v_err text; v_status text;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- Case 1: a 1,100 USD Zelle with 800 + 200 recipients is blocked; adding the missing 100 lets it deliver.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599001331', 'test328') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 275000, quoted_destination_amount = 1100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA A', 'a@example.com', 800, 'USD', 1, 'vigente', 'manual'),
         (v_op, 'zelle', 'PRUEBA B', 'b@example.com', 200, 'USD', 2, 'vigente', 'manual');

  v_ok := true;
  BEGIN
    PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_ok := false; v_err := SQLERRM;
  END;
  IF v_ok THEN RAISE EXCEPTION 'case 1: the delivery was not blocked'; END IF;
  IF v_err NOT LIKE '%add up to 1000%' THEN RAISE EXCEPTION 'case 1: unexpected error: %', v_err; END IF;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA C', 'c@example.com', 100, 'USD', 3, 'vigente', 'manual');
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'case 1: not delivered after completing the recipients (%): %', v_status, v_err; END IF;

  -- Case 2: a recipient without an amount skips the gate (the per-recipient amount is optional).
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '5990013311', 'test328b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA D', 'd@example.com', NULL, 'USD', 1, 'vigente', 'manual');
  PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op;
  IF v_status <> 'completed' THEN RAISE EXCEPTION 'case 2: a null amount should skip the gate, status %', v_status; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
