-- calculator-entry-correction.sql — self-reverting assertion for
-- 149_calculator_entry_correction.sql
--
-- Proves crm_corregir_entrada_calculadora (B3.2):
--   case 1 — an admin corrects a COMPLETED chat-fed entry's facturado_gyd/
--            invertido_gyd; retorno_gyd recomputes (facturado - invertido)
--            and the row stays status='completed'.
--   case 2 — an admin corrects a VERIFIED_PENDING chat-fed entry: the same
--            call also flips it to 'completed' and clears missing_inputs
--            (104's own pending_has_no_snapshot_chk forces this — a
--            pending row cannot hold non-null facturado/invertido).
--   case 3 — a non-admin (agent) is refused (42501).
--   case 4 — a VOID'd entry is refused (22023), with a clear error.
--   case 5 — a MANUAL weekly-log entry (source='manual') is refused
--            (22023), with a clear error naming why.
--   case 6 — a non-existent entry id is refused (P0002).
--   case 7 — every correction leaves exactly one 'human_calculator_correction'
--            audit row with sensible before/after values.
--   case 8 — after case 1's correction, the same row still cannot be
--            edited by a raw UPDATE outside this RPC (the append-only
--            guard's hole is narrow, not a general unlock).
--
-- RED (against 104-148, function does not exist): every PERFORM/SELECT
--   of crm_corregir_entrada_calculadora fails with "function ... does not
--   exist" (42883).
-- GREEN (after 149): all cases above pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker exec -i wacrm-ensayo psql -U supabase_admin -d postgres,
-- wrapped in BEGIN ... \i 149 ... \i this file ... ROLLBACK, or against
-- real staging the same way). Never COMMIT. Never run against
-- production. Builds its own fixtures.

SAVEPOINT calculator_entry_correction;

DO $$
DECLARE
  v_account_id  uuid;
  v_owner_user  uuid := gen_random_uuid();
  v_admin_user  uuid := gen_random_uuid();
  v_agent_user  uuid := gen_random_uuid();
  v_contact_id  uuid;
  v_conv_id     uuid;
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_admin_claims text;
  v_agent_claims text;

  v_op_completed  uuid;
  v_op_pending    uuid;
  v_op_void       uuid;
  v_entry_completed uuid;
  v_entry_pending   uuid;
  v_entry_void      uuid;
  v_entry_manual    uuid;

  v_e           remittance_calculator_entries;
  v_count       integer;
  v_fail_count  integer := 0;
