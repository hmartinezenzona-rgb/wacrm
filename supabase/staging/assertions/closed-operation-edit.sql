-- =====================================================================
-- Assertion for migration 383 (an owner or admin edits a COMPLETED or CANCELLED operation from the panel: its amounts, recipients and service).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA383', phones 5990383xxxx.
-- 151 closed operations were touched by the developer's audited corrections (2026-10-03..11-13). The panel refused every edit of a closed
-- operation ("operation is closed"). Now an owner or an admin may; an agent still may not. The edit changes the operation, not the money: the
-- calculator is fed only when the status changes (so no line is added), and the destination amount is not recomputed at today's rate for a closed
-- operation (crm_calcular_monto_destino skips them). Every closed edit leaves an extra audit row `human_closed_operation_edit` with the function.
-- Cases:
--   1  owner: correct the operation (amount, destination amount), correct a recipient, add a recipient, remove a recipient, change the service of
--      a COMPLETED operation; each works, each leaves the closed-edit audit row, the status stays completed, no calculator line appears and the
--      destination amount typed is kept
--   2  the same on a CANCELLED operation (the correction of the operation)
--   3  an agent is refused on a closed operation, in the five functions ("operation is closed", 22023); on an open operation an agent still works
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_op2 uuid; v_op3 uuid; v_b uuid; v_b2 uuid; v_new uuid; v_row remittance_operations%ROWTYPE; v_n int; v_ok boolean; v_entries int;
  v_f text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990383001', 'PRUEBA383 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  -- a completed Zelle remesa with two recipients, a completed one without recipients, a cancelled one
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, destination_currency, quoted_destination_amount, quoted_destination_origin)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 13000, 'zelle', 'USD', 50, 'manual') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status) VALUES
    (v_op, 'zelle', 'PRUEBA Titular Uno', 'prueba383a@example.com', 25, 'USD', 1, 1, 'notes_parse', 'vigente'),
    (v_op, 'zelle', 'PRUEBA Titular Dos', 'prueba383b@example.com', 25, 'USD', 2, 2, 'notes_parse', 'vigente');
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op2;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op3;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id IN (v_op, v_op2);
  UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = v_op3;
  PERFORM set_config('wacrm.origin', '', true);
  SELECT count(*) INTO v_entries FROM remittance_calculator_entries WHERE operation_id IN (v_op, v_op2, v_op3);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1 owner on a completed operation
  PERFORM crm_corregir_operacion(v_op, '{"quoted_source_amount": 26000, "quoted_destination_amount": 100}'::jsonb);
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.quoted_source_amount <> 26000 OR v_row.quoted_destination_amount <> 100 OR v_row.status <> 'completed' THEN RAISE EXCEPTION 'case 1: the operation correction was not applied: %', to_jsonb(v_row); END IF;
  SELECT id INTO v_b FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND position = 1;
  v_new := crm_corregir_beneficiario(v_b, '{"name": "PRUEBA Titular Nuevo"}'::jsonb);
  IF (SELECT name FROM remittance_beneficiaries WHERE id = v_new) <> 'PRUEBA Titular Nuevo' OR (SELECT status FROM remittance_beneficiaries WHERE id = v_b) <> 'reemplazado' THEN RAISE EXCEPTION 'case 1: the recipient correction was not applied'; END IF;
  PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type":"zelle","name":"PRUEBA Titular Tres","zelle_account":"prueba383c@example.com","amount":10,"currency":"USD"}'::jsonb);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 3 THEN RAISE EXCEPTION 'case 1: the recipient was not added'; END IF;
  SELECT id INTO v_b2 FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND position = 2;
  PERFORM crm_quitar_beneficiario(v_b2);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 2 THEN RAISE EXCEPTION 'case 1: the recipient was not removed'; END IF;
  PERFORM crm_cambiar_servicio(v_op2, 'tropical');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) <> 'tropical' OR (SELECT status FROM remittance_operations WHERE id = v_op2) <> 'completed' THEN
    RAISE EXCEPTION 'case 1: the service change was not applied or the operation was reopened'; END IF;
  FOREACH v_f IN ARRAY ARRAY['crm_corregir_operacion', 'crm_corregir_beneficiario', 'crm_agregar_beneficiario', 'crm_quitar_beneficiario', 'crm_cambiar_servicio'] LOOP
    IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE action = 'human_closed_operation_edit' AND after ->> 'via' = v_f AND row_id IN (v_op, v_op2)) THEN
      RAISE EXCEPTION 'case 1: the closed-edit audit row for % is missing', v_f; END IF;
  END LOOP;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE operation_id IN (v_op, v_op2, v_op3);
  IF v_n <> v_entries THEN RAISE EXCEPTION 'case 1: editing a closed operation must not feed the calculator (% -> %)', v_entries, v_n; END IF;
  IF (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op) <> 100 THEN RAISE EXCEPTION 'case 1: the typed destination amount must be kept'; END IF;

  -- 2 cancelled
  PERFORM crm_corregir_operacion(v_op3, '{"quoted_source_amount": 14000}'::jsonb);
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op3) <> 14000 OR (SELECT status FROM remittance_operations WHERE id = v_op3) <> 'cancelled' THEN RAISE EXCEPTION 'case 2: the cancelled operation correction failed'; END IF;

  -- 3 an agent is refused on a closed operation, still works on an open one
  UPDATE profiles SET account_role = 'agent' WHERE user_id = v_user;
  SELECT id INTO v_b FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' ORDER BY position LIMIT 1;
  v_ok := false; BEGIN PERFORM crm_corregir_operacion(v_op, '{"quoted_source_amount": 27000}'::jsonb); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an agent must be refused: crm_corregir_operacion'; END IF;
  v_ok := false; BEGIN PERFORM crm_corregir_beneficiario(v_b, '{"name": "x"}'::jsonb); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an agent must be refused: crm_corregir_beneficiario'; END IF;
  v_ok := false; BEGIN PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type":"zelle","name":"x","zelle_account":"x@example.com","amount":1,"currency":"USD"}'::jsonb); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an agent must be refused: crm_agregar_beneficiario'; END IF;
  v_ok := false; BEGIN PERFORM crm_quitar_beneficiario(v_b); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an agent must be refused: crm_quitar_beneficiario'; END IF;
  v_ok := false; BEGIN PERFORM crm_cambiar_servicio(v_op2, 'zelle'); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an agent must be refused: crm_cambiar_servicio'; END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op3;
  PERFORM crm_corregir_operacion(v_op3, '{"quoted_source_amount": 15000}'::jsonb);
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op3) <> 15000 THEN RAISE EXCEPTION 'case 3: an agent must still correct an open operation'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
