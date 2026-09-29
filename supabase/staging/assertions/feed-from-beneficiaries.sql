-- feed-from-beneficiaries.sql — self-reverting assertion for
-- 141_calculator_feed_from_beneficiaries.sql
--
-- Proves the calculator feed resolves an operation's service from its
-- CURRENT `remittance_beneficiaries` rows instead of the stale
-- `remittance_operations.delivery_method` column (set only by the legacy
-- notes trigger, 042; never by the add-beneficiary RPC 123 or the reparto
-- RPCs 127/129).
--
-- BEFORE 141 (RED), the right reasons:
--   case 1 (2 Zelle, NULL delivery_method)  -> no entry at all, because
--     calculator_service_for_operation(NULL) is NULL.
--   case 2 (2 cuban_card, NULL delivery_method) -> same: no entry.
--   case 3 (mixed card + Zelle) -> no entry, and ALSO invisible in
--     calculator_unfed_operations, because that view's own filter drops any
--     row whose old-style service resolves to NULL.
--   case 5 (stale delivery_method='cuban_card' with Zelle-only current
--     beneficiaries) -> a WRONG CUP entry is fed, priced off the stale
--     column instead of the beneficiaries that actually win today.
--   case 4 (legacy op, no beneficiaries, delivery_method='cuban_card') is
--     the control: it must PASS unchanged both before and after 141.
--
-- AFTER 141 (GREEN): cases 1, 2, 5 resolve to the beneficiary-derived
-- service; case 4 is untouched. Case 3 (mixed) was entry-less and listed
-- as unfed under 141; since 142 it gets one pending line per service
-- (its fixtures carry no amounts), see feed-mixed.sql.
--
-- Rates: cup_global_rate=1.5, usdt_buy_gyd=250, usdt_sell_gyd=265,
-- usdt_sell_cup=400 (same as feed-matrix.sql, exact numeric results).
--   CUP basis 75000   -> amount 112500 (75000 * 1.5)
--   ZELLE basis 26000 -> amount 98 (floor(26000/265) = 98.11 -> 98; 111
--     moved the USD rails from ceil to floor, the LATEST definition on
--     staging — verified with pg_get_functiondef before writing this).
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT feed_from_beneficiaries;

DO $$
DECLARE
  v_account_id   uuid;
  v_owner_user   uuid := gen_random_uuid();
  v_admin_user   uuid := gen_random_uuid();
  v_agent_user   uuid := gen_random_uuid();
  v_contact_id   uuid;
  v_conv_id      uuid;
  v_dummy_hash   CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_agent_claims text;

  v_op_zelle2    uuid; -- case 1: 2 Zelle beneficiaries, NULL delivery_method
  v_op_card2     uuid; -- case 2: 2 cuban_card beneficiaries, NULL delivery_method
  v_op_mixed     uuid; -- case 3: 1 cuban_card + 1 zelle beneficiary
  v_op_legacy    uuid; -- case 4: no beneficiaries, delivery_method='cuban_card'
  v_op_stale     uuid; -- case 5: delivery_method='cuban_card' (stale), Zelle-only beneficiaries

  v_e            remittance_calculator_entries;
  v_count        integer;
  v_fail_count   integer := 0;
