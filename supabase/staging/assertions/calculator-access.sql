\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- calculator-access.sql — self-reverting assertion for
-- 106_calculator_session_client_access.sql
--
-- Proves that a logged-in user can now read the calculator's two 095
-- tables with their OWN session (the whole point: the route stops needing
-- a service-role key), that they can read only their own account's rows,
-- that no write path opened up alongside the read path, that the document
-- RPC enforces agent+, and that 103's inherited write privileges are gone.
--
-- WHY THIS ONE USES `SET LOCAL ROLE` AND THE OTHER ASSERTIONS DO NOT:
-- guard12-matrix.sql explains at its head that decision 12's guards are
-- driven by `is_account_member(...)` reading the JWT, never by
-- `current_user`, so varying the JWT alone is the faithful simulation
-- there. This migration is the opposite case — it is ENTIRELY about table
-- privileges and RLS policies, both of which are evaluated against the
-- CURRENT ROLE. Connected as the harness's superuser, RLS is bypassed and
-- every check below would pass vacuously. So each case switches to
-- `authenticated` (the role PostgREST uses for a logged-in caller) with
-- the JWT claims that caller would carry, and resets afterwards.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT calculator_access;

DO $$
DECLARE
  v_account_id   uuid;
  v_other_acct   uuid;
  v_owner_user   uuid := gen_random_uuid();
  v_agent_user   uuid := gen_random_uuid();
  v_viewer_user  uuid := gen_random_uuid();
  v_outsider     uuid := gen_random_uuid();
  v_contact_id   uuid;
  v_conv_id      uuid;
  v_dummy_hash   CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_op_id        uuid;
  v_other_op_id  uuid;
  v_other_conv   uuid;
  v_other_contact uuid;
  v_count        integer;
  v_text         text;

  v_viewer_claims   text;
  v_agent_claims    text;
  v_outsider_claims text;

  v_fail_count   integer := 0;
