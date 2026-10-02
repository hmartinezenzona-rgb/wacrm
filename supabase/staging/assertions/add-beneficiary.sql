\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- add-beneficiary.sql — self-reverting assertion for
-- 123_add_beneficiary_rpc.sql
--
-- Proves crm_agregar_beneficiario: authorization (agent+ required),
-- validation (unknown keys, beneficiary_type, per-type required fields,
-- amount, currency), refusal on closed and non-remesa operations, the
-- 'vigente' row it inserts plus the refreshed completeness flag it
-- returns, the admin_locked_fields lock it places, the human_beneficiary_
-- added audit row, and that a later cerebro_sync_beneficiarios (042/098)
-- does not remove or replace the beneficiary a human just added.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures
-- (pipeline/stage via ON CONFLICT DO NOTHING, same ids as
-- field-lock-persistence.sql / corrections.sql) so it can run alongside
-- or independently of the other assertion files.
--
-- RED:   against staging without 123 applied — crm_agregar_beneficiario
--        does not exist, every case fails.
-- GREEN: after 123 is applied — all cases PASS.

SAVEPOINT add_beneficiary;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_op_card_id       uuid;
  v_op_zelle_id      uuid;
  v_op_closed_id     uuid;
  v_op_nonremesa_id  uuid;
  v_deal_sync_id     uuid; v_op_sync_id uuid;

  v_result         jsonb;
  v_new_id         uuid;
  v_case_start     timestamptz;
  v_fail_count     integer := 0;

  v_row            remittance_beneficiaries%ROWTYPE;
  v_locked_jsonb   jsonb;
  v_vigente_count  integer;
  v_vigente_id     uuid;
  v_sync_result    integer;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'add-benef-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'add-benef-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'add-benef-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'add-beneficiary test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'add-benef owner', 'add-benef-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'add-benef agent', 'add-benef-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'add-benef viewer', 'add-benef-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer');

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000501', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- NOTE: since 114 retired the deals->remittance_operations INSERT/UPDATE
  -- mirror trigger (trg_sync_operacion_desde_deal is now DELETE-only — see
  -- that migration's header, "brand-new-deal branch of
  -- cerebro_registrar_deposito gains an explicit INSERT INTO
  -- remittance_operations"), a plain `INSERT INTO deals` no longer creates
  -- an operation row by itself. Every operation fixture below is inserted
  -- directly into remittance_operations instead; only opSync also gets a
  -- real `deals` row, because case 9 needs cerebro_sync_beneficiarios(deal_id)
  -- to find it via the deals/remittance_operations join.

  -- opCard: fresh, no beneficiary, for the happy-path cuban_card add
  -- (case 1), the bad-card (case 4), missing-amount (case 5), and
  -- unauthorized (case 8) attempts — none of those mutate state.
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id)
  RETURNING id INTO v_op_card_id;

  -- opZelle: fresh, for the zelle happy path (case 2) and the missing-
  -- zelle_account rejection (case 6).
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id)
  RETURNING id INTO v_op_zelle_id;

  -- opClosed: a cancelled operation, for the closed-operation test (case 3).
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, 'cancelled')
  RETURNING id INTO v_op_closed_id;

  -- opNonRemesa: a live operation whose service_type is something other
  -- than 'remesa', for the non-remesa rejection (case 7).
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, service_type)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, 'combo')
  RETURNING id INTO v_op_nonremesa_id;

  -- opSync: a real deal + its linked operation, for the "a later bot sync
  -- does not wipe the manual beneficiary" test (case 9).
  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/add-benef-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'add-benef-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'add-benef fixture sync', v_account_id, v_conv_id, v_contact_id, 100, 'GYD')
  RETURNING id INTO v_deal_sync_id;
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, v_contact_id, v_deal_sync_id)
  RETURNING id INTO v_op_sync_id;

  -- ---- case 1: agent adds a cuban_card beneficiary ---------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_agregar_beneficiario(v_op_card_id, jsonb_build_object(
           'beneficiary_type', 'cuban_card',
           'card_number', '9205123412349412',
           'phone', '55512345',
           'amount', 15000,
           'currency', 'CUP'
         )) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  v_new_id := (v_result ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE id = v_new_id;
  SELECT admin_locked_fields INTO v_locked_jsonb FROM remittance_operations WHERE id = v_op_card_id;

  IF v_new_id IS NULL
     OR v_row.status IS DISTINCT FROM 'vigente'
     OR v_row.beneficiary_type IS DISTINCT FROM 'cuban_card'
     OR v_row.card_number IS DISTINCT FROM '9205123412349412'
     OR v_row.phone IS DISTINCT FROM '55512345'
     OR v_row.amount IS DISTINCT FROM 15000
     OR v_row.currency IS DISTINCT FROM 'CUP'
     OR (v_result ->> 'complete') IS DISTINCT FROM 'true'
     OR NOT (v_locked_jsonb ? 'beneficiaries')
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_new_id AND action = 'human_beneficiary_added' AND created_at >= v_case_start
     )
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected a vigente cuban_card row, complete=true, a beneficiaries lock, and a human_beneficiary_added audit row; got id=%, status=%, complete=%, locked=%', v_new_id, v_row.status, v_result ->> 'complete', v_locked_jsonb;
  ELSE
    RAISE NOTICE 'PASS [case 1] agent adds a cuban_card beneficiary: row exists, complete=true, locked, audited';
  END IF;

  -- ---- case 2: agent adds a zelle beneficiary ---------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_agregar_beneficiario(v_op_zelle_id, jsonb_build_object(
           'beneficiary_type', 'zelle',
           'name', 'Maria Perez',
           'zelle_account', 'maria@example.com',
           'amount', 100,
           'currency', 'USD'
         )) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  v_new_id := (v_result ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE id = v_new_id;

  IF v_new_id IS NULL
     OR v_row.status IS DISTINCT FROM 'vigente'
     OR v_row.name IS DISTINCT FROM 'Maria Perez'
     OR v_row.zelle_account IS DISTINCT FROM 'maria@example.com'
     OR (v_result ->> 'complete') IS DISTINCT FROM 'true'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected a vigente zelle row with name/zelle_account and complete=true; got id=%, name=%, zelle_account=%, complete=%', v_new_id, v_row.name, v_row.zelle_account, v_result ->> 'complete';
  ELSE
    RAISE NOTICE 'PASS [case 2] agent adds a zelle beneficiary: row exists, complete=true';
  END IF;

  -- ---- case 3: add to a closed (cancelled) operation -> 22023 ----------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_agregar_beneficiario(v_op_closed_id, jsonb_build_object(
              'beneficiary_type', 'cuban_card', 'card_number', '1111222233334444',
              'phone', '55512346', 'amount', 100, 'currency', 'CUP'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected 22023 for a cancelled operation, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 3] adding to a closed (cancelled) operation is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 3] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 4: bad card number (15 digits) -> 22023 --------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_agregar_beneficiario(v_op_card_id, jsonb_build_object(
              'beneficiary_type', 'cuban_card', 'card_number', '123456789012345',
              'phone', '55512347', 'amount', 100, 'currency', 'CUP'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected 22023 for a 15-digit card_number, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 4] a 15-digit card_number is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5: missing amount -> 22023 ----------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_agregar_beneficiario(v_op_card_id, jsonb_build_object(
              'beneficiary_type', 'cuban_card', 'card_number', '1111222233334444',
              'phone', '55512348', 'currency', 'CUP'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected 22023 for a missing amount, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 5] a missing amount is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 6: zelle missing zelle_account -> 22023 --------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_agregar_beneficiario(v_op_zelle_id, jsonb_build_object(
              'beneficiary_type', 'zelle', 'name', 'Someone Else',
              'amount', 50, 'currency', 'USD'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected 22023 for a zelle beneficiary missing zelle_account, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 6] a zelle beneficiary without zelle_account is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7: non-remesa operation -> 22023 ----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_agregar_beneficiario(v_op_nonremesa_id, jsonb_build_object(
              'beneficiary_type', 'cuban_card', 'card_number', '1111222233334444',
              'phone', '55512349', 'amount', 100, 'currency', 'CUP'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected 22023 for a non-remesa operation, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7] a non-remesa operation is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8: unauthorized (viewer) -> 42501 ---------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_agregar_beneficiario(v_op_card_id, jsonb_build_object(
              'beneficiary_type', 'cuban_card', 'card_number', '1111222233334444',
              'phone', '55512350', 'amount', 100, 'currency', 'CUP'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected 42501 for a viewer calling crm_agregar_beneficiario, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 8] a viewer is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 9: a later bot sync does not wipe the manual beneficiary ---
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_agregar_beneficiario(v_op_sync_id, jsonb_build_object(
           'beneficiary_type', 'cuban_card', 'card_number', '9205123412349999',
           'phone', '55512399', 'amount', 200, 'currency', 'CUP'
         )) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);
  v_new_id := (v_result ->> 'id')::uuid;

  -- Automation actor (no jwt claims set): calling cerebro_sync_beneficiarios
  -- directly must return 0 new rows, leave the manually added row the only
  -- vigente one, and record an automation_write_suppressed audit row —
  -- exactly the lock behavior 098 already gives corrections/reassignments.
  SELECT cerebro_sync_beneficiarios(v_deal_sync_id) INTO v_sync_result;
  SELECT count(*) INTO v_vigente_count FROM remittance_beneficiaries WHERE operation_id = v_op_sync_id AND status = 'vigente';
  SELECT id INTO v_vigente_id FROM remittance_beneficiaries WHERE operation_id = v_op_sync_id AND status = 'vigente';

  IF v_sync_result IS DISTINCT FROM 0
     OR v_vigente_count IS DISTINCT FROM 1
     OR v_vigente_id IS DISTINCT FROM v_new_id
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_sync_id AND field_name = 'beneficiaries'
          AND action = 'automation_write_suppressed' AND created_at >= v_case_start
     )
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] expected cerebro_sync_beneficiarios to return 0, leave the added beneficiary vigente, and audit automation_write_suppressed; got result=%, vigente_count=%, vigente_id=%', v_sync_result, v_vigente_count, v_vigente_id;
  ELSE
    RAISE NOTICE 'PASS [case 9] a later automation sync does not remove or replace the manually added beneficiary';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'add-beneficiary: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'add-beneficiary: ALL PASS (9 expectations)';
END $$;

ROLLBACK TO SAVEPOINT add_beneficiary;
