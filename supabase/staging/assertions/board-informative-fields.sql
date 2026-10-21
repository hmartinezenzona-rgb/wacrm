-- =====================================================================
-- Assertion for migration 258 (crm_tablero_operaciones also returns the rail types, the quoted destination amount and
-- currency, the recipient label and count, and mixed_group_id). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Fixtures build their own account, user, contact and operations.
-- Cases: 1 Zelle with name -> label = name, types {zelle}; 2 CUP card without name -> 'Tarjeta ·1234'; 3 recarga -> phone;
-- 4 two beneficiaries -> count 2 (ordered by block_index, position) and replaced ones ignored; 5 destination amount and
-- currency; 6 mixed_group_id; 7 no beneficiaries -> empty array, NULL label, count 0.
-- Run it as: BEGIN; \i board-informative-fields.sql; ROLLBACK;
-- =====================================================================
DO $$
DECLARE
  v_user  uuid := gen_random_uuid();
  v_acc   uuid;
  v_ct    uuid;
  v_conv  uuid;
  v_op1   uuid;
  v_op2   uuid;
  v_op3   uuid;
  v_op4   uuid;
  v_op5   uuid;
  v_mix   uuid;
  v_hash  text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_r     record;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'info-a-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'board info account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'board info agent', 'info-a-' || v_user || '@test.invalid', v_acc, 'agent');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900258', 'Board Info Customer') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- Operations
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method, quoted_destination_amount, destination_currency)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 18200, NULL, 70, 'USD') RETURNING id INTO v_op1;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 20000) RETURNING id INTO v_op2;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'recarga', 'GYD', 5000) RETURNING id INTO v_op3;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 40000) RETURNING id INTO v_op4;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 1000) RETURNING id INTO v_op5;

  -- op1 is a member of op4's mixed group (mixed_group_id references remittance_operations.id).
  v_mix := v_op4;
  UPDATE remittance_operations SET mixed_group_id = v_mix WHERE id = v_op1;

  -- Beneficiaries
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (v_op1, 'zelle', 'Maria Perez', 'maria@example.test', 1, 1, 'vigente');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, position, block_index, status)
  VALUES (v_op2, 'cuban_card', '  ', '9225123456781234', 1, 1, 'vigente');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, status)
  VALUES (v_op3, 'recarga', '53512345', 1, 1, 'vigente');
  -- op4: a replaced row that must be ignored, then two current rows: block 2 position 1 must come AFTER block 1 position 2.
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, position, block_index, status, replaced_at)
  VALUES (v_op4, 'tropical', 'Old Name', '1111222233334444', 1, 1, 'reemplazado', now());
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (v_op4, 'zelle', 'Second Block', 'second@example.test', 1, 2, 'vigente');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, position, block_index, status)
  VALUES (v_op4, 'clasica', 'First Block', '5555666677778888', 2, 1, 'vigente');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1. Zelle with a name: label is the name, types {zelle}, count 1.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op1;
  IF v_r.recipient_label IS DISTINCT FROM 'Maria Perez' OR v_r.beneficiary_types IS DISTINCT FROM ARRAY['zelle']::text[] OR v_r.recipient_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'case 1: %', to_jsonb(v_r); END IF;
  -- 5. Destination amount and currency.
  IF v_r.quoted_destination_amount IS DISTINCT FROM 70::numeric OR v_r.destination_currency IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case 5: %', to_jsonb(v_r); END IF;
  -- 6. mixed_group_id.
  IF v_r.mixed_group_id IS DISTINCT FROM v_mix THEN RAISE EXCEPTION 'case 6: %', to_jsonb(v_r); END IF;

  -- 2. CUP card without a name (blank): 'Tarjeta ·1234'.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op2;
  IF v_r.recipient_label IS DISTINCT FROM 'Tarjeta ·1234' OR v_r.beneficiary_types IS DISTINCT FROM ARRAY['cuban_card']::text[] THEN
    RAISE EXCEPTION 'case 2: %', to_jsonb(v_r); END IF;
  -- (a trigger fills the quoted destination of a CUP remesa itself, so only mixed_group_id is expected NULL here)
  IF v_r.mixed_group_id IS NOT NULL THEN RAISE EXCEPTION 'case 2b: expected NULL mixed_group_id: %', to_jsonb(v_r); END IF;

  -- 3. Recarga: label is the phone.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op3;
  IF v_r.recipient_label IS DISTINCT FROM '53512345' OR v_r.beneficiary_types IS DISTINCT FROM ARRAY['recarga']::text[] THEN
    RAISE EXCEPTION 'case 3: %', to_jsonb(v_r); END IF;

  -- 4. Two current beneficiaries (replaced ignored), ordered by block_index then position.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op4;
  IF v_r.recipient_count IS DISTINCT FROM 2 OR v_r.beneficiary_types IS DISTINCT FROM ARRAY['clasica', 'zelle']::text[] OR v_r.recipient_label IS DISTINCT FROM 'First Block' THEN
    RAISE EXCEPTION 'case 4: %', to_jsonb(v_r); END IF;

  -- 7. No beneficiaries.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op5;
  IF v_r.operation_id IS NULL THEN RAISE EXCEPTION 'case 7: the operation is not on the board'; END IF;
  IF v_r.beneficiary_types IS DISTINCT FROM ARRAY[]::text[] OR v_r.recipient_label IS NOT NULL OR v_r.recipient_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'case 7: %', to_jsonb(v_r); END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
