\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- read-rpc.sql — self-reverting assertion for
-- 097_operaciones_de_conversacion_rpc.sql
--
-- Proves `crm_operaciones_de_conversacion`:
--   1. lists every open (non-terminal) service_type='remesa' operation for
--      the conversation, each with its 'vigente' beneficiaries, excluding
--      a terminal (cancelled) remesa and a live NON-remesa operation;
--   2. surfaces resolver state 'ambigua' without picking a winner, and
--      lets the resolver's candidate count include the live non-remesa
--      operation the operations list itself excludes (documented deviation,
--      see 097's file header);
--   3. surfaces resolver state 'ninguna' with an empty operations list —
--      no fabricated row;
--   4. surfaces resolver state 'unica' correctly on the simple one-op case;
--   5. denies a caller who is not a member of the conversation's account
--      (insufficient_privilege, SQLSTATE 42501), and denies a NULL
--      conversation id the same way.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK — see
-- the SDD apply-progress for port-chat-operations-calculator Slice 5 for
-- the exact invocation (docker psql against $PGURL, wrapped in
-- BEGIN ... \i 097 ... \i this file ... ROLLBACK). Never COMMIT. Never run
-- against production.
--
-- FIXTURES: two accounts (A = the fixture account under test, B = an
-- unrelated account whose only member is the "non-member" persona), a
-- viewer member of A, three conversations under A (ambiguous, none, and
-- unique), four remesa/combo operations, and two beneficiaries. Every
-- operation is inserted at a NON-'completed' status so guard 12a
-- (096_admin_locks_audit_sync.sql) never coerces it — the "terminal,
-- excluded" fixture uses 'cancelled' instead of 'completed' specifically
-- to sidestep that guard entirely rather than fight it with the
-- wacrm.origin GUC (guard 12a only guards transitions into/out of
-- 'completed', never 'cancelled' — see 096's guard 12a body). This script
-- never touches `deals`, so it needs none of guard12-matrix.sql's
-- cerebro_config/pipeline fixtures.

-- SAVEPOINT and ROLLBACK TO SAVEPOINT are plain transaction-control
-- commands and cannot be issued from inside a PL/pgSQL DO block, so they
-- bracket it here instead.
SAVEPOINT read_rpc;

DO $$
DECLARE
  v_account_id      uuid;
  v_account_b_id    uuid;
  v_owner_user      uuid := gen_random_uuid();
  v_owner_b_user    uuid := gen_random_uuid();
  v_viewer_user     uuid := gen_random_uuid();
  v_nonmember_user  uuid := gen_random_uuid();
  v_contact_ambigua_id uuid;
  v_contact_ninguna_id uuid;
  v_contact_unica_id   uuid;
  v_conv_ambigua_id uuid;
  v_conv_ninguna_id uuid;
  v_conv_unica_id   uuid;
  v_op1_id          uuid;
  v_op2_id          uuid;
  v_op3_cancelled   uuid;
  v_op4_combo       uuid;
  v_op_unica_id     uuid;
  v_ben1_id         uuid;
  v_ben2_id         uuid;
  v_row_count       integer;
  v_distinct_ops    integer;
  v_distinct_bens   integer;
  v_fail_count      integer := 0;
  v_dummy_hash      CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see guard12-matrix.sql's fixture comment for why (a
  -- pre-existing, out-of-scope production bug on this schema).
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user,     '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'readrpc-owner-'     || v_owner_user     || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_owner_b_user,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'readrpc-ownerb-'    || v_owner_b_user   || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'readrpc-viewer-'    || v_viewer_user    || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_nonmember_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'readrpc-nonmember-' || v_nonmember_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'read-rpc test account A', v_owner_user)   RETURNING id INTO v_account_id;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'read-rpc test account B', v_owner_b_user) RETURNING id INTO v_account_b_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user,     'readrpc owner',     'readrpc-owner-'     || v_owner_user     || '@test.invalid', v_account_id,   'owner'),
    (gen_random_uuid(), v_viewer_user,    'readrpc viewer',    'readrpc-viewer-'    || v_viewer_user    || '@test.invalid', v_account_id,   'viewer'),
    (gen_random_uuid(), v_owner_b_user,   'readrpc owner b',   'readrpc-ownerb-'    || v_owner_b_user   || '@test.invalid', v_account_b_id, 'owner'),
    (gen_random_uuid(), v_nonmember_user, 'readrpc nonmember', 'readrpc-nonmember-' || v_nonmember_user || '@test.invalid', v_account_b_id, 'viewer');

  -- One contact per conversation: migration 094 enforces exactly one
  -- conversation per (account_id, contact_id).
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000301', v_account_id) RETURNING id INTO v_contact_ambigua_id;
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000302', v_account_id) RETURNING id INTO v_contact_ninguna_id;
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000303', v_account_id) RETURNING id INTO v_contact_unica_id;

  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_ambigua_id, v_account_id) RETURNING id INTO v_conv_ambigua_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_ninguna_id, v_account_id) RETURNING id INTO v_conv_ninguna_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_unica_id, v_account_id) RETURNING id INTO v_conv_unica_id;

  -- Ambiguous conversation: 2 live remesas (op1, op2), 1 cancelled remesa
  -- (op3 — must be excluded), 1 live combo (op4 — counted by the resolver,
  -- excluded from `operations`, see 097's file header). All non-'completed'
  -- on INSERT so guard 12a never engages.
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, destination_currency, quoted_source_amount, quoted_destination_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_ambigua_id, 'deposit_verification', 'remesa', 'GYD', 'CUP', 10000, 9800) RETURNING id INTO v_op1_id;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency)
  VALUES (gen_random_uuid(), v_account_id, v_conv_ambigua_id, 'awaiting_deposit', 'remesa', 'GYD') RETURNING id INTO v_op2_id;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_conv_ambigua_id, 'cancelled', 'remesa') RETURNING id INTO v_op3_cancelled;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_conv_ambigua_id, 'collecting_information', 'combo') RETURNING id INTO v_op4_combo;

  -- op1 gets two 'vigente' beneficiaries (two distinct blocks, so the
  -- (operation_id, block_index, position) unique index is untouched).
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, card_number, phone, position, block_index, status)
  VALUES (gen_random_uuid(), v_op1_id, 'cuban_card', 'Yaima Perez', '9205123412340009412', '15550001111', 1, 1, 'vigente') RETURNING id INTO v_ben1_id;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, zelle_account, position, block_index, status)
  VALUES (gen_random_uuid(), v_op1_id, 'zelle', 'Yaima Perez Zelle', 'yaima@example.invalid', 1, 2, 'vigente') RETURNING id INTO v_ben2_id;
  -- op2 deliberately has zero beneficiaries — proves the LEFT JOIN still
  -- surfaces the operation with an empty beneficiary set, not zero rows.

  -- Unique-resolver conversation: exactly one live remesa, one beneficiary.
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_unica_id, 'ready_to_transfer', 'remesa', 5000) RETURNING id INTO v_op_unica_id;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, card_number, position, block_index, status)
  VALUES (gen_random_uuid(), v_op_unica_id, 'cuban_card', 'Solo Beneficiario', '1111222233334444', 1, 1, 'vigente');

  RAISE NOTICE 'read-rpc: fixtures ready (account=%, conv_ambigua=%, conv_ninguna=%, conv_unica=%)', v_account_id, v_conv_ambigua_id, v_conv_ninguna_id, v_conv_unica_id;

  -- ---- Case 1: ambigua — lists op1 (2 beneficiaries) + op2 (0), excludes
  --      the cancelled remesa and the live combo from `operations`, but the
  --      combo still counts toward `resolver_candidatas`. ----------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  SELECT count(*) INTO v_row_count FROM crm_operaciones_de_conversacion(v_conv_ambigua_id);
  IF v_row_count IS DISTINCT FROM 3 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [ambigua row count] expected 3 rows (op1 x2 beneficiaries + op2 x1 empty row), got %', v_row_count;
  ELSE
    RAISE NOTICE 'PASS [ambigua row count] 3 rows';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) r
    HAVING count(*) FILTER (WHERE r.resolver_resultado <> 'ambigua') = 0
       AND count(*) FILTER (WHERE r.resolver_candidatas <> 3) = 0
       AND count(*) FILTER (WHERE r.resolver_operation_id IS NOT NULL) = 0
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [ambigua resolver columns] expected resultado=ambigua, candidatas=3, operation_id=NULL on every row';
  ELSE
    RAISE NOTICE 'PASS [ambigua resolver columns] resultado=ambigua, candidatas=3 (includes the live combo), operation_id=NULL on every row';
  END IF;

  SELECT count(DISTINCT operation_id) INTO v_distinct_ops FROM crm_operaciones_de_conversacion(v_conv_ambigua_id);
  IF v_distinct_ops IS DISTINCT FROM 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [ambigua distinct operations] expected exactly 2 distinct operation ids (op1, op2), got %', v_distinct_ops;
  ELSIF EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) WHERE operation_id IN (v_op3_cancelled, v_op4_combo)) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [ambigua distinct operations] the cancelled remesa or the live combo leaked into `operations`';
  ELSE
    RAISE NOTICE 'PASS [ambigua distinct operations] exactly {op1, op2}, cancelled remesa and live combo both excluded';
  END IF;

  SELECT count(DISTINCT beneficiary_id) INTO v_distinct_bens
    FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) WHERE operation_id = v_op1_id;
  IF v_distinct_bens IS DISTINCT FROM 2 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [op1 beneficiaries] expected 2 distinct beneficiaries for op1, got %', v_distinct_bens;
  ELSIF NOT EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) WHERE operation_id = v_op1_id AND beneficiary_id = v_ben1_id AND beneficiary_card_number = '9205123412340009412')
     OR NOT EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) WHERE operation_id = v_op1_id AND beneficiary_id = v_ben2_id AND beneficiary_zelle_account = 'yaima@example.invalid') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [op1 beneficiaries] raw card_number/zelle_account did not round-trip unmasked (masking is a TS read-model concern, not this RPC)';
  ELSE
    RAISE NOTICE 'PASS [op1 beneficiaries] both beneficiaries present with raw (unmasked) field values';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) WHERE operation_id = v_op2_id AND beneficiary_id IS NULL) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [op2 empty beneficiaries] expected exactly one row for op2 with beneficiary_id NULL (LEFT JOIN, not fabricated)';
  ELSE
    RAISE NOTICE 'PASS [op2 empty beneficiaries] op2 surfaces with an empty beneficiary set';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- Case 2: ninguna — empty operations list, no fabrication --------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  SELECT count(*) INTO v_row_count FROM crm_operaciones_de_conversacion(v_conv_ninguna_id);
  IF v_row_count IS DISTINCT FROM 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [ninguna row count] expected exactly 1 row (resolver-only, no operation), got %', v_row_count;
  ELSIF NOT EXISTS (
    SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_ninguna_id)
     WHERE resolver_resultado = 'ninguna' AND resolver_operation_id IS NULL AND resolver_candidatas = 0 AND operation_id IS NULL
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [ninguna shape] expected resultado=ninguna, operation_id=NULL, candidatas=0, and no operation row';
  ELSE
    RAISE NOTICE 'PASS [ninguna] empty operations list, no fabricated operation';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- Case 3: unica — the simple one-operation case -------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);

  IF NOT EXISTS (
    SELECT 1 FROM crm_operaciones_de_conversacion(v_conv_unica_id)
     WHERE resolver_resultado = 'unica' AND resolver_operation_id = v_op_unica_id AND resolver_candidatas = 1
       AND operation_id = v_op_unica_id AND beneficiary_name = 'Solo Beneficiario'
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [unica] expected resultado=unica pointing at the single operation with its one beneficiary';
  ELSE
    RAISE NOTICE 'PASS [unica] resultado=unica, resolver_operation_id matches, beneficiary present';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- Case 4: non-member denied ---------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nonmember_user, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM 1 FROM crm_operaciones_de_conversacion(v_conv_ambigua_id) LIMIT 1;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [non-member denied] expected insufficient_privilege, the call returned instead';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS [non-member denied] insufficient_privilege raised as expected';
  END;
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- Case 5: NULL conversation id denied the same way ----------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM 1 FROM crm_operaciones_de_conversacion(NULL) LIMIT 1;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [NULL conversation id] expected insufficient_privilege, the call returned instead';
  EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'PASS [NULL conversation id] insufficient_privilege raised as expected';
  END;
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'read-rpc: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'read-rpc: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT read_rpc;
