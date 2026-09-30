-- objetivo-compromiso-cliente-recurrente.sql — self-reverting assertion for
-- 152_objetivo_compromiso_envio_en_curso.sql
--
-- Proves the A3 gate holds for a RETURNING customer. 148 counted a vigente
-- beneficiary of ANY operation (also completed ones) and ANY receipt ever
-- sent by the phone, so a customer with one past remesa always passed the
-- gate and a bare quote kept creating a target (found in a real staging
-- test on 2026-09-30).
--
--   case 1 — returning customer (completed remesa with a vigente beneficiary,
--            receipt sent before it closed), bare quote -> NO target.
--   case 2 — same customer opens a new remesa and its beneficiary is
--            registered -> the quote DOES set the target.
--   case 3 — returning customer who sends a receipt AFTER the last closed
--            remesa -> the quote DOES set the target.
--   case 4 — regression: brand-new customer, bare quote -> NO target.
--
-- RED (against 148): case 1 fails (the target is created).
-- GREEN (after 152): all four pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT objetivo_compromiso_recurrente;

DO $$
DECLARE
  v_owner_user  uuid := gen_random_uuid();
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc         uuid;
  v_ct1 uuid; v_conv1 uuid; v_op_old1 uuid; v_op_new1 uuid;
  v_ct3 uuid; v_conv3 uuid; v_op_old3 uuid;
  v_ct4 uuid; v_conv4 uuid;
  v_n           integer;
  v_fail_count  integer := 0;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ocr-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'objetivo recurrente test account', v_owner_user)
  RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner_user, 'ocr owner', 'ocr-owner-' || v_owner_user || '@test.invalid', v_acc, 'owner');

  -- A completed remesa is inserted as an admin write so 096's completion
  -- guard does not coerce it to 'incident' (same as 150's assertion).
  PERFORM set_config('wacrm.origin', 'admin', true);

  -- ---- customer 1: one past remesa, closed yesterday --------------------
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner_user, '59900152001', 'OCR Recurrente 1', v_acc) RETURNING id INTO v_ct1;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_ct1, v_acc) RETURNING id INTO v_conv1;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, created_at, completed_at)
  VALUES (v_acc, v_conv1, v_ct1, 'cuban_card', 'completed', now() - interval '2 days', now() - interval '1 day')
  RETURNING id INTO v_op_old1;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status, source)
  VALUES (v_op_old1, 'cuban_card', '9204000000001521', '53000152', 'vigente', 'reparto_auto');
  INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, fecha_recibido, whatsapp_message_id)
  VALUES ('ocr-hash-old-1-' || v_conv1, '59900152001', 'COMP-ocr-old-1', now() - interval '2 days', 'wamid.ocr.old.1');

  -- ---- customer 3: past remesa closed, then a NEW receipt ----------------
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner_user, '59900152003', 'OCR Recurrente 3', v_acc) RETURNING id INTO v_ct3;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_ct3, v_acc) RETURNING id INTO v_conv3;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, created_at, completed_at)
  VALUES (v_acc, v_conv3, v_ct3, 'cuban_card', 'completed', now() - interval '2 days', now() - interval '1 day')
  RETURNING id INTO v_op_old3;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status, source)
  VALUES (v_op_old3, 'cuban_card', '9204000000003521', '53000352', 'vigente', 'reparto_auto');
  INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, fecha_recibido, whatsapp_message_id)
  VALUES ('ocr-hash-new-3-' || v_conv3, '59900152003', 'COMP-ocr-new-3', now() - interval '5 minutes', 'wamid.ocr.new.3');

  -- ---- customer 4: brand new -------------------------------------------
  INSERT INTO contacts (id, user_id, phone, name, account_id)
  VALUES (gen_random_uuid(), v_owner_user, '59900152004', 'OCR Nuevo 4', v_acc) RETURNING id INTO v_ct4;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_ct4, v_acc) RETURNING id INTO v_conv4;

  PERFORM set_config('wacrm.origin', '', true);

  -- ===========================================================================
  -- CASE 1 — returning customer, bare quote: no target.
  -- ===========================================================================
  PERFORM cerebro_fijar_objetivo(v_conv1, 26000, 'GYD');
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv1;
  IF v_n <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] a returning customer''s bare quote created a target (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 1] returning customer, bare quote -> no target';
  END IF;

  -- ===========================================================================
  -- CASE 2 — same customer, new open remesa with its beneficiary: target set.
  -- ===========================================================================
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status)
  VALUES (v_acc, v_conv1, v_ct1, 'cuban_card', 'collecting_information')
  RETURNING id INTO v_op_new1;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status, source)
  VALUES (v_op_new1, 'cuban_card', '9204000000001522', '53000153', 'vigente', 'reparto_auto');
  PERFORM cerebro_fijar_objetivo(v_conv1, 26000, 'GYD');
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv1 AND monto = 26000;
  IF v_n <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a new open remesa with a beneficiary should set the target (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 2] new open remesa with beneficiary -> target set';
  END IF;

  -- ===========================================================================
  -- CASE 3 — returning customer, receipt after the last closed remesa.
  -- ===========================================================================
  PERFORM cerebro_fijar_objetivo(v_conv3, 13000, 'GYD');
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv3 AND monto = 13000;
  IF v_n <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a receipt after the last closed remesa should set the target (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 3] receipt after the last closed remesa -> target set';
  END IF;

  -- ===========================================================================
  -- CASE 4 — regression: brand-new customer, bare quote.
  -- ===========================================================================
  PERFORM cerebro_fijar_objetivo(v_conv4, 26000, 'GYD');
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv4;
  IF v_n <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a new customer''s bare quote created a target (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 4] new customer, bare quote -> no target';
  END IF;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'objetivo-compromiso-cliente-recurrente: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;
  RAISE NOTICE 'objetivo-compromiso-cliente-recurrente: ALL PASS (4 expectations)';
END $$;

ROLLBACK TO SAVEPOINT objetivo_compromiso_recurrente;
