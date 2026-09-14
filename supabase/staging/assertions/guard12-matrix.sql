-- guard12-matrix.sql — self-reverting assertion for 096_admin_locks_audit_sync.sql
--
-- Proves guard 12a (remittance_operations.status, into/out of `completed`)
-- and guard 12b (deals.stage_id, into/out of Entregada, remesas pipeline
-- only), for five callers: postgres with no JWT (n8n via Supavisor),
-- service_role with no JWT, and an `authenticated` session as viewer,
-- agent, and admin.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK — see
-- the SDD apply-progress for port-chat-operations-calculator Slice 4 for
-- the exact invocation (docker psql against $PGURL, wrapped in
-- BEGIN ... \i 096 ... \i this file ... ROLLBACK). Never COMMIT. Never run
-- against production.
--
-- FIXTURES: this script creates its own account, four auth.users rows
-- (one bootstrap owner used only to own the fixture account, plus
-- viewer/agent/admin test personas moved into that account), the remesas
-- pipeline (78220927-...) and its Entregada/Incidencia stages if absent
-- (staging currently lacks pipeline/stage config data — see apply-progress
-- obs 42), one contact/conversation, one standalone operation (no
-- deal_id, so guard-12a checks below never cross paths with the deal->
-- operation sync trigger) and one deal in the Incidencia stage (no
-- conversation_id, so guard-12b checks never cascade into
-- remittance_operations either). All of it lives inside SAVEPOINT
-- guard12_matrix and is rolled back to that savepoint once every
-- expectation has been checked, so it leaves no trace even if the
-- caller's outer transaction were ever committed by mistake.
--
-- WHY NO `SET LOCAL ROLE` FOR THE HUMAN CASES: guard 12a/12b (design
-- decision 12) is driven entirely by `is_account_member(...)`, which reads
-- `auth.uid()` from the `request.jwt.claims` GUC — never `current_user` /
-- `session_user` (decision 12's own evidence column explicitly rejects a
-- current_user-based gate). Production traffic that reaches these two
-- tables always executes as the migration/function-owner role regardless
-- of caller (n8n connects directly as `postgres`; every future CRM write
-- goes through a SECURITY DEFINER RPC also owned by `postgres`) — only
-- the JWT claims differ per caller. So this matrix stays connected as the
-- role the harness provided (superuser) throughout and varies only
-- `request.jwt.claims`, which is the faithful simulation for THIS guard
-- and also sidesteps `deals`' separate RLS layer and any
-- not-yet-granted table privilege on `remittance_operations`, neither of
-- which this migration touches. `postgres` and `service_role` are
-- mechanically identical to this guard (neither carries a `sub` claim);
-- they are still reported as two distinct matrix rows for a legible report.