BEGIN
  v_viewer_claims   := json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text;
  v_agent_claims    := json_build_object('sub', v_agent_user,  'role', 'authenticated')::text;
  v_outsider_claims := json_build_object('sub', v_outsider,    'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cacc-owner-'    || v_owner_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cacc-agent-'    || v_agent_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cacc-viewer-'   || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_outsider,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cacc-outsider-' || v_outsider    || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'calculator access account', v_owner_user)
  RETURNING id INTO v_account_id;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'calculator other account', v_outsider)
  RETURNING id INTO v_other_acct;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user,  'cacc owner',    'cacc-owner-'    || v_owner_user  || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user,  'cacc agent',    'cacc-agent-'    || v_agent_user  || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'cacc viewer',   'cacc-viewer-'   || v_viewer_user || '@test.invalid', v_account_id, 'viewer'),
    (gen_random_uuid(), v_outsider,    'cacc outsider', 'cacc-outsider-' || v_outsider    || '@test.invalid', v_other_acct, 'owner');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550000903', v_account_id, 'Cliente Access')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_outsider, '15550000904', v_other_acct, 'Cliente Otro')
  RETURNING id INTO v_other_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_outsider, v_other_contact, v_other_acct)
  RETURNING id INTO v_other_conv;

  -- One ledger entry per account, written the real way (rates + completion).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 265, 'usdt_sell_cup', 400));
  PERFORM set_config('request.jwt.claims', v_outsider_claims, true);
  PERFORM crm_set_calculator_rates(v_other_acct, jsonb_build_object('usdt_buy_gyd', 250, 'usdt_sell_gyd', 265));
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle')
  RETURNING id INTO v_op_id;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_other_acct, v_other_conv, 'ready_to_transfer', 'remesa', 'GYD', 26000, 'zelle')
  RETURNING id INTO v_other_op_id;

  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_id;
  PERFORM set_config('request.jwt.claims', v_outsider_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_other_op_id;
  PERFORM set_config('request.jwt.claims', '', true);

  INSERT INTO remittance_calculator_documents (account_id, raw_text, period_label)
  VALUES (v_account_id, 'documento de prueba', 'sem 1');

  -- ---- case 1: a viewer reads their own ledger with their own session ---
  PERFORM set_config('request.jwt.claims', v_viewer_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_count FROM remittance_calculator_entries;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_count <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected a viewer to see their 1 ledger entry as authenticated, saw %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 1] a logged-in member reads the ledger with their own session — no service-role key needed';
  END IF;

  -- ---- case 2: and never another account's ------------------------------
  PERFORM set_config('request.jwt.claims', v_viewer_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_count FROM remittance_calculator_entries WHERE account_id = v_other_acct;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_count <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a member saw % row(s) of another account''s ledger', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 2] another account''s ledger is invisible';
  END IF;

  -- ---- case 3: the document is readable the same way --------------------
  PERFORM set_config('request.jwt.claims', v_viewer_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT raw_text INTO v_text FROM remittance_calculator_documents WHERE account_id = v_account_id;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_text IS DISTINCT FROM 'documento de prueba' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected the document text, got %', coalesce(v_text, '<null>');
  ELSE
    RAISE NOTICE 'PASS [case 3] a member reads the calculator document with their own session';
  END IF;

  -- ---- case 4: reading did not open writing -----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, service, amount, amount_currency, completed_at, facturado_gyd, invertido_gyd, retorno_gyd)
    VALUES (v_account_id, 'manual', 'completed', current_date, 'CUP', 1, 'CUP', now(), 1, 0, 1);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] a logged-in user inserted directly into the ledger';
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 4] no write policy: a direct ledger INSERT is refused';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5: nor updating ---------------------------------------------
  -- Refused at the GRANT level, before RLS is even consulted: only SELECT
  -- was granted, so there is no UPDATE privilege to evaluate a policy for.
  -- That is stricter than an RLS no-match (which would silently touch zero
  -- rows and report success to the caller).
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    UPDATE remittance_calculator_entries SET customer_name = 'hacked' WHERE account_id = v_account_id;
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a logged-in user updated the ledger directly';
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 5] a direct ledger UPDATE is refused for want of the privilege';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 6: the document RPC is agent+ -------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_viewer_claims, true);
    PERFORM crm_guardar_documento_calculadora(v_account_id, 'texto de un viewer', 'sem 2');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected 42501 for a viewer saving the document';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 6] a viewer cannot save the calculator document';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7: an agent can save it -------------------------------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  PERFORM crm_guardar_documento_calculadora(v_account_id, 'texto guardado por el agente', 'sem 3');
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT raw_text INTO v_text FROM remittance_calculator_documents WHERE account_id = v_account_id;
  IF v_text IS DISTINCT FROM 'texto guardado por el agente' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected the agent''s text, got %', coalesce(v_text, '<null>');
  ELSE
    RAISE NOTICE 'PASS [case 7] an agent saves the calculator document through the RPC';
  END IF;

  -- ---- case 8: never another account's document -------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    PERFORM crm_guardar_documento_calculadora(v_other_acct, 'intruso', 'sem 4');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] an agent wrote another account''s document';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 8] an agent cannot write another account''s document';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 9: 103's inherited write privileges are gone ----------------
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    EXECUTE 'SET LOCAL ROLE authenticated';
    INSERT INTO calculator_rate_versions (account_id, cup_global_rate) VALUES (v_account_id, 9);
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] a logged-in user inserted a rate version directly';
  EXCEPTION WHEN OTHERS THEN
    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 9] rate versions cannot be written outside crm_set_calculator_rates';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 9] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 10: but a member still reads them ---------------------------
  PERFORM set_config('request.jwt.claims', v_viewer_claims, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*) INTO v_count FROM calculator_rate_versions WHERE account_id = v_account_id;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_count < 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] a member could not read their own rate versions, saw %', v_count;
  ELSE
    RAISE NOTICE 'PASS [case 10] a member reads their own rate versions';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'calculator-access: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'calculator-access: ALL PASS (10 expectations)';
END $$;

ROLLBACK TO SAVEPOINT calculator_access;
