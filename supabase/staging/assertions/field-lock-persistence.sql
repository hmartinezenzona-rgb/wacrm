\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- field-lock-persistence.sql — self-reverting assertion for
-- 096_admin_locks_audit_sync.sql
--
-- Proves decision 2 / spec "Operator Corrections Survive Automation
-- Writes": once a human (agent+) corrects a field on remittance_operations,
-- automation can no longer overwrite it — including when the overwrite
-- comes from the existing deal->operation sync trigger
-- (cerebro_sync_operacion_desde_deal, 041/043/060), which this migration
-- did not modify — while a later human write to that same field still
-- goes through.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK — see
-- the SDD apply-progress for port-chat-operations-calculator Slice 4 for
-- the exact invocation. Never COMMIT. Never run against production. Run
-- after guard12-matrix.sql in the same transaction; both create their own
-- fixtures independently (pipeline/stages via ON CONFLICT DO NOTHING) so
-- either can run alone too.
--
-- Case 1 exercises the sync path end-to-end: a deal is created linked to a
-- conversation (so cerebro_sync_operacion_desde_deal's INSERT branch feeds
-- an operation from it), an agent then corrects the operation's
-- quoted_source_amount directly (locking it), and the deal's value is
-- changed as automation (no JWT) — the sync trigger's resulting UPDATE on
-- remittance_operations must keep the human-corrected amount, not the
-- deal's new value.
--
-- Case 2 exercises the lock mechanism directly (no sync involved) on a
-- second field, destination_currency, and also proves the lock map column
-- itself is immune to an automation write that tries to clear it.

-- SAVEPOINT and ROLLBACK TO SAVEPOINT are plain transaction-control
-- commands and cannot be issued from inside a PL/pgSQL DO block, so they
-- bracket it here instead.
SAVEPOINT field_lock_persistence;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_deal_id        uuid;
  v_op_id          uuid;
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;
  v_amount         numeric;
  v_currency       text;
  v_locked         jsonb;
  v_case_start     timestamptz;
  v_fail_count     integer := 0;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see guard12-matrix.sql's fixture comment for why (a
  -- pre-existing, out-of-scope production bug on this schema).
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lockpersist-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lockpersist-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'field-lock-persistence test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'lockpersist owner', 'lockpersist-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'lockpersist agent', 'lockpersist-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() (pre-existing trigger, unrelated to 096) fires on
  -- every deals INSERT and needs a non-null notify_url — see
  -- guard12-matrix.sql's fixture comment for the full explanation.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/field-lock-persistence-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'field-lock-persistence-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000202', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- ---- Case 1: sync-trigger path (quoted_source_amount) --------------
  -- Deal created with a conversation_id: cerebro_sync_operacion_desde_deal's
  -- INSERT branch feeds a remittance_operations row from it (040/041).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'field-lock-persistence fixture', v_account_id, v_conv_id, v_contact_id, 100, 'GYD')
  RETURNING id INTO v_deal_id;

  SELECT id, quoted_source_amount INTO v_op_id, v_amount FROM remittance_operations WHERE deal_id = v_deal_id;
  IF v_op_id IS NULL THEN
    RAISE EXCEPTION 'field-lock-persistence: fixture setup failed — deal->operation sync did not create an operation for deal %', v_deal_id;
  END IF;
  IF v_amount IS DISTINCT FROM 100 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [fixture] expected the sync trigger to seed quoted_source_amount=100 from the deal, got %', v_amount;
  END IF;

  -- Human (agent) correction: locks quoted_source_amount going forward.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET quoted_source_amount = 250 WHERE id = v_op_id;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT quoted_source_amount, admin_locked_fields INTO v_amount, v_locked FROM remittance_operations WHERE id = v_op_id;
  IF v_amount IS DISTINCT FROM 250 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [human correction] expected quoted_source_amount=250 after an agent write, got %', v_amount;
  ELSIF NOT (v_locked ? 'quoted_source_amount') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [human correction] expected admin_locked_fields to contain quoted_source_amount after an agent write, got %', v_locked;
  ELSE
    RAISE NOTICE 'PASS [human correction] agent write locked quoted_source_amount at 250';
  END IF;

  -- Automation changes the deal's value (no JWT): the sync trigger's
  -- UPDATE on remittance_operations must keep the locked amount.
  v_case_start := clock_timestamp();
  UPDATE deals SET value = 999 WHERE id = v_deal_id;

  SELECT quoted_source_amount INTO v_amount FROM remittance_operations WHERE id = v_op_id;
  IF v_amount IS DISTINCT FROM 250 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [lock survives sync] expected quoted_source_amount to stay 250 after an automation deal-value change, got %', v_amount;
  ELSIF NOT EXISTS (
    SELECT 1 FROM remittance_admin_audit
     WHERE row_id = v_op_id AND field_name = 'quoted_source_amount'
       AND action = 'automation_write_suppressed' AND created_at >= v_case_start
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [lock survives sync] expected an automation_write_suppressed audit row for quoted_source_amount, found none';
  ELSE
    RAISE NOTICE 'PASS [lock survives sync] automation deal-value change (100->999) did not move the locked amount off 250, audited';
  END IF;

  -- Human revert/re-correction must still be allowed on a locked field.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET quoted_source_amount = 300 WHERE id = v_op_id;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT quoted_source_amount INTO v_amount FROM remittance_operations WHERE id = v_op_id;
  IF v_amount IS DISTINCT FROM 300 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [human revert allowed] expected a second agent write to succeed (quoted_source_amount=300), got %', v_amount;
  ELSE
    RAISE NOTICE 'PASS [human revert allowed] a locked field still accepts a later human write';
  END IF;

  -- ---- Case 2: direct lock on a second field + lock-map immutability --
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET destination_currency = 'CUP' WHERE id = v_op_id;
  PERFORM set_config('request.jwt.claims', '', true);

  v_case_start := clock_timestamp();
  UPDATE remittance_operations SET destination_currency = 'USD' WHERE id = v_op_id;

  SELECT destination_currency INTO v_currency FROM remittance_operations WHERE id = v_op_id;
  IF v_currency IS DISTINCT FROM 'CUP' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [direct lock] expected destination_currency to stay CUP after a direct automation write, got %', v_currency;
  ELSIF NOT EXISTS (
    SELECT 1 FROM remittance_admin_audit
     WHERE row_id = v_op_id AND field_name = 'destination_currency'
       AND action = 'automation_write_suppressed' AND created_at >= v_case_start
  ) THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [direct lock] expected an automation_write_suppressed audit row for destination_currency, found none';
  ELSE
    RAISE NOTICE 'PASS [direct lock] a direct automation write to a locked field (no sync involved) was suppressed and audited';
  END IF;

  -- Automation tries to wipe the whole lock map alongside an unrelated no-op write.
  UPDATE remittance_operations SET admin_locked_fields = '{}'::jsonb WHERE id = v_op_id;
  SELECT admin_locked_fields INTO v_locked FROM remittance_operations WHERE id = v_op_id;
  IF NOT (v_locked ? 'quoted_source_amount' AND v_locked ? 'destination_currency') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [lock map immutable] expected both locks to survive an automation attempt to clear admin_locked_fields, got %', v_locked;
  ELSE
    RAISE NOTICE 'PASS [lock map immutable] automation cannot clear admin_locked_fields directly';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'field-lock-persistence: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'field-lock-persistence: ALL PASS (6 expectations)';
END $$;

ROLLBACK TO SAVEPOINT field_lock_persistence;