BEGIN
  v_admin_claims := json_build_object('sub', v_admin_user, 'role', 'authenticated')::text;
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cec-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cec-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cec-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'calculator entry correction test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'cec owner', 'cec-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user, 'cec admin', 'cec-admin-' || v_admin_user || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user, 'cec agent', 'cec-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550009901', v_account_id, 'Cliente CEC')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  -- Full rates, so completing a ZELLE operation feeds a live 'completed' line.
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 400));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- completed entry fixture -----------------------------------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle')
  RETURNING id INTO v_op_completed;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_completed;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT id INTO v_entry_completed FROM remittance_calculator_entries WHERE operation_id = v_op_completed;

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_entry_completed;
  IF v_e.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'calculator-entry-correction: fixture setup failed — completed entry did not feed as completed (status=%)', v_e.status;
  END IF;

  -- ---- pending entry fixture (usdt_sell_gyd unset -> parks pending) -----
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', NULL));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 30000, 'zelle')
  RETURNING id INTO v_op_pending;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_pending;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT id INTO v_entry_pending FROM remittance_calculator_entries WHERE operation_id = v_op_pending;

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_entry_pending;
  IF v_e.status IS DISTINCT FROM 'verified_pending' THEN
    RAISE EXCEPTION 'calculator-entry-correction: fixture setup failed — expected a verified_pending entry (status=%)', v_e.status;
  END IF;

  -- Restore the full rate set for the rest of the fixtures/assertions.
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', 260));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- void'd entry fixture ----------------------------------------------
  -- A dedicated third operation: complete it (feeds an entry), then revert
  -- it and leave it reverted. A revert flips that SAME entry row's status
  -- to 'void' in place — it does NOT create a fresh row and leave the old
  -- one behind (verified directly against a rehearsal DB: re-completing
  -- after a revert revives the identical row id back to 'completed'). So
  -- v_op_completed/v_entry_completed above are left untouched here, and
  -- this fixture never re-completes v_op_void, or its entry would revive
  -- out of 'void' too.
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 13000, 'zelle')
  RETURNING id INTO v_op_void;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_void;
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op_void;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT id INTO v_entry_void FROM remittance_calculator_entries
   WHERE operation_id = v_op_void AND status = 'void';

  IF v_entry_void IS NULL THEN
    RAISE EXCEPTION 'calculator-entry-correction: fixture setup failed — expected a voided entry after reverting v_op_void';
  END IF;

  -- ---- manual weekly-log entry fixture ------------------------------------
  INSERT INTO remittance_calculator_entries (
    account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at
  ) VALUES (
    v_account_id, 'manual', 'completed', current_date, 'Manual CEC', 'ZELLE', 50, 'USD',
    13000, 12000, 1000, now()
  ) RETURNING id INTO v_entry_manual;

  -- ===========================================================================
  -- CASE 1 — admin corrects a COMPLETED entry; retorno recomputes.
  -- ===========================================================================
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_entrada_calculadora(v_entry_completed, 27000, 24500);
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_entry_completed;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.facturado_gyd IS DISTINCT FROM 27000
     OR v_e.invertido_gyd IS DISTINCT FROM 24500 OR v_e.retorno_gyd IS DISTINCT FROM 2500
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected completed 27000/24500/2500, got status=% f=% i=% r=%',
      v_e.status, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 1] an admin corrects a completed entry and retorno_gyd recomputes correctly';
  END IF;

  -- ===========================================================================
  -- CASE 2 — admin corrects a VERIFIED_PENDING entry: also completes it.
  -- ===========================================================================
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_entrada_calculadora(v_entry_pending, 30500, 28000);
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_entry_pending;
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.facturado_gyd IS DISTINCT FROM 30500
     OR v_e.invertido_gyd IS DISTINCT FROM 28000 OR v_e.retorno_gyd IS DISTINCT FROM 2500
     OR v_e.missing_inputs IS NOT NULL
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected completed 30500/28000/2500 with missing_inputs cleared, got status=% f=% i=% r=% missing=%',
      v_e.status, v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.missing_inputs;
  ELSE
    RAISE NOTICE 'PASS [case 2] an admin correction resolves a pending entry into a completed one';
  END IF;

  -- ===========================================================================
  -- CASE 3 — a non-admin (agent) is refused.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    PERFORM crm_corregir_entrada_calculadora(v_entry_completed, 1, 1);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected 42501 for an agent correcting a calculator entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 3] correcting a calculator entry is admin+';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 3] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ===========================================================================
  -- CASE 4 — a VOID'd entry is refused.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_entrada_calculadora(v_entry_void, 1, 1);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected 22023 for correcting a void entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 4] a void entry cannot be corrected (%)', SQLERRM;
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ===========================================================================
  -- CASE 5 — a MANUAL weekly-log entry is refused.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_entrada_calculadora(v_entry_manual, 1, 1);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected 22023 for correcting a manual weekly-log entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 5] a manual weekly-log entry cannot be corrected here (%)', SQLERRM;
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ===========================================================================
  -- CASE 6 — a non-existent entry id is refused.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_entrada_calculadora(gen_random_uuid(), 1, 1);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected P0002 for a missing entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = 'P0002' THEN
      RAISE NOTICE 'PASS [case 6] a missing entry reports not-found';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6] expected SQLSTATE P0002, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ===========================================================================
  -- CASE 7 — every correction is audited with sensible before/after values.
  -- ===========================================================================
  SELECT count(*) INTO v_count
    FROM remittance_admin_audit
   WHERE row_id = v_entry_completed
     AND action = 'human_calculator_correction'
     AND (before ->> 'facturado_gyd')::numeric IS DISTINCT FROM (after ->> 'facturado_gyd')::numeric
     AND (after ->> 'facturado_gyd')::numeric = 27000
     AND (after ->> 'invertido_gyd')::numeric = 24500
     AND (after ->> 'retorno_gyd')::numeric = 2500;
  IF v_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected exactly 1 audit row with the corrected before/after values, found %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 7] the correction is audited with sensible before/after values';
  END IF;

  -- ===========================================================================
  -- CASE 8 — the append-only guard's hole is narrow: a raw UPDATE of the
  -- same completed row (outside the RPC) is still refused.
  -- ===========================================================================
  BEGIN
    UPDATE remittance_calculator_entries SET facturado_gyd = 999 WHERE id = v_entry_completed;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected the append-only guard to still refuse a raw UPDATE outside the RPC';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 8] the correction hole is narrow -- a raw UPDATE is still refused';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'calculator-entry-correction: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'calculator-entry-correction: ALL PASS (8 expectations)';
END $$;

ROLLBACK TO SAVEPOINT calculator_entry_correction;
