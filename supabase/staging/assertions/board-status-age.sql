-- =====================================================================
-- Assertion for migration 219 (remittance_operations.status_changed_at and the board's state_since). Self-reverting:
-- one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Fixtures build their own account, user, contact and operations.
-- Run it as: BEGIN; \i board-status-age.sql; ROLLBACK;
--
-- now() is constant inside a transaction, so every timestamp here is read with clock_timestamp() around each write and
-- the board's state_since is checked against that window, never against now().
-- =====================================================================
DO $$
DECLARE
  v_user   uuid := gen_random_uuid();
  v_acc    uuid;
  v_ct     uuid;
  v_conv   uuid;
  v_op     uuid;
  v_op2    uuid;
  v_op3    uuid;
  v_hash   text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_t0     timestamptz;
  v_t1     timestamptz;
  v_since  timestamptz;
  v_after  timestamptz;
  v_r      record;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'age-a-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'board age account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'board age agent', 'age-a-' || v_user || '@test.invalid', v_acc, 'agent');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900219', 'Board Age Customer') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- The transaction clock is now older than anything below.
  PERFORM pg_sleep(0.05);

  -- 1. INSERT stamps the status time: state_since falls inside the insert window.
  v_t0 := clock_timestamp();
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 31000, 'zelle') RETURNING id INTO v_op;
  v_t1 := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.operation_id IS NULL THEN RAISE EXCEPTION 'case 1: the new operation is not on the board'; END IF;
  IF v_r.state_since < v_t0 OR v_r.state_since > v_t1 THEN
    RAISE EXCEPTION 'case 1: state_since % is outside the insert window [%, %]', v_r.state_since, v_t0, v_t1; END IF;

  -- 2. A status change by a NON-audited writer (no session, as the bot writes), then an unrelated edit later:
  --    state_since stays at the status change, not at the later edit.
  PERFORM pg_sleep(0.1);
  v_t0 := clock_timestamp();
  UPDATE remittance_operations SET status = 'deposit_verification' WHERE id = v_op;
  v_t1 := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.status <> 'deposit_verification' THEN RAISE EXCEPTION 'case 2: the bot status change did not apply: %', v_r.status; END IF;
  IF v_r.state_since < v_t0 OR v_r.state_since > v_t1 THEN
    RAISE EXCEPTION 'case 2: state_since % is outside the status change window [%, %]', v_r.state_since, v_t0, v_t1; END IF;
  v_since := v_r.state_since;

  PERFORM pg_sleep(0.1);
  UPDATE remittance_operations SET quoted_source_amount = 31500 WHERE id = v_op;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.quoted_source_amount <> 31500 THEN RAISE EXCEPTION 'case 2: the unrelated edit did not apply'; END IF;
  IF v_r.state_since IS DISTINCT FROM v_since THEN
    RAISE EXCEPTION 'case 2: an unrelated edit moved state_since from % to %', v_since, v_r.state_since; END IF;

  -- 3. An UPDATE that sets the status to the value it already has does not move it (alone or with other columns).
  PERFORM pg_sleep(0.1);
  UPDATE remittance_operations SET status = 'deposit_verification' WHERE id = v_op;
  UPDATE remittance_operations SET status = 'deposit_verification', quoted_source_amount = 31600 WHERE id = v_op;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.state_since IS DISTINCT FROM v_since THEN
    RAISE EXCEPTION 'case 3: a same-status update moved state_since from % to %', v_since, v_r.state_since; END IF;

  -- 4. A later real change moves it again (and only to the new change time).
  PERFORM pg_sleep(0.1);
  v_t0 := clock_timestamp();
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  v_t1 := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.state_since < v_t0 OR v_r.state_since > v_t1 OR v_r.state_since <= v_since THEN
    RAISE EXCEPTION 'case 4: state_since % is not the new change window [%, %] after %', v_r.state_since, v_t0, v_t1, v_since; END IF;
  v_since := v_r.state_since;

  -- 5. A status change the guard suppresses (automation trying to complete) leaves the status, and so state_since.
  PERFORM pg_sleep(0.1);
  UPDATE remittance_operations SET status = 'completed' WHERE id = v_op;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 5: the guard did not suppress the completion: %', v_r.status; END IF;
  IF v_r.state_since IS DISTINCT FROM v_since THEN
    RAISE EXCEPTION 'case 5: a suppressed status change moved state_since from % to %', v_since, v_r.state_since; END IF;

  -- 6. Completed operations report the completion time (completed_at), also when it is backdated.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 32000, 'zelle') RETURNING id INTO v_op2;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() - interval '1 second' WHERE id = v_op2;
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op2;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_r.status <> 'completed' OR v_r.completed_at IS NULL OR v_r.state_since IS DISTINCT FROM v_r.completed_at THEN
    RAISE EXCEPTION 'case 6: a backdated completion: %', to_jsonb(v_r); END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 33000, 'zelle') RETURNING id INTO v_op3;
  v_t0 := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET status = 'completed' WHERE id = v_op3;
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op3;
  PERFORM set_config('request.jwt.claims', '', true);
  v_after := clock_timestamp();
  IF v_r.state_since IS DISTINCT FROM v_r.completed_at OR v_r.state_since IS NULL THEN
    RAISE EXCEPTION 'case 6: a plain completion: %', to_jsonb(v_r); END IF;
  IF v_r.state_since > v_after THEN RAISE EXCEPTION 'case 6: completion time in the future'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
