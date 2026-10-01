-- operation-keyed-money.sql — self-reverting assertion for 158
-- (operation_id on depositos_mmg and cerebro_objetivo_envio, the dual-write
-- trigger, the backfill statement, and the operation/deal twins).
--
-- Proves:
--   1. cerebro_saldo_operacion exists and, for an operation with an objetivo
--      of 40000 GYD and one consumed deposit of 25000 linked by deal_id (the
--      trigger filled operation_id), returns 40000 / 25000 / 15000;
--   2. cerebro_saldo_envio(deal) returns exactly the same row as
--      cerebro_saldo_operacion(op) for that case, and for a deal with no
--      objetivo and no deposits returns (NULL, 0, NULL, 'GYD');
--   3. an operation with deal_id NULL works end to end:
--      cerebro_objetivo_atar_op attaches the objective and a deposit with
--      operation_id set directly balances correctly;
--   4. cerebro_objetivo_cerrar_op closes the deal-less one, and
--      cerebro_objetivo_cerrar(deal) closes a deal-linked one;
--   5. the backfill statement fills operation_id on a row that has deal_id
--      but operation_id NULL.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (docker
-- psql against the staging URL, wrapped in BEGIN ... ROLLBACK). Never
-- COMMIT. Never run against production. Builds its own fixtures, same
-- posture as deterministic-usd-destination.sql: real auth.users -> accounts
-- -> profiles -> pipelines/pipeline_stages -> contacts -> conversations, with
-- every NOT NULL column filled. Column names verified against
-- reports/staging-columns-158.txt.
--
-- Deals are inserted with the two fixed ids the Cerebro pipeline uses, and
-- 125's trg_sync_operacion_al_crear_deal creates the operation for them
-- automatically — so case 5 can assert that the trigger really did it.
--
-- RED:   against staging WITHOUT 158 the run dies at case 1 — the function
--        does not exist. Case 1 raises on failure on purpose (no nested
--        handler), so RED stops there instead of reporting five failures.
-- GREEN: after 158 is applied — all cases PASS.

