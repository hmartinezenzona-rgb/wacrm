\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- resolve-pending.sql — self-reverting assertion for
-- 105_calculator_resolve_pending.sql
--
-- Proves crm_resolve_pending_entry: admin+ only, the mandatory reason,
-- input validation, refusal to resolve an entry that is not pending,
-- refusal when the payload still leaves a required rate unset, the
-- coalesce rule (a rate the entry already snapshotted is never overwritten
-- by the payload), the repricing itself against the operation's deposit,
-- clearing of missing_inputs, and the audit row.
--
-- Fixture rates leave usdt_sell_gyd unset, so a completed ZELLE remesa of
-- 26000 GYD parks as pending with usdt_buy_gyd = 250 already snapshotted.
-- Resolving it with usdt_sell_gyd = 265 must give amount 98 (floor 98.11),
-- facturado 26000 (235: the deposit; was 98 x 265 = 25970), invertido 24500, retorno 1500 (was 1470).
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT resolve_pending;

DO $$
DECLARE
  v_account_id  uuid;
  v_owner_user  uuid := gen_random_uuid();
  v_admin_user  uuid := gen_random_uuid();
  v_agent_user  uuid := gen_random_uuid();
  v_contact_id  uuid;
  v_conv_id     uuid;
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_op_pending  uuid;
  v_op_ok       uuid;
  v_entry_id    uuid;
  v_ok_entry_id uuid;
  v_e           remittance_calculator_entries;
  v_count       integer;

  v_admin_claims text;
  v_agent_claims text;

  v_fail_count  integer := 0;
BEGIN
  v_admin_claims := json_build_object('sub', v_admin_user, 'role', 'authenticated')::text;
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'resolve-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'resolve-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'resolve-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'resolve pending test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'resolve owner', 'resolve-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user, 'resolve admin', 'resolve-admin-' || v_admin_user || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user, 'resolve agent', 'resolve-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550000902', v_account_id, 'Cliente Resolve')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  -- usdt_sell_gyd deliberately absent.
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_cup', 400));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle')
  RETURNING id INTO v_op_pending;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_pending;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT id INTO v_entry_id FROM remittance_calculator_entries WHERE operation_id = v_op_pending;

  -- ---- case 1: the fixture really is pending ----------------------------
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_entry_id;
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR NOT (v_e.missing_inputs @> ARRAY['usdtSellGyd'])
     OR v_e.usdt_buy_gyd IS DISTINCT FROM 250
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected a pending entry missing usdtSellGyd with usdt_buy_gyd 250; got status=% missing=% buy=%',
      v_e.status, v_e.missing_inputs, v_e.usdt_buy_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 1] the entry parks as pending with the rate it did have already snapshotted';
  END IF;

  -- ---- case 2: an agent cannot resolve ----------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    PERFORM crm_resolve_pending_entry(v_entry_id, jsonb_build_object('usdt_sell_gyd', 265), 'rate agreed that day');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected 42501 for an agent resolving an entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 2] resolving a pending entry is admin+';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 3: the reason is mandatory ----------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_resolve_pending_entry(v_entry_id, jsonb_build_object('usdt_sell_gyd', 265), 'ok');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected 22023 for a too-short reason';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 3] a resolution without a real reason is refused';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 3] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 4: unknown rate key -----------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_resolve_pending_entry(v_entry_id, jsonb_build_object('tarifa', 265), 'rate agreed that day');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected 22023 for an unknown rate key';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 4] an unknown rate key is refused';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5: a payload that still leaves a rate unset ------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_resolve_pending_entry(v_entry_id, jsonb_build_object('cup_global_rate', 2), 'wrong rate supplied');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected 22023 when the payload does not supply what is missing';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 5] supplying the wrong rate leaves the entry pending, not half-priced';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 6: resolve, and never overwrite a recorded rate --------------
  -- usdt_buy_gyd 999 in the payload must be ignored: the entry already has 250.
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_resolve_pending_entry(
    v_entry_id,
    jsonb_build_object('usdt_sell_gyd', 265, 'usdt_buy_gyd', 999),
    'rate agreed with the client that day');
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_entry_id;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 98
     OR v_e.facturado_gyd IS DISTINCT FROM 26000 OR v_e.invertido_gyd IS DISTINCT FROM 24500
     OR v_e.retorno_gyd IS DISTINCT FROM 1500 OR v_e.usdt_buy_gyd IS DISTINCT FROM 250
     OR v_e.usdt_sell_gyd IS DISTINCT FROM 265 OR v_e.missing_inputs IS NOT NULL
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected completed 98 / 26000 / 24500 / 1500 with buy kept at 250; got status=% amount=% f=% i=% r=% buy=% sell=% missing=%',
      v_e.status, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.usdt_buy_gyd, v_e.usdt_sell_gyd, v_e.missing_inputs;
  ELSE
    RAISE NOTICE 'PASS [case 6] the entry is repriced from the deposit, and the rate it already had is not overwritten';
  END IF;

  -- ---- case 7: the resolution is audited with its reason ----------------
  SELECT count(*) INTO v_count
    FROM remittance_admin_audit
   WHERE row_id = v_entry_id
     AND action = 'calculator_pending_resolved'
     AND reason = 'rate agreed with the client that day';
  IF v_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected exactly 1 audit row carrying the reason, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 7] the resolution is audited with the reason given';
  END IF;

  -- ---- case 8: an already-resolved entry cannot be resolved again --------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_resolve_pending_entry(v_entry_id, jsonb_build_object('usdt_sell_gyd', 300), 'trying to reprice it');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected 22023 when resolving an entry that is already completed';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 8] a resolved entry cannot be repriced by resolving it again';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 9: a non-existent entry -------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_resolve_pending_entry(gen_random_uuid(), jsonb_build_object('usdt_sell_gyd', 265), 'no such entry here');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] expected P0002 for a missing entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = 'P0002' THEN
      RAISE NOTICE 'PASS [case 9] a missing entry reports not-found';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 9] expected SQLSTATE P0002, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 10: the shared formulas still price a full-rate feed ---------
  -- 105 re-expressed calculator_feed_operation on the shared helpers; this
  -- proves a normal feed still lands on the same numbers as before.
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', 265));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, 'cuban_card')
  RETURNING id INTO v_op_ok;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_ok;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_ok;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 112500
     OR v_e.facturado_gyd IS DISTINCT FROM 75000 OR v_e.invertido_gyd IS DISTINCT FROM 70312.5
     OR v_e.retorno_gyd IS DISTINCT FROM 4687.5
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] the refactored feed changed the CUP numbers: amount=% f=% i=% r=%',
      v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 10] moving the formulas into shared helpers did not change what the feed computes';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'resolve-pending: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'resolve-pending: ALL PASS (10 expectations)';
END $$;

ROLLBACK TO SAVEPOINT resolve_pending;
