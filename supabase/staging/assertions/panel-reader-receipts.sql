-- panel-reader-receipts.sql — assertion for 159
--
-- Proves:
--   1. An operation WITHOUT a deal (deal_id NULL, status 'deposit_verification')
--      returns a JSON that contains the receipt comp_id when the receipt exists
--      in remittance_operation_receipts. RED fails at this case with the old
--      099 code that reads deals.notes (which do not exist for this operation).
--   2. Two receipts on the same operation, both with comp_id set, are returned
--      ordered by block_index; a second receipt with the same comp_id is
--      rejected by the partial unique index (no duplicate), so we use a
--      different comp_id to test two distinct rows.
--
-- Fixture posture: same as operation-keyed-money.sql — real auth.users ->
-- accounts -> profiles, pipeline/stages for the remesas pipeline, contacts,
-- conversations. request.jwt.claims is set the same way add-beneficiary.sql
-- does (sub = user uuid, role = authenticated).
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker psql against staging, wrapped in BEGIN ... ROLLBACK).
-- Never COMMIT. Never run against production.

SAVEPOINT panel_reader_receipts;

DO $$
DECLARE
  v_owner_user    uuid := gen_random_uuid();
  v_account_id    uuid;
  v_contact       uuid;
  v_conv          uuid;
  v_op            uuid;
  v_comp_a        text := 'COMP-' || substr(md5(random()::text), 1, 20);
  v_comp_b        text := 'COMP-' || substr(md5(random()::text || 'b'), 1, 20);
  v_result        jsonb;
  v_receipts      jsonb;
  v_receipt0      jsonb;
  v_receipt1      jsonb;
  v_dummy_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'pr' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
    VALUES (gen_random_uuid(), 'panel reader test account', v_owner_user)
    RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
    VALUES (gen_random_uuid(), v_owner_user, 'panel reader owner', 'pr' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000999', 'Panel Reader Test', v_account_id)
    RETURNING id INTO v_contact;

  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact, v_account_id)
    RETURNING id INTO v_conv;

  -- Operation with deal_id NULL, status deposit_verification, service_type
  -- 'remesa', quoted_source_amount 40000, source_currency 'GYD'.
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                     status, service_type, quoted_source_amount, source_currency)
  VALUES (gen_random_uuid(), v_account_id, v_conv, v_contact, NULL,
          'deposit_verification', 'remesa', 40000, 'GYD')
  RETURNING id INTO v_op;

  -- One receipt row with comp_id set, amount 40000, currency 'GYD',
  -- reference '12345678901234', source 'bot'.
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, reference, source, block_index)
  VALUES (v_op, v_conv, v_comp_a, 40000, 'GYD', '12345678901234', 'bot', 1);

  -- Second receipt with a different comp_id so we can assert ordering.
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, reference, source, block_index)
  VALUES (v_op, v_conv, v_comp_b, 10000, 'GYD', '12345678901235', 'bot', 2);

  -- Set JWT claims so is_account_member passes.
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);

  -- ---- case 1: operation without deal -----------------------------------
  BEGIN
    v_result := crm_comprobantes_de_operacion(v_op);

    -- Must contain the comp_id of the first receipt.
    IF jsonb_array_length(v_result -> 'receipts') <> 2 THEN
      RAISE EXCEPTION 'FAIL [case 1] expected 2 receipts, got %',
        jsonb_array_length(v_result -> 'receipts');
    END IF;

    -- Both comp_ids must appear.
    IF NOT ((v_result -> 'receipts' -> 0 ->> 'comp_id') LIKE '%' || v_comp_a || '%'
            OR (v_result -> 'receipts' -> 1 ->> 'comp_id') LIKE '%' || v_comp_a || '%') THEN
      RAISE EXCEPTION 'FAIL [case 1a] receipt with comp_id % not found in result', v_comp_a;
    END IF;
    IF NOT ((v_result -> 'receipts' -> 0 ->> 'comp_id') LIKE '%' || v_comp_b || '%'
            OR (v_result -> 'receipts' -> 1 ->> 'comp_id') LIKE '%' || v_comp_b || '%') THEN
      RAISE EXCEPTION 'FAIL [case 1b] receipt with comp_id % not found in result', v_comp_b;
    END IF;

    -- deal_id must be NULL (this operation has no deal).
    IF (v_result ->> 'deal_id') IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [case 1c] deal_id should be NULL for this operation, got %', v_result ->> 'deal_id';
    END IF;

    -- status must be 'deposit_verification'.
    IF v_result ->> 'status' <> 'deposit_verification' THEN
      RAISE EXCEPTION 'FAIL [case 1d] expected status deposit_verification, got %', v_result ->> 'status';
    END IF;

    RAISE NOTICE 'PASS [case 1] deal-less operation returns receipts from remittance_operation_receipts';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FAIL [case 1] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 2: two receipts ordered by block_index ----------------------
  BEGIN
    v_result := crm_comprobantes_de_operacion(v_op);
    v_receipts := v_result -> 'receipts';
    v_receipt0 := v_receipts -> 0;
    v_receipt1 := v_receipts -> 1;

    -- First receipt should have comp_a (block_index 1), second comp_b (block_index 2).
    IF (v_receipt0 ->> 'comp_id') IS DISTINCT FROM v_comp_a THEN
      RAISE EXCEPTION 'FAIL [case 2a] first receipt should have comp_id %, got %',
        v_comp_a, v_receipt0 ->> 'comp_id';
    END IF;
    IF (v_receipt1 ->> 'comp_id') IS DISTINCT FROM v_comp_b THEN
      RAISE EXCEPTION 'FAIL [case 2b] second receipt should have comp_id %, got %',
        v_comp_b, v_receipt1 ->> 'comp_id';
    END IF;

    -- Amounts should match what we inserted.
    IF (v_receipt0 ->> 'declared_amount')::numeric IS DISTINCT FROM 40000 THEN
      RAISE EXCEPTION 'FAIL [case 2c] first receipt amount should be 40000, got %',
        v_receipt0 ->> 'declared_amount';
    END IF;
    IF (v_receipt1 ->> 'declared_amount')::numeric IS DISTINCT FROM 10000 THEN
      RAISE EXCEPTION 'FAIL [case 2d] second receipt amount should be 10000, got %',
        v_receipt1 ->> 'declared_amount';
    END IF;

    RAISE NOTICE 'PASS [case 2] two receipts ordered by block_index, amounts correct';
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'FAIL [case 2] % (%)', SQLERRM, SQLSTATE;
  END;

  RAISE NOTICE 'panel-reader-receipts: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT panel_reader_receipts;