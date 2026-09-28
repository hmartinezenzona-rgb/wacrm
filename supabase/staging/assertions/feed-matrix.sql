-- feed-matrix.sql — self-reverting assertion for
-- 104_calculator_ledger_feed.sql
--
-- Proves the calculator auto-feed end to end: the four service formulas
-- against the exact numbers formulas.ts produces, the multiple_distribution
-- and unknown-method mappings, pending_rates with named missing inputs,
-- feed-exactly-once, snapshot immutability under later rate changes, void
-- on human revert with the figures preserved, revival at the NEW rates,
-- the append-only guard's remaining teeth, the no-backfill bound on
-- calculator_unfed_operations, and crm_feed_calculator's authorization.
--
-- THE NUMBERS (rates 1.5 / 250 / 265 / 400 chosen so every result is exact
-- in numeric, no float tolerance needed):
--   CUP      basis 75000 -> amount 112500, facturado 75000, invertido 70312.5, retorno 4687.5
--   ZELLE    basis 26000 -> amount 98 (floor 98.11), facturado 25970, invertido 24500, retorno 1470
--   CLASICA  basis 26000 -> same as ZELLE
--   TROPICAL basis 53000 -> amount 200, facturado 53000, invertido 50000, retorno 3000
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT feed_matrix;

DO $$
DECLARE
  v_account_id   uuid;
  v_owner_user   uuid := gen_random_uuid();
  v_admin_user   uuid := gen_random_uuid();
  v_agent_user   uuid := gen_random_uuid();
  v_viewer_user  uuid := gen_random_uuid();
  v_contact_id   uuid;
  v_conv_id      uuid;
  v_dummy_hash   CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_op_cup       uuid; v_op_zelle   uuid; v_op_clasica uuid;
  v_op_tropical  uuid; v_op_multi   uuid; v_op_mmg     uuid;
  v_op_pending   uuid; v_op_revert  uuid; v_op_old     uuid;

  v_e            remittance_calculator_entries;
  v_count        integer;
  v_missing      text[];
  v_entry_id     uuid;

  v_fail_count   integer := 0;

  -- Impersonation helper values
  v_agent_claims text;
