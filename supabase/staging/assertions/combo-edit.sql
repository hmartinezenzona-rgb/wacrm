-- =====================================================================
-- Assertion for migration 212 (editing and moving a combo recipient from the panel). Self-reverting: one DO block that
-- ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- crm_corregir_beneficiario and crm_reasignar_beneficiario wrote the new row with the remesa columns only, so a combo
-- recipient lost its address, reference and contact phone (and a cash recipient its address and ID photo); the panel
-- hid both buttons on combo cards (T2 of odd/tasks/combos-end-to-end.md).
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_op2 uuid; v_b uuid; v_new uuid; v_r record; v_ok boolean;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990021201', 'test212') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Ana Gomez', '53111222', 'Calle 1 #2, Vedado, La Habana', 'Casa azul', '53999000', 30000, 1);
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Luis Mora', '53333444', 'Calle 5, Holguin', 'Frente al parque', NULL, 25000, 2);
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'combo';
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  SELECT id INTO v_b FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND name = 'Ana Gomez';
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1. Correcting only the name keeps every other combo field.
  v_new := crm_corregir_beneficiario(v_b, '{"name": "Ana Gomez Diaz"}'::jsonb);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE id = v_new;
  IF v_r.beneficiary_type <> 'combo' OR v_r.name <> 'Ana Gomez Diaz' OR v_r.phone <> '53111222'
     OR v_r.address IS DISTINCT FROM 'Calle 1 #2, Vedado, La Habana' OR v_r.reference IS DISTINCT FROM 'Casa azul'
     OR v_r.contact_phone IS DISTINCT FROM '53999000' OR v_r.amount <> 30000 OR v_r.currency <> 'GYD' OR v_r.position <> 1 THEN
    RAISE EXCEPTION 'case 1: fields lost on correction: %', to_jsonb(v_r); END IF;

  -- 2. The combo fields themselves can be corrected, and a new amount updates the combo total.
  v_new := crm_corregir_beneficiario(v_new, '{"address": "Calle 1 #2, Playa, La Habana", "reference": "Casa verde", "contact_phone": "53888777", "amount": 35000}'::jsonb);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE id = v_new;
  IF v_r.address <> 'Calle 1 #2, Playa, La Habana' OR v_r.reference <> 'Casa verde' OR v_r.contact_phone <> '53888777' OR v_r.amount <> 35000 THEN
    RAISE EXCEPTION 'case 2: combo fields not corrected: %', to_jsonb(v_r); END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 60000 THEN
    RAISE EXCEPTION 'case 2: the combo total must follow the amounts (60000), got %', (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op); END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 2: the corrected combo must stay complete'; END IF;

  -- 3. Remesa-only fields, a bad contact phone or a type change are refused on a combo recipient.
  v_ok := false;
  BEGIN PERFORM crm_corregir_beneficiario(v_new, '{"card_number": "9227069999999999"}'::jsonb);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: a card on a combo recipient must be refused'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_corregir_beneficiario(v_new, '{"contact_phone": "12"}'::jsonb);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: a 2-digit contact phone must be refused'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_corregir_beneficiario(v_new, '{"beneficiary_type": "cuban_card"}'::jsonb);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: turning a combo recipient into a card must be refused'; END IF;

  -- 4. Moving a combo recipient to another open combo of the same conversation keeps its data; both totals follow.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'combo', 'GYD', 0) RETURNING id INTO v_op2;
  SELECT id INTO v_b FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND name = 'Luis Mora';
  v_new := crm_reasignar_beneficiario(v_b, v_op2);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE id = v_new;
  IF v_r.operation_id <> v_op2 OR v_r.address IS DISTINCT FROM 'Calle 5, Holguin' OR v_r.reference IS DISTINCT FROM 'Frente al parque'
     OR v_r.amount <> 25000 OR v_r.beneficiary_type <> 'combo' THEN
    RAISE EXCEPTION 'case 4: fields lost on the move: %', to_jsonb(v_r); END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 35000
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op2) <> 25000 THEN
    RAISE EXCEPTION 'case 4: totals after the move: % / %', (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op),
      (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op2); END IF;

  -- 5. A combo recipient cannot move into a remesa, nor a remesa beneficiary into a combo.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO v_op2;
  v_ok := false;
  BEGIN PERFORM crm_reasignar_beneficiario(v_new, v_op2);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: a combo recipient moved into a remesa'; END IF;

  -- 6. A cash recipient keeps its address and ID photo when its name is corrected.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'efectivo_usd', 'GYD', 29000) RETURNING id INTO v_op2;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, id_photo_wamid, position, block_index, source, status)
  VALUES (v_op2, 'efectivo_usd', 'Pedro', '53555666', 'Calle 8, Cerro, La Habana', 'wamid.TEST212', 1, 1, 'reparto_auto', 'vigente') RETURNING id INTO v_b;
  v_new := crm_corregir_beneficiario(v_b, '{"name": "Pedro Ruiz"}'::jsonb);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE id = v_new;
  IF v_r.address IS DISTINCT FROM 'Calle 8, Cerro, La Habana' OR v_r.id_photo_wamid IS DISTINCT FROM 'wamid.TEST212' THEN
    RAISE EXCEPTION 'case 6: the cash recipient lost its address or photo: %', to_jsonb(v_r); END IF;

  -- 7. A plain remesa card correction behaves as before (the old 'corrections' assertion has a stale deal fixture):
  --    the new card is stored, phone and amount kept, and a combo-only field is refused.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'cuban_card', 'GYD', 10000) RETURNING id INTO v_op2;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, amount, currency, position, block_index, source, status)
  VALUES (v_op2, 'cuban_card', '9227069911112222', '53121212', 30000, 'CUP', 1, 1, 'notes_parse', 'vigente') RETURNING id INTO v_b;
  v_new := crm_corregir_beneficiario(v_b, '{"card_number": "9227069933334444"}'::jsonb);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE id = v_new;
  IF v_r.card_number <> '9227069933334444' OR v_r.phone <> '53121212' OR v_r.amount <> 30000 OR v_r.currency <> 'CUP'
     OR v_r.beneficiary_type <> 'cuban_card' OR v_r.status <> 'vigente'
     OR (SELECT status FROM remittance_beneficiaries WHERE id = v_b) <> 'reemplazado' THEN
    RAISE EXCEPTION 'case 7: remesa correction changed: %', to_jsonb(v_r); END IF;
  v_ok := false;
  BEGIN PERFORM crm_corregir_beneficiario(v_new, '{"reference": "x"}'::jsonb);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7: a reference on a card beneficiary must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS';
END $$;
