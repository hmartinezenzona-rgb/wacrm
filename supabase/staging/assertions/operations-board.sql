-- =====================================================================
-- Assertion for migration 214 (crm_tablero_operaciones, the read-only operations board). Self-reverting: one DO block
-- that ends in RAISE EXCEPTION 'ALL PASS'. Fixtures build their own accounts, users, contacts and operations.
-- Run it as: BEGIN; \i operations-board.sql; ROLLBACK;
-- =====================================================================
DO $$
DECLARE
  v_user   uuid := gen_random_uuid();
  v_other  uuid := gen_random_uuid();
  v_nomem  uuid := gen_random_uuid();
  v_acc    uuid;
  v_acc2   uuid;
  v_ct     uuid;
  v_ct2    uuid;
  v_conv   uuid;
  v_conv2  uuid;
  v_op     uuid;
  v_statuses text[] := ARRAY['collecting_information','deposit_verification','ready_to_transfer','transferring','incident'];
  v_s      text;
  v_ops    jsonb := '{}'::jsonb;
  v_op_new uuid;
  v_op_old uuid;
  v_op_can uuid;
  v_op_oth uuid;
  v_r      record;
  v_n      int;
  v_hash   text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_since  timestamptz;
  v_rank   int;
  v_prev_rank int;
  v_prev_since timestamptz;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tab-a-' || v_user  || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_other, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tab-b-' || v_other || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_nomem, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tab-c-' || v_nomem || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'board account', v_user) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'board other account', v_other) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_user,  'board agent', 'tab-a-' || v_user  || '@test.invalid', v_acc,  'agent'),
    (gen_random_uuid(), v_other, 'board other',  'tab-b-' || v_other || '@test.invalid', v_acc2, 'owner');
  -- v_nomem has NO profile: it belongs to no account.

  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990021401', 'Board Customer') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_other, v_acc2, '5990021402', 'Other Customer') RETURNING id INTO v_ct2;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_other, v_acc2, v_ct2) RETURNING id INTO v_conv2;

  -- One open operation of each live status (one per service so they are told apart).
  FOREACH v_s IN ARRAY v_statuses LOOP
    INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
    VALUES (v_acc, v_conv, v_ct, v_s, 'remesa', 'GYD', 30000 + length(v_s), 'zelle') RETURNING id INTO v_op;
    v_ops := v_ops || jsonb_build_object(v_s, v_op);
  END LOOP;
  -- A visa (needs no recipients) among them.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'visa', 'GYD', 5000) RETURNING id INTO v_op;

  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 40000, 'zelle') RETURNING id INTO v_op_new;
  -- A completion is only accepted from a logged-in human (the status guard suppresses automation ones).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() - interval '2 hours' WHERE id = v_op_new;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 41000, 'zelle') RETURNING id INTO v_op_old;
  -- A completion is only accepted from a logged-in human (the status guard suppresses automation ones).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() - interval '30 hours' WHERE id = v_op_old;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 42000, 'zelle') RETURNING id INTO v_op_can;
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op_can;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc2, v_conv2, v_ct2, 'collecting_information', 'remesa', 'GYD', 43000, 'zelle') RETURNING id INTO v_op_oth;

  -- A status change audited by a human: state_since must follow the audit row, not updated_at.
  v_since := now() - interval '5 hours';
  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after, created_at)
  VALUES (v_acc, 'remittance_operations', (v_ops->>'incident')::uuid, 'status', 'human_forced_verification', 'test',
          '{"status":"deposit_verification"}'::jsonb, '{"status":"incident"}'::jsonb, v_since);
  -- Since 219 state_since reads status_changed_at first; an operation without a stamp (NULL) falls back to the 214
  -- derivation, which is what this case exercises. The stamp itself is asserted in board-status-age.sql.
  UPDATE remittance_operations SET status_changed_at = NULL WHERE id = (v_ops->>'incident')::uuid;

  -- 1. A member sees the open operations of each status with the right fields.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  FOREACH v_s IN ARRAY v_statuses LOOP
    SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = (v_ops->>v_s)::uuid;
    IF v_r.operation_id IS NULL THEN RAISE EXCEPTION 'case 1: the % operation is missing', v_s; END IF;
    IF v_r.status <> v_s OR v_r.conversation_id <> v_conv OR v_r.contact_name <> 'Board Customer'
       OR v_r.contact_phone <> '5990021401' OR v_r.service_type <> 'remesa' OR v_r.delivery_method <> 'zelle'
       OR v_r.source_currency <> 'GYD' OR v_r.quoted_source_amount <> 30000 + length(v_s)
       OR v_r.created_at IS NULL OR v_r.completed_at IS NOT NULL OR v_r.state_since IS NULL
       OR v_r.beneficiaries_complete IS NULL THEN
      RAISE EXCEPTION 'case 1: wrong fields for %: %', v_s, to_jsonb(v_r); END IF;
  END LOOP;
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op;
  IF v_r.service_type <> 'visa' THEN RAISE EXCEPTION 'case 1: the visa is missing'; END IF;

  -- 2. With no status_changed_at, state_since follows the audited status change when there is one.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = (v_ops->>'incident')::uuid;
  IF abs(extract(epoch FROM (v_r.state_since - v_since))) > 1 THEN
    RAISE EXCEPTION 'case 2: state_since % should be the audit time %', v_r.state_since, v_since; END IF;

  -- 3. Completed: inside 24 h appears (state_since = completed_at); older does not.
  SELECT * INTO v_r FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op_new;
  IF v_r.operation_id IS NULL OR v_r.status <> 'completed' OR v_r.completed_at IS NULL OR v_r.state_since <> v_r.completed_at THEN
    RAISE EXCEPTION 'case 3: the recently completed operation: %', to_jsonb(v_r); END IF;
  IF EXISTS (SELECT 1 FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op_old) THEN
    RAISE EXCEPTION 'case 3: an operation completed 30 h ago must not appear'; END IF;

  -- 4. Cancelled never appears; another account's operation never appears.
  IF EXISTS (SELECT 1 FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op_can) THEN
    RAISE EXCEPTION 'case 4: a cancelled operation appeared'; END IF;
  IF EXISTS (SELECT 1 FROM crm_tablero_operaciones() t WHERE t.operation_id = v_op_oth) THEN
    RAISE EXCEPTION 'case 4: another account''s operation appeared'; END IF;
  SELECT count(*) INTO v_n FROM crm_tablero_operaciones();
  IF v_n <> 7 THEN RAISE EXCEPTION 'case 4: expected 7 rows (5 open + visa + 1 completed), got %', v_n; END IF;

  -- 5. Ordered by board column (requested, deposit check, ready/transferring, incident, completed), then state_since.
  v_prev_rank := 0;
  FOR v_r IN SELECT * FROM crm_tablero_operaciones() LOOP
    v_rank := CASE v_r.status WHEN 'collecting_information' THEN 1 WHEN 'deposit_verification' THEN 2
                WHEN 'ready_to_transfer' THEN 3 WHEN 'transferring' THEN 3 WHEN 'incident' THEN 4 ELSE 5 END;
    IF v_rank < v_prev_rank THEN RAISE EXCEPTION 'case 5: column order broken at %', v_r.status; END IF;
    IF v_rank = v_prev_rank AND v_r.state_since < v_prev_since THEN
      RAISE EXCEPTION 'case 5: state_since order broken inside column %', v_rank; END IF;
    v_prev_rank := v_rank; v_prev_since := v_r.state_since;
  END LOOP;

  -- 6. A caller with no account is refused (same 42501 as the other panel read RPCs).
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nomem, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM * FROM crm_tablero_operaciones();
    RAISE EXCEPTION 'case 6: a non-member must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  -- ... and so is a request with no session at all.
  PERFORM set_config('request.jwt.claims', '', true);
  BEGIN
    PERFORM * FROM crm_tablero_operaciones();
    RAISE EXCEPTION 'case 6b: no session must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  -- 7. anon cannot execute it; authenticated can.
  IF has_function_privilege('anon', 'crm_tablero_operaciones()', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 7: anon must not execute it'; END IF;
  IF has_function_privilege('public', 'crm_tablero_operaciones()', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 7: PUBLIC must not execute it'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_tablero_operaciones()', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 7: authenticated must execute it'; END IF;

  RAISE EXCEPTION 'ALL PASS';
END $$;
