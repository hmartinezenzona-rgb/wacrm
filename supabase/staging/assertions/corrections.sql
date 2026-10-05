\set ON_ERROR_STOP on
-- (2026-10-05) Fixture rebuilt deal-free: operations come from cerebro_crear_operacion (a deal no longer creates one since 161/172/183); only the two operations whose beneficiaries are parsed from notes get a deal linked to them, because cerebro_sync_beneficiarios still reads the linked deal's notes.
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- corrections.sql — self-reverting assertion for
-- 098_operator_corrections_rpcs.sql
--
-- Proves crm_corregir_operacion, crm_corregir_beneficiario and
-- crm_reasignar_beneficiario: authorization (agent+ required), validation
-- (allowed keys, field formats, closed operations), the append-only
-- correction/reassignment behavior for beneficiaries, the
-- admin_locked_fields lock they place, and that cerebro_sync_beneficiarios
-- (042) honors that lock instead of overwriting a corrected beneficiary.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures
-- (pipeline/stage via ON CONFLICT DO NOTHING, same ids as
-- field-lock-persistence.sql) so it can run alongside or independently of
-- the other assertion files.

-- SAVEPOINT and ROLLBACK TO SAVEPOINT are plain transaction-control
-- commands and cannot be issued from inside a PL/pgSQL DO block, so they
-- bracket it here instead.
SAVEPOINT corrections;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_contact2_id    uuid;
  v_conv1_id       uuid;
  v_conv2_id       uuid;
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_deal_x_id      uuid; v_op_x_id      uuid;
  v_deal_closed_id uuid; v_op_closed_id uuid;
  v_deal_y_id      uuid; v_op_y_id      uuid; v_ben_y_id uuid;
  v_deal_a_id      uuid; v_op_a_id      uuid; v_ben_a_id uuid;
  v_deal_b_id      uuid; v_op_b_id      uuid;
  v_deal_c_id      uuid; v_op_c_id      uuid;

  v_new_ben_id     uuid;
  v_reassigned_id  uuid;
  v_sync_result    integer;

  v_amount         numeric;
  v_status         text;
  v_status2        text;
  v_card           text;
  v_locked_jsonb   jsonb;
  v_locked_a       jsonb;
  v_locked_b       jsonb;
  v_new_op         uuid;
  v_vigente_count  integer;
  v_vigente_id     uuid;

  v_case_start     timestamptz;
  v_fail_count     integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see field-lock-persistence.sql's fixture comment for why.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'corrections-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'corrections-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'corrections-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'corrections test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'corrections owner', 'corrections-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'corrections agent', 'corrections-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'corrections viewer', 'corrections-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() (pre-existing trigger, unrelated to 098) fires on
  -- every deals INSERT and needs a non-null notify_url.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/corrections-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'corrections-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000303', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000304', v_account_id) RETURNING id INTO v_contact2_id;
  -- conversations has a unique (account_id, contact_id) constraint, so the
  -- two conversations need distinct contacts.
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv1_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact2_id, v_account_id) RETURNING id INTO v_conv2_id;

  -- opX: plain operation used for the operation-correction tests (cases 1-3).
  v_op_x_id := cerebro_crear_operacion(v_conv1_id, 100, 'GYD', v_por_verificar);

  -- opClosed: a second operation, cancelled, for the closed-operation test (case 4).
  v_op_closed_id := cerebro_crear_operacion(v_conv1_id, 100, 'GYD', v_por_verificar);
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op_closed_id;

  -- opY: operation with a notes-parsed vigente beneficiary, for the
  -- beneficiary-correction tests (cases 5-7). The notes UPDATE happens
  -- after the operation already exists so trg_sync_benef_desde_deal's
  -- cerebro_sync_beneficiarios() call actually finds it.
  v_op_y_id := cerebro_crear_operacion(v_conv1_id, 100, 'GYD', v_por_verificar);
  -- the beneficiary sync still reads the notes of the deal linked to the operation: link a deal to it.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'corrections fixture Y', v_account_id, v_conv1_id, v_contact_id, 100, 'GYD')
  RETURNING id INTO v_deal_y_id;
  UPDATE remittance_operations SET deal_id = v_deal_y_id WHERE id = v_op_y_id;
  UPDATE deals SET notes = 'BENEFICIARIO (Beneficiario Y)' || E'\n' || 'Tarjeta: 1111222233334444' || E'\n' || 'Celular: 55512345'
   WHERE id = v_deal_y_id;
  SELECT id INTO v_ben_y_id FROM remittance_beneficiaries WHERE operation_id = v_op_y_id AND status = 'vigente';
  IF v_ben_y_id IS NULL THEN
    RAISE EXCEPTION 'corrections: fixture setup failed — no vigente beneficiary parsed for deal %', v_deal_y_id;
  END IF;

  -- opA / opB: same conversation, for the same-conversation reassignment
  -- test (case 8) and its follow-on cross-conversation / unauthorized
  -- attempts (cases 9-10).
  v_op_a_id := cerebro_crear_operacion(v_conv1_id, 100, 'GYD', v_por_verificar);
  -- the beneficiary sync still reads the notes of the deal linked to the operation: link a deal to it.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'corrections fixture A', v_account_id, v_conv1_id, v_contact_id, 100, 'GYD')
  RETURNING id INTO v_deal_a_id;
  UPDATE remittance_operations SET deal_id = v_deal_a_id WHERE id = v_op_a_id;
  UPDATE deals SET notes = 'BENEFICIARIO (Beneficiario A)' || E'\n' || 'Tarjeta: 5555666677778888' || E'\n' || 'Celular: 55512399'
   WHERE id = v_deal_a_id;
  SELECT id INTO v_ben_a_id FROM remittance_beneficiaries WHERE operation_id = v_op_a_id AND status = 'vigente';
  IF v_ben_a_id IS NULL THEN
    RAISE EXCEPTION 'corrections: fixture setup failed — no vigente beneficiary parsed for deal %', v_deal_a_id;
  END IF;

  v_op_b_id := cerebro_crear_operacion(v_conv1_id, 100, 'GYD', v_por_verificar);

  -- opC: a different conversation, target for the cross-conversation
  -- reassignment rejection (case 9).
  v_op_c_id := cerebro_crear_operacion(v_conv2_id, 100, 'GYD', v_por_verificar);

  -- ---- case 1: agent corrects quoted_source_amount ---------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  PERFORM crm_corregir_operacion(v_op_x_id, jsonb_build_object('quoted_source_amount', 250));
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT quoted_source_amount, admin_locked_fields INTO v_amount, v_locked_jsonb
    FROM remittance_operations WHERE id = v_op_x_id;

  IF v_amount IS DISTINCT FROM 250
     OR NOT (v_locked_jsonb ? 'quoted_source_amount')
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_x_id AND field_name = 'quoted_source_amount'
          AND action = 'human_correction' AND created_at >= v_case_start
     )
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected quoted_source_amount=250, locked, and a human_correction audit row; got amount=%, locked=%', v_amount, v_locked_jsonb;
  ELSE
    RAISE NOTICE 'PASS [case 1] agent correction updates the amount, locks it, and audits human_correction';
  END IF;

  -- ---- case 2: viewer calls crm_corregir_operacion -> 42501 -----------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_corregir_operacion(v_op_x_id, jsonb_build_object('quoted_source_amount', 999));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected 42501 for a viewer calling crm_corregir_operacion, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 2] a viewer is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 3: unknown key -> 22023 ------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_corregir_operacion(v_op_x_id, jsonb_build_object('not_a_real_field', 'x'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected 22023 for an unknown key, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 3] an unknown key is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 3] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 4: closed operation (cancelled) -> 22023 -------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_corregir_operacion(v_op_closed_id, jsonb_build_object('quoted_source_amount', 50));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected 22023 for a closed operation, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 4] a closed (cancelled) operation is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 4] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 5: agent corrects beneficiary card_number ------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_corregir_beneficiario(v_ben_y_id, jsonb_build_object('card_number', '9999888877776666')) INTO v_new_ben_id;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT status INTO v_status FROM remittance_beneficiaries WHERE id = v_ben_y_id;
  SELECT status, card_number INTO v_status2, v_card FROM remittance_beneficiaries WHERE id = v_new_ben_id;
  SELECT admin_locked_fields INTO v_locked_jsonb FROM remittance_operations WHERE id = v_op_y_id;

  IF v_status IS DISTINCT FROM 'reemplazado'
     OR v_status2 IS DISTINCT FROM 'vigente'
     OR v_card IS DISTINCT FROM '9999888877776666'
     OR NOT (v_locked_jsonb ? 'beneficiaries')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected old row reemplazado, new vigente row with new card, and a beneficiaries lock; got old_status=%, new_status=%, new_card=%, locked=%', v_status, v_status2, v_card, v_locked_jsonb;
  ELSE
    RAISE NOTICE 'PASS [case 5] beneficiary card correction replaces the row and locks beneficiaries on the operation';
  END IF;

  -- ---- case 6: cerebro_sync_beneficiarios is suppressed by the lock ----
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT cerebro_sync_beneficiarios(v_deal_y_id) INTO v_sync_result;

  SELECT count(*) INTO v_vigente_count FROM remittance_beneficiaries WHERE operation_id = v_op_y_id AND status = 'vigente';
  SELECT id INTO v_vigente_id FROM remittance_beneficiaries WHERE operation_id = v_op_y_id AND status = 'vigente';

  IF v_sync_result IS DISTINCT FROM 0
     OR v_vigente_count IS DISTINCT FROM 1
     OR v_vigente_id IS DISTINCT FROM v_new_ben_id
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_y_id AND field_name = 'beneficiaries'
          AND action = 'automation_write_suppressed' AND created_at >= v_case_start
     )
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected cerebro_sync_beneficiarios to return 0, leave the corrected beneficiary vigente, and audit automation_write_suppressed; got result=%, vigente_count=%, vigente_id=%', v_sync_result, v_vigente_count, v_vigente_id;
  ELSE
    RAISE NOTICE 'PASS [case 6] automation sync is suppressed once beneficiaries are locked by an operator correction';
  END IF;

  -- ---- case 7: invalid card (15 digits) -> 22023 -----------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_corregir_beneficiario(v_new_ben_id, jsonb_build_object('card_number', '123456789012345'));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected 22023 for a 15-digit card_number, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7] a 15-digit card_number is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8: reassign vigente beneficiary A -> B (same conversation) --
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_reasignar_beneficiario(v_ben_a_id, v_op_b_id) INTO v_reassigned_id;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT status INTO v_status FROM remittance_beneficiaries WHERE id = v_ben_a_id;
  SELECT operation_id, status INTO v_new_op, v_status2 FROM remittance_beneficiaries WHERE id = v_reassigned_id;
  SELECT admin_locked_fields INTO v_locked_a FROM remittance_operations WHERE id = v_op_a_id;
  SELECT admin_locked_fields INTO v_locked_b FROM remittance_operations WHERE id = v_op_b_id;

  IF v_status IS DISTINCT FROM 'reemplazado'
     OR v_new_op IS DISTINCT FROM v_op_b_id
     OR v_status2 IS DISTINCT FROM 'vigente'
     OR NOT (v_locked_a ? 'beneficiaries')
     OR NOT (v_locked_b ? 'beneficiaries')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected source reemplazado, target vigente row, and both operations locked; got source_status=%, target_op=%, target_status=%, locked_a=%, locked_b=%', v_status, v_new_op, v_status2, v_locked_a, v_locked_b;
  ELSE
    RAISE NOTICE 'PASS [case 8] reassignment within the same conversation replaces the source row, creates a vigente row on the target, and locks both operations';
  END IF;

  -- ---- case 9: reassign to op of another conversation -> 22023 ---------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_reasignar_beneficiario(v_reassigned_id, v_op_c_id);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] expected 22023 when reassigning across conversations, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 9] reassignment to an operation in another conversation is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 9] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 10: reassign by viewer -> 42501 -----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_reasignar_beneficiario(v_reassigned_id, v_op_a_id);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] expected 42501 for a viewer calling crm_reasignar_beneficiario, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 10] a viewer is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 10] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'corrections: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'corrections: ALL PASS (10 expectations)';
END $$;

ROLLBACK TO SAVEPOINT corrections;