BEGIN
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'feed-owner-'  || v_owner_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'feed-admin-'  || v_admin_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'feed-agent-'  || v_agent_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'feed-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'feed matrix test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user,  'feed owner',  'feed-owner-'  || v_owner_user  || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user,  'feed admin',  'feed-admin-'  || v_admin_user  || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user,  'feed agent',  'feed-agent-'  || v_agent_user  || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'feed viewer', 'feed-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550000901', v_account_id, 'Cliente Feed')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  -- Rates in force for every case except the pending ones.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 265, 'usdt_sell_cup', 400));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, 'cuban_card'),
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle'),
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'clasica'),
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 53000, 'tropical'),
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 75000, 'multiple_distribution'),
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'mmg'),
    (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle');

  SELECT id INTO v_op_cup      FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'cuban_card';
  SELECT id INTO v_op_clasica  FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'clasica';
  SELECT id INTO v_op_tropical FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'tropical';
  SELECT id INTO v_op_multi    FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'multiple_distribution';
  SELECT id INTO v_op_mmg      FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'mmg';
  SELECT id INTO v_op_zelle    FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'zelle' ORDER BY id LIMIT 1;
  SELECT id INTO v_op_revert   FROM remittance_operations WHERE account_id = v_account_id AND delivery_method = 'zelle' AND id <> v_op_zelle LIMIT 1;

  -- ---- case 1: CUP formula ---------------------------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = v_agent_user WHERE id = v_op_cup;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_cup;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.service IS DISTINCT FROM 'CUP'
     OR v_e.amount IS DISTINCT FROM 112500 OR v_e.amount_currency IS DISTINCT FROM 'CUP'
     OR v_e.facturado_gyd IS DISTINCT FROM 75000 OR v_e.invertido_gyd IS DISTINCT FROM 70312.5
     OR v_e.retorno_gyd IS DISTINCT FROM 4687.5 OR v_e.rate_version_id IS NULL
     OR v_e.delivery_mode IS DISTINCT FROM 'proof_sent' OR v_e.customer_name IS DISTINCT FROM 'Cliente Feed'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] CUP expected 112500 CUP / 75000 / 70312.5 / 4687.5; got status=% service=% amount=% cur=% f=% i=% r=% rv=% mode=% name=%',
      v_e.status, v_e.service, v_e.amount, v_e.amount_currency, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.rate_version_id, v_e.delivery_mode, v_e.customer_name;
  ELSE
    RAISE NOTICE 'PASS [case 1] a completed cuban_card remesa is priced by the CUP formula';
  END IF;

  -- ---- case 2: ZELLE formula, amount floors ------------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'no_proof' WHERE id = v_op_zelle;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_zelle;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.service IS DISTINCT FROM 'ZELLE'
     OR v_e.amount IS DISTINCT FROM 98 OR v_e.amount_currency IS DISTINCT FROM 'USD'
     OR v_e.facturado_gyd IS DISTINCT FROM 25970 OR v_e.invertido_gyd IS DISTINCT FROM 24500
     OR v_e.retorno_gyd IS DISTINCT FROM 1470
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] ZELLE expected 98 USD / 25970 / 24500 / 1470; got status=% service=% amount=% f=% i=% r=%',
      v_e.status, v_e.service, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 2] ZELLE rounds 98.11 units down to 98 and prices them';
  END IF;

  -- ---- case 3: CLASICA uses the same formula ----------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_clasica;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_clasica;
  IF v_e.service IS DISTINCT FROM 'CLASICA' OR v_e.amount IS DISTINCT FROM 98 OR v_e.retorno_gyd IS DISTINCT FROM 1470 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] CLASICA expected 98 / 1470; got service=% amount=% r=%', v_e.service, v_e.amount, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 3] CLASICA is priced on the dollar-rail formula';
  END IF;

  -- ---- case 4: TROPICAL, exact division ---------------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_tropical;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_tropical;
  IF v_e.service IS DISTINCT FROM 'TROPICAL' OR v_e.amount IS DISTINCT FROM 200
     OR v_e.facturado_gyd IS DISTINCT FROM 53000 OR v_e.invertido_gyd IS DISTINCT FROM 50000
     OR v_e.retorno_gyd IS DISTINCT FROM 3000
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] TROPICAL expected 200 / 53000 / 50000 / 3000; got amount=% f=% i=% r=%',
      v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 4] TROPICAL prices an exact unit count';
  END IF;

  -- ---- case 5: multiple_distribution maps to CUP ------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_multi;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_multi;
  IF v_e.service IS DISTINCT FROM 'CUP' OR v_e.amount IS DISTINCT FROM 112500 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] multiple_distribution expected CUP 112500; got service=% amount=%', v_e.service, v_e.amount;
  ELSE
    RAISE NOTICE 'PASS [case 5] a multiple distribution is priced as CUP';
  END IF;

  -- ---- case 6: an unmapped method produces no entry ---------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_mmg;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE operation_id = v_op_mmg;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected no entry for an unmapped delivery method, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 6] a service the ledger cannot price produces no entry rather than a guess';
  END IF;

  -- ---- case 7: feed exactly once ----------------------------------------
  SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE operation_id = v_op_cup;
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'transferring' WHERE id = v_op_cup;
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_cup;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE operation_id = v_op_cup;
  IF v_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected exactly 1 entry after a revert + re-complete cycle, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 7] one operation never produces a second entry';
  END IF;

  -- ---- case 8: revert voids the entry and keeps every figure ------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'no_proof' WHERE id = v_op_revert;
  PERFORM set_config('request.jwt.claims', '', true);

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'incident' WHERE id = v_op_revert;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_revert;
  IF v_e.status IS DISTINCT FROM 'void' OR v_e.voided_at IS NULL OR v_e.void_reason IS NULL
     OR v_e.facturado_gyd IS DISTINCT FROM 25970 OR v_e.retorno_gyd IS DISTINCT FROM 1470
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected void with figures intact (25970/1470); got status=% voided_at=% reason=% f=% r=%',
      v_e.status, v_e.voided_at, v_e.void_reason, v_e.facturado_gyd, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 8] a human revert voids the entry without erasing what it recorded';
  END IF;

  -- ---- case 9: revival uses the rates in force NOW ----------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', 300));
  PERFORM set_config('request.jwt.claims', '', true);

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_revert;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_revert;
  -- floor(26000/300) = 86; 86*300 = 25800; 86*250 = 21500; retorno 4300
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 86
     OR v_e.facturado_gyd IS DISTINCT FROM 25800 OR v_e.retorno_gyd IS DISTINCT FROM 4300
     OR v_e.voided_at IS NOT NULL
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] revival expected 86 / 25800 / 4300 at the new rate; got status=% amount=% f=% r=% voided_at=%',
      v_e.status, v_e.amount, v_e.facturado_gyd, v_e.retorno_gyd, v_e.voided_at;
  ELSE
    RAISE NOTICE 'PASS [case 9] re-completing revives the entry at the rates in force now, not the original ones';
  END IF;

  -- ---- case 10: a live entry is frozen against later rate changes -------
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_zelle;
  IF v_e.facturado_gyd IS DISTINCT FROM 25970 OR v_e.usdt_sell_gyd IS DISTINCT FROM 265 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] expected the case-2 entry untouched at 25970 / rate 265; got f=% rate=%',
      v_e.facturado_gyd, v_e.usdt_sell_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 10] changing the rates never reaches back into an entry already written';
  END IF;

  -- ---- case 11: missing rates -> verified_pending + named inputs --------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', NULL));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle')
  RETURNING id INTO v_op_pending;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_pending;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_pending;
  IF v_e.status IS DISTINCT FROM 'verified_pending'
     OR NOT (v_e.missing_inputs @> ARRAY['usdtSellGyd'])
     OR v_e.facturado_gyd IS NOT NULL OR v_e.invertido_gyd IS NOT NULL OR v_e.retorno_gyd IS NOT NULL
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 11] expected verified_pending naming usdtSellGyd with no financials; got status=% missing=% f=% i=% r=%',
      v_e.status, v_e.missing_inputs, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 11] a missing rate parks the entry as pending and names what it needs';
  END IF;

  -- ---- case 12: pending entries stay out of the totals ------------------
  SELECT count(*) INTO v_count
    FROM remittance_calculator_entries
   WHERE account_id = v_account_id AND status = 'completed' AND operation_id = v_op_pending;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 12] a pending entry must never count as completed, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 12] a pending entry is excluded from the completed totals';
  END IF;

  -- ---- case 13: UPDATE of a completed entry is refused ------------------
  BEGIN
    UPDATE remittance_calculator_entries SET amount = 1 WHERE operation_id = v_op_zelle;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 13] expected the append-only guard to refuse editing a completed entry';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 13] a completed entry cannot be edited';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 13] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 14: DELETE of a completed entry is refused ------------------
  BEGIN
    DELETE FROM remittance_calculator_entries WHERE operation_id = v_op_zelle;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 14] expected the append-only guard to refuse deleting a completed entry';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 14] a completed entry cannot be deleted';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 14] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 15: voiding must not rewrite the figures --------------------
  BEGIN
    UPDATE remittance_calculator_entries
       SET status = 'void', voided_at = clock_timestamp(), facturado_gyd = 1
     WHERE operation_id = v_op_zelle;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 15] expected a refusal when voiding also altered a figure';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 15] voiding may change the status, never the recorded money';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 15] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 16: unfed view holds only what genuinely could not be priced
  -- Every op the trigger COULD price (cases 1-5, 7-9) has a live entry and
  -- is absent here. v_op_mmg (case 6, delivery_method='mmg', no
  -- beneficiaries) is genuinely unresolvable and — since 141 — is meant to
  -- be VISIBLE here instead of silently excluded, so it is the one
  -- expected row.
  SELECT count(*) INTO v_count FROM calculator_unfed_operations WHERE account_id = v_account_id;
  IF v_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 16] expected calculator_unfed_operations to hold exactly the unresolvable mmg op, found % row(s)', v_count;
  ELSE
    SELECT count(*) INTO v_count FROM calculator_unfed_operations
     WHERE account_id = v_account_id AND operation_id = v_op_mmg AND unfed_reason = 'service_unresolved';
    IF v_count <> 1 THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 16] expected the one unfed row to be v_op_mmg with unfed_reason=service_unresolved';
    ELSE
      RAISE NOTICE 'PASS [case 16] only the genuinely unresolvable op is unfed, and it is visible with its reason (141)';
    END IF;
  END IF;

  -- ---- case 17: no backfill (assumption A1) -----------------------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method, completed_at)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'completed', 'remesa', 'GYD', 26000, 'zelle',
          (SELECT feed_started_at - interval '1 day' FROM calculator_feed_state))
  RETURNING id INTO v_op_old;

  SELECT count(*) INTO v_count FROM calculator_unfed_operations WHERE operation_id = v_op_old;
  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 17] a remesa completed before feed_started_at must not appear as unfed, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 17] remesas completed before the feed existed are not backfilled';
  END IF;

  -- ---- case 18: crm_feed_calculator is admin+ ---------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_feed_calculator(v_op_cup);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 18] expected 42501 for a viewer replaying the feed';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 18] replaying the feed is admin+';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 18] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 19: replaying over a live entry changes nothing -------------
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op_zelle;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  v_entry_id := crm_feed_calculator(v_op_zelle);
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_entry_id IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 19] replaying over a live entry should touch nothing, got entry %', v_entry_id;
  ELSE
    SELECT count(*) INTO v_count FROM remittance_calculator_entries
     WHERE operation_id = v_op_zelle AND facturado_gyd = 25970 AND status = 'completed';
    IF v_count <> 1 THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 19] the live entry changed after a replay';
    ELSE
      RAISE NOTICE 'PASS [case 19] replaying the feed over a live entry is a no-op';
    END IF;
  END IF;

  -- ---- case 20: an operation with no basis produces no entry ------------
  DECLARE
    v_op_nobasis uuid;
  BEGIN
    INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, delivery_method)
    VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 'zelle')
    RETURNING id INTO v_op_nobasis;

    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_nobasis;
    PERFORM set_config('request.jwt.claims', '', true);

    SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE operation_id = v_op_nobasis;
    IF v_count <> 0 THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 20] expected no entry when the deposit amount is unknown, found %', v_count;
    ELSE
      RAISE NOTICE 'PASS [case 20] no deposit on file means no ledger entry, and the completion still commits';
    END IF;
  END;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'feed-matrix: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'feed-matrix: ALL PASS (20 expectations)';
END $$;

ROLLBACK TO SAVEPOINT feed_matrix;