-- SAVEPOINT and ROLLBACK TO SAVEPOINT are plain transaction-control
-- commands and cannot be issued from inside a PL/pgSQL DO block, so they
-- bracket it here instead.
SAVEPOINT guard12_matrix;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_admin_user     uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_op_id          uuid;
  v_op_id2         uuid;
  v_deal_id        uuid;
  v_deal_id2       uuid;
  v_entregada      CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;
  v_case           record;
  v_status         text;
  v_stage          uuid;
  v_case_start     timestamptz;
  v_fail_count     integer := 0;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- auth.users rows are needed only for the FK from profiles.user_id.
  -- NOTE: this script does NOT rely on the on_auth_user_created /
  -- handle_new_user() signup trigger — it inserts accounts/profiles
  -- directly. Discovered live on staging while authoring this script:
  -- the deployed handle_new_user() is still the pre-017 version (it
  -- inserts profiles without account_id/account_role at all), so on
  -- this schema every real signup today silently gets NO account_id
  -- (caught by the function's own EXCEPTION handler, RAISE WARNING,
  -- profile row never created) — a pre-existing production bug,
  -- unrelated to this migration, out of scope here.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guard12-owner-'  || v_owner_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guard12-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guard12-agent-'  || v_agent_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guard12-admin-'  || v_admin_user  || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'guard12-matrix test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user,  'guard12 owner',  'guard12-owner-'  || v_owner_user  || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_viewer_user, 'guard12 viewer', 'guard12-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer'),
    (gen_random_uuid(), v_agent_user,  'guard12 agent',  'guard12-agent-'  || v_agent_user  || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_admin_user,  'guard12 admin',  'guard12-admin-'  || v_admin_user  || '@test.invalid', v_account_id, 'admin');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_entregada, v_pipeline_id, 'Entregada', 90) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 91) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() (pre-existing trigger, unrelated to 096) fires on
  -- every deals INSERT and needs a non-null notify_url — staging lacks
  -- cerebro_config data (apply-progress obs 42). pg_net queues the POST
  -- asynchronously in this same transaction, so a loopback no-op URL never
  -- actually gets dispatched once this script rolls back.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/guard12-matrix-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'guard12-matrix-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000101', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'collecting_information') RETURNING id INTO v_op_id;

  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_incidencia, 'guard12-matrix fixture', v_account_id) RETURNING id INTO v_deal_id;

  RAISE NOTICE 'guard12-matrix: fixtures ready (account=%, operation=%, deal=%)', v_account_id, v_op_id, v_deal_id;

  -- ---- Matrix A: remittance_operations.status, into AND out of completed
  FOR v_case IN
    SELECT * FROM (VALUES
      ('into', NULL::uuid,    true,  'postgres (n8n, no JWT) -> completed'),
      ('into', NULL::uuid,    true,  'service_role (no JWT) -> completed'),
      ('into', v_viewer_user, true,  'viewer -> completed'),
      ('into', v_agent_user,  false, 'agent -> completed'),
      ('into', v_admin_user,  false, 'admin -> completed'),
      ('out',  NULL::uuid,    true,  'postgres (n8n, no JWT) -> out of completed'),
      ('out',  NULL::uuid,    true,  'service_role (no JWT) -> out of completed'),
      ('out',  v_viewer_user, true,  'viewer -> out of completed'),
      ('out',  v_agent_user,  false, 'agent -> out of completed'),
      ('out',  v_admin_user,  false, 'admin -> out of completed')
    ) AS t(direction, jwt_sub, expect_suppressed, label)
  LOOP
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations
       SET status = CASE WHEN v_case.direction = 'into' THEN 'collecting_information' ELSE 'completed' END
     WHERE id = v_op_id;
    PERFORM set_config('wacrm.origin', '', true);
    PERFORM set_config('request.jwt.claims', '', true);

    v_case_start := clock_timestamp();
    IF v_case.jwt_sub IS NOT NULL THEN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_case.jwt_sub, 'role', 'authenticated')::text, true);
    END IF;

    UPDATE remittance_operations
       SET status = CASE WHEN v_case.direction = 'into' THEN 'completed' ELSE 'incident' END
     WHERE id = v_op_id;

    PERFORM set_config('request.jwt.claims', '', true);
    SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_id;

    IF v_case.expect_suppressed THEN
      IF (v_case.direction = 'into' AND v_status IS DISTINCT FROM 'collecting_information')
      OR (v_case.direction = 'out'  AND v_status IS DISTINCT FROM 'completed') THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] expected suppressed, got status=%', v_case.label, v_status;
      ELSIF NOT EXISTS (
        SELECT 1 FROM remittance_admin_audit
         WHERE row_id = v_op_id AND created_at >= v_case_start
           AND action = (CASE WHEN v_case.direction = 'into' THEN 'automation_completion_suppressed' ELSE 'automation_revert_suppressed' END)
      ) THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] expected a suppression audit row, found none', v_case.label;
      ELSE
        RAISE NOTICE 'PASS [%] suppressed and audited', v_case.label;
      END IF;
    ELSE
      IF (v_case.direction = 'into' AND v_status IS DISTINCT FROM 'completed')
      OR (v_case.direction = 'out'  AND v_status IS DISTINCT FROM 'incident') THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] expected the transition to succeed, got status=%', v_case.label, v_status;
      ELSE
        RAISE NOTICE 'PASS [%] transition allowed', v_case.label;
      END IF;
    END IF;
  END LOOP;

  -- ---- Matrix B: deals.stage_id, into AND out of Entregada
  FOR v_case IN
    SELECT * FROM (VALUES
      ('into', NULL::uuid,    true,  'postgres (n8n, no JWT) -> Entregada'),
      ('into', NULL::uuid,    true,  'service_role (no JWT) -> Entregada'),
      ('into', v_viewer_user, true,  'viewer -> Entregada'),
      ('into', v_agent_user,  false, 'agent -> Entregada'),
      ('into', v_admin_user,  false, 'admin -> Entregada'),
      ('out',  NULL::uuid,    true,  'postgres (n8n, no JWT) -> out of Entregada'),
      ('out',  NULL::uuid,    true,  'service_role (no JWT) -> out of Entregada'),
      ('out',  v_viewer_user, true,  'viewer -> out of Entregada'),
      ('out',  v_agent_user,  false, 'agent -> out of Entregada'),
      ('out',  v_admin_user,  false, 'admin -> out of Entregada')
    ) AS t(direction, jwt_sub, expect_suppressed, label)
  LOOP
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE deals
       SET stage_id = CASE WHEN v_case.direction = 'into' THEN v_incidencia ELSE v_entregada END
     WHERE id = v_deal_id;
    PERFORM set_config('wacrm.origin', '', true);
    PERFORM set_config('request.jwt.claims', '', true);

    v_case_start := clock_timestamp();
    IF v_case.jwt_sub IS NOT NULL THEN
      PERFORM set_config('request.jwt.claims', json_build_object('sub', v_case.jwt_sub, 'role', 'authenticated')::text, true);
    END IF;

    UPDATE deals
       SET stage_id = CASE WHEN v_case.direction = 'into' THEN v_entregada ELSE v_incidencia END
     WHERE id = v_deal_id;

    PERFORM set_config('request.jwt.claims', '', true);
    SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_id;

    IF v_case.expect_suppressed THEN
      IF (v_case.direction = 'into' AND v_stage IS DISTINCT FROM v_incidencia)
      OR (v_case.direction = 'out'  AND v_stage IS DISTINCT FROM v_entregada) THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] expected suppressed, got stage_id=%', v_case.label, v_stage;
      ELSIF NOT EXISTS (
        SELECT 1 FROM remittance_admin_audit
         WHERE table_name = 'deals' AND row_id = v_deal_id AND created_at >= v_case_start
           AND action = (CASE WHEN v_case.direction = 'into' THEN 'automation_completion_suppressed' ELSE 'automation_revert_suppressed' END)
      ) THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] expected a suppression audit row, found none', v_case.label;
      ELSE
        RAISE NOTICE 'PASS [%] suppressed and audited', v_case.label;
      END IF;
    ELSE
      IF (v_case.direction = 'into' AND v_stage IS DISTINCT FROM v_entregada)
      OR (v_case.direction = 'out'  AND v_stage IS DISTINCT FROM v_incidencia) THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [%] expected the transition to succeed, got stage_id=%', v_case.label, v_stage;
      ELSE
        RAISE NOTICE 'PASS [%] transition allowed', v_case.label;
      END IF;
    END IF;
  END LOOP;

  -- ---- Case C: INSERT-time coercion (automation only — no JWT)
  PERFORM set_config('request.jwt.claims', '', true);
  v_case_start := clock_timestamp();
  INSERT INTO remittance_operations (id, account_id, conversation_id, status)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'completed') RETURNING id INTO v_op_id2;
  SELECT status INTO v_status FROM remittance_operations WHERE id = v_op_id2;
  IF v_status IS DISTINCT FROM 'incident' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [INSERT operation as completed, automation] expected coercion to incident, got status=%', v_status;
  ELSIF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op_id2 AND created_at >= v_case_start AND action = 'automation_completion_suppressed') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [INSERT operation as completed, automation] expected a suppression audit row, found none';
  ELSE
    RAISE NOTICE 'PASS [INSERT operation as completed, automation] coerced to incident and audited';
  END IF;

  v_case_start := clock_timestamp();
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_entregada, 'guard12-matrix insert-coercion fixture', v_account_id) RETURNING id INTO v_deal_id2;
  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_id2;
  IF v_stage IS DISTINCT FROM v_incidencia THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [INSERT deal into Entregada, automation] expected coercion to Incidencia, got stage_id=%', v_stage;
  ELSIF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE table_name = 'deals' AND row_id = v_deal_id2 AND created_at >= v_case_start AND action = 'automation_completion_suppressed') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [INSERT deal into Entregada, automation] expected a suppression audit row, found none';
  ELSE
    RAISE NOTICE 'PASS [INSERT deal into Entregada, automation] coerced to Incidencia and audited';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'guard12-matrix: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'guard12-matrix: ALL PASS (22 expectations)';
END $$;

ROLLBACK TO SAVEPOINT guard12_matrix;
