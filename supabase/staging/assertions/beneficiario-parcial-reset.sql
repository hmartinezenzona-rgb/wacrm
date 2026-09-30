-- beneficiario-parcial-reset.sql — self-reverting assertion for
-- 155_reset_beneficiario_parcial_al_cerrar.sql
--
-- `cerebro_beneficiario_parcial` accumulates the recipient's data across
-- messages until it is complete. Nothing cleared it when the remesa closed,
-- and `Merge beneficiario` refreshes `actualizado` on every turn, so its 24 h
-- expiry never triggers in an active chat. The next message ("Gracias")
-- found the old data complete again and `Registrar zelle auto` /
-- `Registrar beneficiario auto` opened a NEW empty remesa with the same
-- beneficiary (production, 2026-09-30: Yilian, completed 13:16, zombie at
-- 13:23; 14 such remesas cancelled by hand in 45 days).
--
--   case 1 — the remesa is completed -> its conversation's accumulator is gone.
--   case 2 — the remesa is cancelled -> gone too.
--   case 3 — regression: a non-closing status change (ready_to_transfer)
--            keeps the accumulator (the data may still be arriving).
--   case 4 — another conversation's accumulator is never touched.
--
-- RED (before 155): cases 1 and 2 fail. GREEN (after 155): all four pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT beneficiario_parcial_reset;

DO $$
DECLARE
  v_owner_user uuid := gen_random_uuid();
  v_dummy_hash CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid;
  v_ct1 uuid; v_conv1 uuid; v_op1 uuid;
  v_ct2 uuid; v_conv2 uuid; v_op2 uuid;
  v_ct3 uuid; v_conv3 uuid; v_op3 uuid;
  v_ct4 uuid; v_conv4 uuid;
  v_n integer;
  v_fail_count integer := 0;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bpr-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'beneficiario parcial reset test account', v_owner_user)
  RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner_user, 'bpr owner', 'bpr-owner-' || v_owner_user || '@test.invalid', v_acc, 'owner');

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900155001', 'BPR 1', v_acc) RETURNING id INTO v_ct1;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct1, v_acc) RETURNING id INTO v_conv1;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900155002', 'BPR 2', v_acc) RETURNING id INTO v_ct2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct2, v_acc) RETURNING id INTO v_conv2;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900155003', 'BPR 3', v_acc) RETURNING id INTO v_ct3;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct3, v_acc) RETURNING id INTO v_conv3;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900155004', 'BPR 4', v_acc) RETURNING id INTO v_ct4;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct4, v_acc) RETURNING id INTO v_conv4;

  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv1, v_ct1, 'zelle', 'ready_to_transfer', 26000) RETURNING id INTO v_op1;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv2, v_ct2, 'cuban_card', 'collecting_information', 0) RETURNING id INTO v_op2;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv3, v_ct3, 'cuban_card', 'deposit_verification', 13000) RETURNING id INTO v_op3;

  INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_nombre, zelle_cuenta, zelle_nombre_cuenta, actualizado)
  VALUES (v_conv1, 'Liudis Prueba', '7860000001', '7860000001', now());
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta, celular, actualizado)
  VALUES (v_conv2, '9204000000001551', '53000155', now()),
         (v_conv3, '9204000000001553', '53000355', now()),
         (v_conv4, '9204000000001554', '53000455', now());

  -- Closing a remesa is an admin write (096's completion guard).
  PERFORM set_config('wacrm.origin', 'admin', true);

  -- ===========================================================================
  -- CASE 1 — completed.
  -- ===========================================================================
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op1;
  SELECT count(*) INTO v_n FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv1;
  IF v_n <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] completing the remesa left the accumulator (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 1] completed -> accumulator cleared';
  END IF;

  -- ===========================================================================
  -- CASE 2 — cancelled.
  -- ===========================================================================
  UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = v_op2;
  SELECT count(*) INTO v_n FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv2;
  IF v_n <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] cancelling the remesa left the accumulator (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 2] cancelled -> accumulator cleared';
  END IF;

  -- ===========================================================================
  -- CASE 3 — regression: a non-closing status change keeps it.
  -- ===========================================================================
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op3;
  SELECT count(*) INTO v_n FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv3;
  IF v_n <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a non-closing status change removed the accumulator (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 3] non-closing status change -> accumulator kept';
  END IF;

  -- ===========================================================================
  -- CASE 4 — another conversation is never touched.
  -- ===========================================================================
  SELECT count(*) INTO v_n FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv4;
  IF v_n <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] another conversation''s accumulator changed (rows=%)', v_n;
  ELSE
    RAISE NOTICE 'PASS [case 4] other conversations untouched';
  END IF;

  PERFORM set_config('wacrm.origin', '', true);

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'beneficiario-parcial-reset: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;
  RAISE NOTICE 'beneficiario-parcial-reset: ALL PASS (4 expectations)';
END $$;

ROLLBACK TO SAVEPOINT beneficiario_parcial_reset;
