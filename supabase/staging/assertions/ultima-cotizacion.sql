-- ultima-cotizacion.sql — self-reverting assertion for
-- 153_ultima_cotizacion.sql (B1.1: the bot must be able to say how much the
-- recipient gets BEFORE the deposit).
--
--   case 1 — cerebro_registrar_cotizacion stores the quote; a second quote
--            replaces it (one row per conversation).
--   case 2 — NULL conversation or NULL destination amount is a harmless no-op.
--   case 3 — cerebro_monto_recibe: open operation with no destination amount
--            yet + fresh quote -> returns the quote (the real test case: the
--            beneficiary arrived before the deposit).
--   case 4 — once the open operation HAS a destination amount, that wins
--            over the quote.
--   case 5 — a quote older than the conversation's last closed remesa is
--            ignored (it belonged to a previous remesa).
--   case 6 — a quote older than 24 hours is ignored.
--   case 7 — nothing at all -> NULLs (the bot says no amount).
--   case 8 — the table has RLS on, and neither function is executable by
--            anon or authenticated.
--
-- RED (before 153): the functions do not exist.
-- GREEN (after 153): all eight pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT ultima_cotizacion;

DO $$
DECLARE
  v_owner_user uuid := gen_random_uuid();
  v_dummy_hash CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc  uuid;
  v_ct1 uuid; v_conv1 uuid; v_op1 uuid;
  v_ct5 uuid; v_conv5 uuid;
  v_ct6 uuid; v_conv6 uuid;
  v_ct7 uuid; v_conv7 uuid;
  v_n    integer;
  v_val  numeric;
  v_mon  text;
  v_fail_count integer := 0;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'uc-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'ultima cotizacion test account', v_owner_user)
  RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_owner_user, 'uc owner', 'uc-owner-' || v_owner_user || '@test.invalid', v_acc, 'owner');

  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900153001', 'UC 1', v_acc) RETURNING id INTO v_ct1;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct1, v_acc) RETURNING id INTO v_conv1;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900153005', 'UC 5', v_acc) RETURNING id INTO v_ct5;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct5, v_acc) RETURNING id INTO v_conv5;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900153006', 'UC 6', v_acc) RETURNING id INTO v_ct6;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct6, v_acc) RETURNING id INTO v_conv6;
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '59900153007', 'UC 7', v_acc) RETURNING id INTO v_ct7;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_ct7, v_acc) RETURNING id INTO v_conv7;

  -- ===========================================================================
  -- CASE 1 — store, then replace.
  -- ===========================================================================
  PERFORM cerebro_registrar_cotizacion(v_conv1, 5000, 15000, 'CUP', 'calcular_envio');
  PERFORM cerebro_registrar_cotizacion(v_conv1, 10000, 30000, 'CUP', 'calcular_envio');
  SELECT count(*) INTO v_n FROM cerebro_ultima_cotizacion WHERE conversation_id = v_conv1;
  SELECT destino_monto, destino_moneda INTO v_val, v_mon FROM cerebro_ultima_cotizacion WHERE conversation_id = v_conv1;
  IF v_n <> 1 OR v_val IS DISTINCT FROM 30000 OR v_mon IS DISTINCT FROM 'CUP' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected one row 30000 CUP, got rows=% % %', v_n, v_val, v_mon;
  ELSE
    RAISE NOTICE 'PASS [case 1] quote stored and replaced (one row per conversation)';
  END IF;

  -- ===========================================================================
  -- CASE 2 — NULL inputs are no-ops.
  -- ===========================================================================
  PERFORM cerebro_registrar_cotizacion(NULL, 1, 1, 'CUP', 'calcular_envio');
  PERFORM cerebro_registrar_cotizacion(v_conv7, 1000, NULL, 'CUP', 'calcular_envio');
  SELECT count(*) INTO v_n FROM cerebro_ultima_cotizacion WHERE conversation_id = v_conv7;
  IF v_n <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a NULL destination created a row';
  ELSE
    RAISE NOTICE 'PASS [case 2] NULL inputs are no-ops';
  END IF;

  -- ===========================================================================
  -- CASE 3 — open operation without destination amount + fresh quote.
  -- ===========================================================================
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, quoted_source_amount)
  VALUES (v_acc, v_conv1, v_ct1, 'cuban_card', 'collecting_information', 0)
  RETURNING id INTO v_op1;
  SELECT valor, moneda INTO v_val, v_mon FROM cerebro_monto_recibe(v_conv1);
  IF v_val IS DISTINCT FROM 30000 OR v_mon IS DISTINCT FROM 'CUP' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected the quote 30000 CUP, got % %', v_val, v_mon;
  ELSE
    RAISE NOTICE 'PASS [case 3] beneficiary before deposit -> the quote is used';
  END IF;

  -- ===========================================================================
  -- CASE 4 — the operation's own destination amount wins.
  -- ===========================================================================
  UPDATE remittance_operations
     SET quoted_destination_amount = 36000, destination_currency = 'CUP'
   WHERE id = v_op1;
  SELECT valor, moneda INTO v_val, v_mon FROM cerebro_monto_recibe(v_conv1);
  IF v_val IS DISTINCT FROM 36000 OR v_mon IS DISTINCT FROM 'CUP' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected the operation amount 36000 CUP, got % %', v_val, v_mon;
  ELSE
    RAISE NOTICE 'PASS [case 4] the operation destination amount wins over the quote';
  END IF;

  -- ===========================================================================
  -- CASE 5 — a quote from before the last closed remesa is ignored.
  -- ===========================================================================
  PERFORM cerebro_registrar_cotizacion(v_conv5, 10000, 30000, 'CUP', 'calcular_envio');
  UPDATE cerebro_ultima_cotizacion SET cotizado_en = now() - interval '3 hours' WHERE conversation_id = v_conv5;
  PERFORM set_config('wacrm.origin', 'admin', true);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status, created_at, completed_at)
  VALUES (v_acc, v_conv5, v_ct5, 'cuban_card', 'completed', now() - interval '2 hours', now() - interval '1 hour');
  PERFORM set_config('wacrm.origin', '', true);
  SELECT valor, moneda INTO v_val, v_mon FROM cerebro_monto_recibe(v_conv5);
  IF v_val IS NOT NULL OR v_mon IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a quote from a previous remesa was used: % %', v_val, v_mon;
  ELSE
    RAISE NOTICE 'PASS [case 5] a quote older than the last closed remesa is ignored';
  END IF;

  -- ===========================================================================
  -- CASE 6 — a quote older than 24 hours is ignored.
  -- ===========================================================================
  PERFORM cerebro_registrar_cotizacion(v_conv6, 10000, 38, 'USD', 'calcular_usd_desde_gyd');
  UPDATE cerebro_ultima_cotizacion SET cotizado_en = now() - interval '25 hours' WHERE conversation_id = v_conv6;
  SELECT valor, moneda INTO v_val, v_mon FROM cerebro_monto_recibe(v_conv6);
  IF v_val IS NOT NULL OR v_mon IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] a stale (25h) quote was used: % %', v_val, v_mon;
  ELSE
    RAISE NOTICE 'PASS [case 6] a quote older than 24 hours is ignored';
  END IF;

  -- ===========================================================================
  -- CASE 7 — nothing at all.
  -- ===========================================================================
  SELECT valor, moneda INTO v_val, v_mon FROM cerebro_monto_recibe(v_conv7);
  IF v_val IS NOT NULL OR v_mon IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected NULLs, got % %', v_val, v_mon;
  ELSE
    RAISE NOTICE 'PASS [case 7] nothing -> NULLs';
  END IF;

  -- ===========================================================================
  -- CASE 8 — locked down.
  -- ===========================================================================
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'cerebro_ultima_cotizacion')
     OR has_function_privilege('anon', 'cerebro_registrar_cotizacion(uuid,numeric,numeric,text,text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'cerebro_registrar_cotizacion(uuid,numeric,numeric,text,text)', 'EXECUTE')
     OR has_function_privilege('anon', 'cerebro_monto_recibe(uuid)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'cerebro_monto_recibe(uuid)', 'EXECUTE')
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] RLS off or a function is exposed to anon/authenticated';
  ELSE
    RAISE NOTICE 'PASS [case 8] RLS on; functions not exposed to anon/authenticated';
  END IF;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'ultima-cotizacion: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;
  RAISE NOTICE 'ultima-cotizacion: ALL PASS (8 expectations)';
END $$;

ROLLBACK TO SAVEPOINT ultima_cotizacion;
