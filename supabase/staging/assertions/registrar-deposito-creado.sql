\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- registrar-deposito-creado.sql — self-reverting assertion for the
-- "creado" path of cerebro_registrar_deposito as defined by
-- 114_cutover_retire_sync_pipeline.sql.
--
-- Bug it guards (found 2026-09-26 by a live staging smoke, executions
-- 248780/248784): 114's creado path ends with
--   INSERT INTO remittance_operations ... ON CONFLICT (deal_id) WHERE deal_id IS NOT NULL
-- inside a plpgsql function that RETURNS TABLE(deal_id uuid, ...). The
-- OUT parameter `deal_id` collides with the column and every NEW receipt
-- fails with `column reference "deal_id" is ambiguous`.
--
-- Proves:
--   1. a first receipt on a conversation with no open deal returns
--      accion = 'creado' without raising;
--   2. the created deal exists and has exactly one remittance_operations
--      row linked to it (the INSERT that used to raise).
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker psql against the staging URL, wrapped in BEGIN ... ROLLBACK).
-- Never COMMIT. Never run against production. Builds its own fixtures,
-- same posture as cutover.sql.
--
-- RED:   against staging with 114 as first applied — case 1 FAILS.
-- GREEN: after the fixed function is applied — all cases PASS.

SAVEPOINT registrar_deposito_creado;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;

  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_pipeline_owner uuid;

  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_fail_count     integer := 0;
  v_result         record;
  v_ops            integer;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'deposito-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'deposito test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'deposito owner', 'deposito-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 20) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia,    v_pipeline_id, 'Incidencia',    91) ON CONFLICT (id) DO NOTHING;

  -- Loopback no-op notify config: pg_net never dispatches after rollback.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/deposito-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'deposito-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000301', 'Deposito Cliente', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- ---- case 1: first receipt creates the deal ----------------------------
  BEGIN
    SELECT * INTO v_result
      FROM cerebro_registrar_deposito(
             v_conv_id, 25000, 'GYD', v_por_verificar,
             'DEPOSITO: 25,000 GYD - VERIFICADA' || chr(10) || 'Via: Agente MMG;',
             'comp-assert-' || substr(gen_random_uuid()::text, 1, 8));
  EXCEPTION WHEN OTHERS THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] cerebro_registrar_deposito raised on a first receipt: % (%)', SQLERRM, SQLSTATE;
  END;

  IF v_fail_count = 0 THEN
    IF v_result.accion IS DISTINCT FROM 'creado' OR v_result.deal_id IS NULL THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 1] expected accion=creado with a deal id, got accion=% deal=%', v_result.accion, v_result.deal_id;
    ELSE
      RAISE NOTICE 'PASS [case 1] first receipt returned accion=creado (deal %)', v_result.deal_id;
    END IF;

    -- ---- case 2: the deal (now op) and its operation row exist ---------
    -- The returned value is now an operation id (deal_id IS NULL).
    SELECT count(*) INTO v_ops FROM remittance_operations WHERE remittance_operations.id = v_result.deal_id AND remittance_operations.deal_id IS NULL;
    IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = v_result.deal_id AND deal_id IS NULL) OR v_ops <> 1 THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2] expected the operation plus exactly 1 row, got % rows', v_ops;
    ELSE
      RAISE NOTICE 'PASS [case 2] the created operation exists with exactly 1 row (deal_id IS NULL)';
    END IF;

    -- ---- case 3: a second receipt on the same conversation -------------
    -- Exercises the non-creado paths under the same function: it must not
    -- raise, and the first operation must still have exactly one row.
    BEGIN
      PERFORM * FROM cerebro_registrar_deposito(
                v_conv_id, 5000, 'GYD', v_por_verificar,
                'DEPOSITO: 5,000 GYD - VERIFICADA' || chr(10) || 'Via: Agente MMG;',
                'comp-assert-' || substr(gen_random_uuid()::text, 1, 8));
      SELECT count(*) INTO v_ops FROM remittance_operations WHERE remittance_operations.id = v_result.deal_id AND remittance_operations.deal_id IS NULL;
      IF v_ops <> 1 THEN
        v_fail_count := v_fail_count + 1;
        RAISE WARNING 'FAIL [case 3] after a second receipt the first operation has % rows, expected 1', v_ops;
      ELSE
        RAISE NOTICE 'PASS [case 3] a second receipt did not raise and left the first operation with 1 row';
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 3] second receipt raised: % (%)', SQLERRM, SQLSTATE;
    END;
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'registrar-deposito-creado: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'registrar-deposito-creado: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT registrar_deposito_creado;