BEGIN
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fb-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fb-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fb-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'feed-from-beneficiaries test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'fb owner', 'fb-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user, 'fb admin', 'fb-admin-' || v_admin_user || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user, 'fb agent', 'fb-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550000902', v_account_id, 'Cliente FB')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 265, 'usdt_sell_cup', 400));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- operations -------------------------------------------------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, NULL)
  RETURNING id INTO v_op_zelle2;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, NULL)
  RETURNING id INTO v_op_card2;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, NULL)
  RETURNING id INTO v_op_mixed;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, 'cuban_card')
  RETURNING id INTO v_op_legacy;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'cuban_card')
  RETURNING id INTO v_op_stale;

  -- ---- beneficiaries (current, 'vigente') --------------------------------
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, status, source, block_index)
  VALUES
    (v_op_zelle2, 'zelle', 'Beneficiario A', 'a@zelle.test', 1, 'vigente', 'admin_addition', 1),
    (v_op_zelle2, 'zelle', 'Beneficiario B', 'b@zelle.test', 2, 'vigente', 'admin_addition', 1);

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, status, source, block_index)
  VALUES
    (v_op_card2, 'cuban_card', 'Beneficiario C', '1111222233334444', '55511112222', 1, 'vigente', 'admin_addition', 1),
    (v_op_card2, 'cuban_card', 'Beneficiario D', '5555666677778888', '55533334444', 2, 'vigente', 'admin_addition', 1);

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, status, source, block_index)
  VALUES (v_op_mixed, 'cuban_card', 'Beneficiario E', '1234123412341234', '55599998888', 1, 'vigente', 'admin_addition', 1);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, status, source, block_index)
  VALUES (v_op_mixed, 'zelle', 'Beneficiario F', 'f@zelle.test', 2, 'vigente', 'admin_addition', 1);

  -- v_op_legacy: no beneficiaries at all (the pre-042 shape).

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, status, source, block_index)
  VALUES
    (v_op_stale, 'zelle', 'Beneficiario G', 'g@zelle.test', 1, 'vigente', 'admin_addition', 1),
    (v_op_stale, 'zelle', 'Beneficiario H', 'h@zelle.test', 2, 'vigente', 'admin_addition', 1);

  -- ---- complete every operation, as a human (agent) actor ----------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = v_agent_user
   WHERE id IN (v_op_zelle2, v_op_card2, v_op_mixed, v_op_legacy, v_op_stale);
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- case 1: 2-Zelle op, NULL delivery_method -> ZELLE entry ----------
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_zelle2;
  IF v_e.service IS DISTINCT FROM 'ZELLE' OR v_e.amount IS DISTINCT FROM 98 OR v_e.status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected a ZELLE entry, amount 98; got service=% amount=% status=%',
      v_e.service, v_e.amount, v_e.status;
  ELSE
    RAISE NOTICE 'PASS [case 1] a 2-Zelle op with NULL delivery_method is fed as ZELLE, amount = floor(basis/usdt_sell_gyd)';
  END IF;

  -- ---- case 2: 2-card op, NULL delivery_method -> CUP entry -------------
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_card2;
  IF v_e.service IS DISTINCT FROM 'CUP' OR v_e.amount IS DISTINCT FROM 112500 OR v_e.status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected a CUP entry, amount 112500; got service=% amount=% status=%',
      v_e.service, v_e.amount, v_e.status;
  ELSE
    RAISE NOTICE 'PASS [case 2] a 2-card op with NULL delivery_method is fed as CUP';
  END IF;

  -- ---- case 3: mixed card + Zelle with NO amounts -----------------------
  -- Since 142 a mixed remesa gets one line per service. These fixtures carry
  -- no beneficiary amounts, so its share is unknown: two verified_pending
  -- lines naming 'beneficiaryAmounts', never an invented number.
  SELECT count(*) INTO v_count FROM remittance_calculator_entries
   WHERE operation_id = v_op_mixed AND status = 'verified_pending'
     AND 'beneficiaryAmounts' = ANY (missing_inputs);
  IF v_count <> 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a mixed op without amounts must get 2 pending lines naming beneficiaryAmounts, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 3a] a mixed op without amounts gets 2 pending lines (142)';
  END IF;

  SELECT count(*) INTO v_count FROM calculator_unfed_operations WHERE operation_id = v_op_mixed;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3b] a mixed op with a line per service is fed (pending), not unfed; found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 3b] the mixed op has a (pending) line per service, so it is not listed as unfed';
  END IF;

  -- ---- case 4: legacy op, no beneficiaries, delivery_method='cuban_card'
  -- Control case: behaviour must be unchanged, before and after 141.
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_legacy;
  IF v_e.service IS DISTINCT FROM 'CUP' OR v_e.amount IS DISTINCT FROM 112500 OR v_e.status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a legacy op with no beneficiaries must still be fed from delivery_method; got service=% amount=% status=%',
      v_e.service, v_e.amount, v_e.status;
  ELSE
    RAISE NOTICE 'PASS [case 4] a legacy op with no beneficiaries keeps the delivery_method mapping unchanged';
  END IF;

  -- ---- case 5: stale delivery_method='cuban_card', Zelle-only beneficiaries
  -- The beneficiaries must win over the stale column.
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_stale;
  IF v_e.service IS DISTINCT FROM 'ZELLE' OR v_e.amount IS DISTINCT FROM 98 OR v_e.status IS DISTINCT FROM 'completed' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a stale cuban_card column with current Zelle beneficiaries must be fed as ZELLE; got service=% amount=% status=%',
      v_e.service, v_e.amount, v_e.status;
  ELSE
    RAISE NOTICE 'PASS [case 5] current beneficiaries win over a stale delivery_method';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'feed-from-beneficiaries: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'feed-from-beneficiaries: ALL PASS (6 expectations)';
END $$;

ROLLBACK TO SAVEPOINT feed_from_beneficiaries;
