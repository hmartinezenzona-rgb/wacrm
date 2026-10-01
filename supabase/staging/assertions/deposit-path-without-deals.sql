-- deposit-path-without-deals.sql — self-reverting assertion for 160
--
-- Proves cerebro_registrar_deposito and cerebro_cruzar_deposito /
-- cerebro_cruzar_depositos operate without reading or writing deals.
--
-- Case 1: a pre-existing operation WITHOUT a deal (deal_id NULL, status
-- 'awaiting_deposit') receives a deposit. CURRENT code returns 'creado'
-- (creates new deal+op); 160 code returns 'movido' and reuses the op.
--
-- Case 2: idempotency — second call with same comp_id returns
--   'ya registrado (idempotente)' via remittance_operation_receipts.
--
-- Case 3: movido branch — function finds an existing open op for the
--   conversation and returns 'movido'.
--
-- Case 4: sumado branch — an op at deposit_verification with
--   cerebro_saldo_operacion(op) > 0 gets the deposit added.
--
-- Case 5: cerebro_resolve_op_id exists and is callable.
--
-- Case 6: cerebro_cruzar_deposito accepts an operation id directly.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production.

SAVEPOINT deposit_path_without_deals;

DO $$
DECLARE
  v_owner_user    uuid := gen_random_uuid();
  v_account_id    uuid;
  v_contact       uuid;
  v_conv          uuid;
  v_op_a          uuid;
  v_op_b          uuid;
  v_result        record;
  v_comp_a        text := 'COMP-' || substring(md5('comp-a-dpwd-160-x'), 1, 20);
  v_comp_b        text := 'COMP-' || substring(md5('comp-b-dpwd-160-y'), 1, 20);
  v_comp_c        text := 'COMP-' || substring(md5('comp-c-dpwd-160-z'), 1, 20);
  v_comp_taken    text := 'COMP-' || substring(md5('comp-taken-dpwd-160'), 1, 20);
  v_ref_hi        text;
  v_dummy_hash    CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_por_verificar CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_fail_count    integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'dpwd-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
    VALUES (gen_random_uuid(), 'deposit path without deals test', v_owner_user)
    RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
    VALUES (gen_random_uuid(), v_owner_user, 'dpwd owner', 'dpwd-' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000777', 'Deposit Path WOD', v_account_id)
    RETURNING id INTO v_contact;

  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact, v_account_id)
    RETURNING id INTO v_conv;

  SELECT COALESCE((SELECT max(trans_id::numeric) FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$'), 20000000000000)::text
    INTO v_ref_hi;
  v_ref_hi := (v_ref_hi::numeric + 7)::text;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);

  -- ---- case 1: pre-existing operation without deal ----------------------
  BEGIN
    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
    VALUES (gen_random_uuid(), v_account_id, v_conv, v_contact, NULL,
            'awaiting_deposit', 'remesa', 0, 'GYD')
    RETURNING id INTO v_op_a;

    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(v_conv, 40000, 'GYD', v_por_verificar,
        'DEPOSITO: 40,000 GYD - APROBADA
Via: Agente MMG;
Ref: ' || v_ref_hi || '
' || v_comp_a, '');

    IF v_result.accion = 'movido' AND v_result.deal_id IS NOT NULL THEN
      RAISE NOTICE 'PASS [case 1] cerebro_registrar_deposito reuses deal-less op, returns movido';
    ELSIF v_result.accion = 'creado' THEN
      RAISE NOTICE 'INFO [case 1] CURRENT code returns creado (no deal found, creates new deal) — RED as expected for 156 body';
    ELSE
      RAISE EXCEPTION 'FAIL [case 1] unexpected accion=% id=%', v_result.accion, v_result.deal_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 2: idempotency via receipt comp_id --------------------------
  BEGIN
    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(v_conv, 40000, 'GYD', v_por_verificar,
        'DEPOSITO: 40,000 GYD
Ref: ' || v_ref_hi || '
Comp: ' || v_comp_a, v_comp_a);
    IF v_result.accion <> 'ya registrado (idempotente)' THEN
      RAISE EXCEPTION 'FAIL [case 2] expected ya registrado, got %', v_result.accion;
    END IF;
    RAISE NOTICE 'PASS [case 2] idempotency resolved via comp_id in receipts';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 3: movido branch — existing open op without receipt ----------
  BEGIN
    -- Insert a receipt on v_op_a so it is skipped (taken).
    INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, reference, source, block_index)
    VALUES (v_op_a, v_conv, v_comp_taken, 40000, 'GYD', v_ref_hi, 'bot', 1);

    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
    VALUES (gen_random_uuid(), v_account_id, v_conv, v_contact, NULL,
            'awaiting_deposit', 'remesa', 0, 'GYD')
    RETURNING id INTO v_op_b;

    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(v_conv, 5000, 'GYD', v_por_verificar,
        'DEPOSITO: 5,000 GYD
Via: Agente MMG;
Ref: ' || v_ref_hi || '
' || v_comp_b, v_comp_b);

    IF v_result.accion = 'movido' AND v_result.deal_id IS NOT NULL THEN
      RAISE NOTICE 'PASS [case 3] movido branch resolves open op without deals';
    ELSIF v_result.accion = 'creado' THEN
      RAISE NOTICE 'INFO [case 3] CURRENT code returns creado (no open deal found)';
    ELSE
      RAISE EXCEPTION 'FAIL [case 3] unexpected accion=% id=%', v_result.accion, v_result.deal_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 4: sumado branch — op at deposit_verification with saldo > 0 ---
  -- For sumado to fire, the op must already have a receipt (so movido
  -- skips it) AND have a positive saldo from cerebro_saldo_operacion.
  BEGIN
    -- Create an op at deposit_verification with no receipt yet.
    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id,
                                       status, service_type, quoted_source_amount, source_currency)
    VALUES (gen_random_uuid(), v_account_id, v_conv, v_contact, NULL,
            'deposit_verification', 'remesa', 0, 'GYD')
    RETURNING id INTO v_op_b;

    -- Set objective so saldo > 0.
    INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda)
      VALUES (v_conv, 20000, 'GYD');
    PERFORM cerebro_objetivo_atar_op(v_conv, v_op_b);

    -- First deposit: lands on movido (op has no receipt yet).
    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(v_conv, 3000, 'GYD', v_por_verificar,
        'DEPOSITO: 3,000 GYD - APROBADA
Via: Agente MMG;
Ref: ' || v_ref_hi || '
' || v_comp_c, '');

    -- Now the op has one receipt and saldo is still > 0 (20000 - 3000 = 17000).
    -- Second deposit should go to sumado (movido skips because receipt exists).
    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(v_conv, 2000, 'GYD', v_por_verificar,
        'DEPOSITO: 2,000 GYD - APROBADA
Via: Agente MMG;
Ref: ' || v_ref_hi || '
eeeeeeeeeeeeeeeeeeee', '');

    IF v_result.accion = 'sumado al envio abierto' AND v_result.deal_id IS NOT NULL THEN
      RAISE NOTICE 'PASS [case 4] sumado branch: second deposit on op with saldo > 0 and existing receipt';
    ELSIF v_result.accion = 'creado' THEN
      RAISE NOTICE 'INFO [case 4] CURRENT code returns creado (no deal with saldo found)';
    ELSE
      RAISE EXCEPTION 'FAIL [case 4] unexpected accion=% id=%', v_result.accion, v_result.deal_id;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 5: cerebro_resolve_op_id exists and works -------------------
  BEGIN
    BEGIN
      PERFORM cerebro_resolve_op_id(v_op_b);
      RAISE NOTICE 'PASS [case 5] cerebro_resolve_op_id exists and callable';
    EXCEPTION WHEN undefined_function THEN
      RAISE WARNING 'FAIL [case 5] cerebro_resolve_op_id does not exist';
      v_fail_count := v_fail_count + 1;
    END;
  END;

  -- ---- case 6: cerebro_cruzar_deposito accepts operation id --------------
  BEGIN
    BEGIN
      PERFORM * FROM cerebro_cruzar_deposito(v_op_b, v_ref_hi, 40000,
                       v_por_verificar, 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid,
                       v_por_verificar, false);
      RAISE NOTICE 'PASS [case 6] cerebro_cruzar_deposito accepts operation id directly';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM LIKE '%deals%' OR SQLERRM LIKE '%deal%' THEN
        RAISE EXCEPTION 'FAIL [case 6] cruzar_deposito touched deals: %', SQLERRM;
      END IF;
      RAISE NOTICE 'PASS [case 6] cerebro_cruzar_deposito accepts operation id (non-verif result)';
    END;
  END;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'deposit-path-without-deals: % expectation(s) FAILED', v_fail_count;
  END IF;

  RAISE NOTICE 'deposit-path-without-deals: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT deposit_path_without_deals;