SAVEPOINT operation_keyed_money;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_contact_a      uuid;
  v_contact_b      uuid;
  v_contact_c      uuid;
  v_conv_a         uuid;
  v_conv_b         uuid;
  v_conv_c         uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_auto_stage     CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';

  v_deal_a         uuid;
  v_deal_b         uuid;
  v_deal_c         uuid;
  v_op_a           uuid;
  v_op_b           uuid;
  v_op_c           uuid;
  v_count          integer;
  v_uuid           uuid;
  v_obj            numeric;
  v_dep            numeric;
  v_sal            numeric;
  v_mon            text;
  v_fail_count     integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'opmoney-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(),
          '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
    VALUES (gen_random_uuid(), 'operation keyed money test account', v_owner_user)
    RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
    VALUES (gen_random_uuid(), v_owner_user, 'opmoney owner', 'opmoney-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  PERFORM 1 FROM pipelines WHERE id = v_pipeline_id;
  IF NOT FOUND THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position")
    VALUES (v_auto_stage, v_pipeline_id, 'Remesa abierta', 10) ON CONFLICT (id) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000801', 'OpMoney A', v_account_id) RETURNING id INTO v_contact_a;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact_a, v_account_id) RETURNING id INTO v_conv_a;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000802', 'OpMoney B', v_account_id) RETURNING id INTO v_contact_b;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact_b, v_account_id) RETURNING id INTO v_conv_b;

  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_owner_user, '15550000803', 'OpMoney C', v_account_id) RETURNING id INTO v_contact_c;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_owner_user, v_contact_c, v_account_id) RETURNING id INTO v_conv_c;

  -- ---- case 1: cerebro_saldo_operacion ---------------------------------
  -- Fails hard (no nested handler): this is where RED must die.
  BEGIN
    -- 125's trigger creates the operation for a remesas deal.
    INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                       stage_id, title, value, currency, notes, status)
    VALUES (v_owner_user, v_account_id, v_contact_a, v_conv_a, v_pipeline_id,
            v_auto_stage, 'Remesa +15550000801', 0, 'GYD', 'test', 'open')
    RETURNING id INTO v_deal_a;

    SELECT id INTO v_op_a FROM remittance_operations WHERE deal_id = v_deal_a;
    IF v_op_a IS NULL THEN
      RAISE EXCEPTION 'FAIL [case 1a] 125''s trigger created no operation for the deal';
    END IF;

    INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda) VALUES (v_conv_a, 40000, 'GYD');

    -- The dual-write trigger must fill operation_id from deal_id.
    INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, deal_id, consumido_en)
    VALUES ('opmoney-1-' || v_owner_user, 25000, 'GYD', 'test 158', now(), v_deal_a, now());

    SELECT operation_id INTO v_uuid FROM depositos_mmg WHERE trans_id = 'opmoney-1-' || v_owner_user;
    IF v_uuid IS NULL THEN
      RAISE EXCEPTION 'FAIL [case 1b] the trigger left operation_id NULL on the deposit';
    END IF;

    SELECT objetivo, depositado, saldo INTO v_obj, v_dep, v_sal FROM cerebro_saldo_operacion(v_op_a);
    IF v_obj <> 40000 OR v_dep <> 25000 OR v_sal <> 15000 THEN
      RAISE EXCEPTION 'FAIL [case 1c] objetivo/depositado/saldo = %/%/%, expected 40000/25000/15000',
        v_obj, v_dep, v_sal;
    END IF;

    RAISE NOTICE 'PASS [case 1] the trigger linked the deposit by operation and cerebro_saldo_operacion reads 40000/25000/15000';
  END;

  -- ---- case 2: the deal twin returns the same row -----------------------
  BEGIN
    SELECT objetivo, depositado, saldo, moneda INTO v_obj, v_dep, v_sal, v_mon
      FROM cerebro_saldo_envio(v_deal_a);
    IF v_obj <> 40000 OR v_dep <> 25000 OR v_sal <> 15000 OR v_mon <> 'GYD' THEN
      RAISE EXCEPTION 'FAIL [case 2a] cerebro_saldo_envio(deal) = %/%/%/%, expected the same 40000/25000/15000/GYD',
        v_obj, v_dep, v_sal, v_mon;
    END IF;

    -- A deal with no objetivo and no deposits: the one-row parity edge.
    INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                       stage_id, title, value, currency, notes, status)
    VALUES (v_owner_user, v_account_id, v_contact_b, v_conv_b, v_pipeline_id,
            v_auto_stage, 'Remesa +15550000802', 0, 'GYD', 'test', 'open')
    RETURNING id INTO v_deal_b;

    SELECT objetivo, depositado, saldo, moneda INTO v_obj, v_dep, v_sal, v_mon
      FROM cerebro_saldo_envio(v_deal_b);
    IF v_obj IS NOT NULL OR v_dep <> 0 OR v_sal IS NOT NULL OR v_mon <> 'GYD' THEN
      RAISE EXCEPTION 'FAIL [case 2b] empty deal = %/%/%/%, expected NULL/0/NULL/GYD',
        v_obj, v_dep, v_sal, v_mon;
    END IF;

    RAISE NOTICE 'PASS [case 2] cerebro_saldo_envio(deal) matches the operation row, and an empty deal still returns one row (NULL,0,NULL,GYD)';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 3: an operation with no deal at all -------------------------
  BEGIN
    INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status)
    VALUES (gen_random_uuid(), v_account_id, v_conv_c, v_contact_c, NULL, 'deposit_verification')
    RETURNING id INTO v_op_c;

    INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda) VALUES (v_conv_c, 10000, 'GYD');
    PERFORM cerebro_objetivo_atar_op(v_conv_c, v_op_c);

    SELECT operation_id INTO v_uuid FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_c;
    IF v_uuid IS DISTINCT FROM v_op_c THEN
      RAISE EXCEPTION 'FAIL [case 3a] cerebro_objetivo_atar_op left operation_id = %, expected %', v_uuid, v_op_c;
    END IF;

    -- Deposit attached by operation_id only: no deal anywhere.
    INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id, consumido_en)
    VALUES ('opmoney-3-' || v_owner_user, 3000, 'GYD', 'test 158', now(), v_op_c, now());

    SELECT objetivo, depositado, saldo INTO v_obj, v_dep, v_sal FROM cerebro_saldo_operacion(v_op_c);
    IF v_obj <> 10000 OR v_dep <> 3000 OR v_sal <> 7000 THEN
      RAISE EXCEPTION 'FAIL [case 3b] deal-less operation = %/%/%, expected 10000/3000/7000',
        v_obj, v_dep, v_sal;
    END IF;

    RAISE NOTICE 'PASS [case 3] an operation with deal_id NULL balances from operation_id alone';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 4: closing, both keys ---------------------------------------
  BEGIN
    PERFORM cerebro_objetivo_cerrar_op(v_op_c);
    SELECT count(*) INTO v_count FROM cerebro_objetivo_envio
     WHERE conversation_id = v_conv_c AND cerrado_en IS NOT NULL;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'FAIL [case 4a] cerebro_objetivo_cerrar_op closed % row(s), expected 1', v_count;
    END IF;

    -- The deal-linked objective of case 1 is still open; close it by deal.
    PERFORM cerebro_objetivo_atar(v_conv_a, v_deal_a);
    IF NOT EXISTS (SELECT 1 FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_a
                    AND deal_id = v_deal_a AND operation_id = v_op_a) THEN
      RAISE EXCEPTION 'FAIL [case 4b0] cerebro_objetivo_atar(deal) did not set both deal_id and operation_id';
    END IF;
    PERFORM cerebro_objetivo_cerrar(v_deal_a);
    SELECT count(*) INTO v_count FROM cerebro_objetivo_envio
     WHERE conversation_id = v_conv_a AND cerrado_en IS NOT NULL;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'FAIL [case 4b] cerebro_objetivo_cerrar(deal) closed % row(s), expected 1', v_count;
    END IF;

    RAISE NOTICE 'PASS [case 4] both close entry points closed exactly their own objective';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- case 5: the backfill statement -----------------------------------
  BEGIN
    INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id,
                       stage_id, title, value, currency, notes, status)
    VALUES (v_owner_user, v_account_id, v_contact_c, v_conv_c, v_pipeline_id,
            v_auto_stage, 'Remesa +15550000803', 0, 'GYD', 'test', 'open')
    RETURNING id INTO v_deal_c;

    SELECT id INTO v_op_b FROM remittance_operations WHERE deal_id = v_deal_c;
    IF v_op_b IS NULL THEN
      RAISE EXCEPTION 'FAIL [case 5a] 125''s trigger created no operation for the deal';
    END IF;

    INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, deal_id, consumido_en)
    VALUES ('opmoney-5-' || v_owner_user, 5000, 'GYD', 'test 158', now(), v_deal_c, now());

    -- Simulate a pre-158 row: keep deal_id, drop the mirror the trigger set.
    -- The trigger is UPDATE OF deal_id only, so this UPDATE cannot re-fire it.
    UPDATE depositos_mmg SET operation_id = NULL
     WHERE trans_id = 'opmoney-5-' || v_owner_user;

    SELECT operation_id INTO v_uuid FROM depositos_mmg WHERE trans_id = 'opmoney-5-' || v_owner_user;
    IF v_uuid IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [case 5b] could not simulate the pre-158 row: operation_id is still %', v_uuid;
    END IF;

    -- The backfill statement, verbatim from 158 item 2.
    UPDATE depositos_mmg t
       SET operation_id = (SELECT ro.id
                             FROM remittance_operations ro
                            WHERE ro.deal_id = t.deal_id)
     WHERE t.deal_id IS NOT NULL
       AND t.operation_id IS NULL;

    SELECT operation_id INTO v_uuid FROM depositos_mmg WHERE trans_id = 'opmoney-5-' || v_owner_user;
    IF v_uuid IS DISTINCT FROM v_op_b THEN
      RAISE EXCEPTION 'FAIL [case 5c] the backfill set operation_id = %, expected %', v_uuid, v_op_b;
    END IF;

    RAISE NOTICE 'PASS [case 5] the backfill statement re-linked the deal_id-only row';
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] % (%)', SQLERRM, SQLSTATE;
  END;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'operation-keyed-money: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'operation-keyed-money: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT operation_keyed_money;
