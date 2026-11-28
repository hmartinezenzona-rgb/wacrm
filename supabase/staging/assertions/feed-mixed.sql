\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- feed-mixed.sql — self-reverting assertion for
-- 142_calculator_mixed_remesas.sql
--
-- A MIXED remesa (current beneficiaries of more than one type, e.g. a Cuban
-- card + a Zelle account paid by one deposit, see 129) gets ONE ledger line
-- PER service, each priced on its own share of the deposit:
--   CUP part   basis = sum of the card beneficiaries' CUP / cup_global_rate
--   USD part   basis = the rest of the deposit (its floor rounding absorbs the
--              under-1-USD leftover, exactly as a single-Zelle remesa does)
--
-- Rates: cup_global_rate=1.5, usdt_buy_gyd=250, usdt_sell_gyd=265,
-- usdt_sell_cup=400 (same as feed-matrix.sql).
-- Mixed op: deposit 75000 GYD; card 30000 CUP (-> 20000 GYD); Zelle 207 USD.
--   CUP line:   basis 20000 -> amount 30000
--   ZELLE line: basis 55000 -> amount floor(55000/265) = 207
--
-- BEFORE 142 (RED): the mixed op has no ledger line at all (141 leaves it
-- unresolved), stays in calculator_unfed_operations, and the financial close
-- does not see it.
-- AFTER 142 (GREEN): all expectations below.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (psql -1). Never COMMIT. Never run against production.

SAVEPOINT feed_mixed;

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
  v_admin_claims text;

  v_op_mixed     uuid; -- card 30000 CUP + Zelle 207 USD, deposit 75000
  v_op_gap       uuid; -- card + Zelle, the Zelle amount unknown

  v_e            remittance_calculator_entries;
  v_count        integer;
  v_close        jsonb;
  v_fail_count   integer := 0;
BEGIN
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;
  v_admin_claims := json_build_object('sub', v_admin_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fm-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fm-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'fm-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'feed-mixed test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'fm owner', 'fm-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user, 'fm admin', 'fm-admin-' || v_admin_user || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user, 'fm agent', 'fm-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550000903', v_account_id, 'Cliente FM')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 265, 'usdt_sell_cup', 400));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, NULL)
  RETURNING id INTO v_op_mixed;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, NULL)
  RETURNING id INTO v_op_gap;

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source, block_index)
  VALUES (v_op_mixed, 'cuban_card', 'Tarjeta M', '1234123412341234', '55599998888', 30000, 'CUP', 1, 'vigente', 'admin_addition', 1);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source, block_index)
  VALUES (v_op_mixed, 'zelle', 'Zelle M', 'm@zelle.test', 207, 'USD', 2, 'vigente', 'admin_addition', 1);

  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source, block_index)
  VALUES (v_op_gap, 'cuban_card', 'Tarjeta G', '4321432143214321', '55588887777', 30000, 'CUP', 1, 'vigente', 'admin_addition', 1);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, status, source, block_index)
  VALUES (v_op_gap, 'zelle', 'Zelle G', 'g@zelle.test', 2, 'vigente', 'admin_addition', 1);

  -- ---- complete both, as a human (agent) actor ---------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = v_agent_user
   WHERE id IN (v_op_mixed, v_op_gap);
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- case 1: two lines, one per service ---------------------------------
  SELECT count(*) INTO v_count FROM remittance_calculator_entries
   WHERE operation_id = v_op_mixed AND status = 'completed';
  IF v_count <> 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] a mixed op must get 2 completed lines, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 1] a mixed card+Zelle op gets 2 completed ledger lines';
  END IF;

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_mixed AND service = 'CUP';
  IF v_e.amount IS DISTINCT FROM 30000 OR v_e.basis_gyd IS DISTINCT FROM 20000 OR v_e.facturado_gyd IS DISTINCT FROM 20000 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] CUP line expected amount 30000, basis 20000, facturado 20000; got % / % / %',
      v_e.amount, v_e.basis_gyd, v_e.facturado_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 2] the CUP line is priced on the cards'' share (20000 GYD -> 30000 CUP)';
  END IF;

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_mixed AND service = 'ZELLE';
  IF v_e.amount IS DISTINCT FROM 207 OR v_e.basis_gyd IS DISTINCT FROM 55000 OR v_e.amount_currency IS DISTINCT FROM 'USD' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] ZELLE line expected amount 207 USD, basis 55000; got % % / %',
      v_e.amount, v_e.amount_currency, v_e.basis_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 3] the ZELLE line is priced on the rest of the deposit (55000 GYD -> 207 USD)';
  END IF;

  -- ---- case 4: fed means every part fed -> not in the unfed view -----------
  SELECT count(*) INTO v_count FROM calculator_unfed_operations WHERE operation_id = v_op_mixed;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a fully fed mixed op must not be in calculator_unfed_operations, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 4] a fully fed mixed op is not listed as unfed';
  END IF;

  -- ---- case 5: unknown share -> pending lines naming what is missing -------
  SELECT count(*) INTO v_count FROM remittance_calculator_entries
   WHERE operation_id = v_op_gap AND status = 'verified_pending'
     AND 'beneficiaryAmounts' = ANY (missing_inputs);
  IF v_count <> 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a mixed op with an unknown amount must get 2 pending lines naming beneficiaryAmounts, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 5] an unknown share gives pending lines, never an invented number';
  END IF;

  -- ---- case 6: the financial close counts the mixed op ONCE ----------------
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  v_close := crm_cierre_financiero((now() AT TIME ZONE 'America/Guyana')::date, (now() AT TIME ZONE 'America/Guyana')::date);
  PERFORM set_config('request.jwt.claims', '', true);
  IF (v_close -> 'totales' ->> 'operaciones')::int IS DISTINCT FROM 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] the financial close must count the mixed op once, got %', v_close -> 'totales' ->> 'operaciones';
  ELSE
    RAISE NOTICE 'PASS [case 6] the financial close counts one operation for its two lines';
  END IF;

  -- ---- case 7: revert voids both lines; re-complete revives both -----------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'ready_to_transfer', completed_at = NULL WHERE id = v_op_mixed;
  SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE operation_id = v_op_mixed AND status = 'void';
  IF v_count <> 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7a] reverting must void both lines, found % void', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 7a] reverting a mixed op voids both lines';
  END IF;

  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_mixed;
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE operation_id = v_op_mixed;
  IF v_count <> 2 OR EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE operation_id = v_op_mixed AND status <> 'completed') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7b] re-completing must revive the same 2 lines, found % rows', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 7b] re-completing revives both lines, no duplicates';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'feed-mixed: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'feed-mixed: ALL PASS (9 expectations)';
END $$;

ROLLBACK TO SAVEPOINT feed_mixed;
