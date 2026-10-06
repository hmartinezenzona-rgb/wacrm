\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- destination-amount.sql — self-reverting assertion for
-- 100_destination_amount_calc.sql
--
-- Proves crm_calcular_monto_destino / crm_tasa_vigente and their triggers:
-- the zelle (GYD -> USD, floor) and cuban_card (GYD -> CUP, round) formulas,
-- recalculation on quoted_source_amount changes, clearing when a second
-- beneficiary appears, silent no-op when no rate is on file, respecting
-- both the 096 admin_locked_fields lock (operator correction wins) and a
-- beneficiary's own pre-existing non-calculated amount, non-GYD and
-- closed-operation exclusion, and the three new columns surfaced by
-- crm_operaciones_de_conversacion.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures (account +
-- owner/agent personas + one conversation), so it can run alongside or
-- independently of the other assertion files.

-- SAVEPOINT and ROLLBACK TO SAVEPOINT are plain transaction-control
-- commands and cannot be issued from inside a PL/pgSQL DO block, so they
-- bracket it here instead.
SAVEPOINT destination_amount;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_op_zelle_id    uuid; v_ben_zelle_id   uuid; v_ben_zelle2_id uuid;
  v_op_cuban_id    uuid; v_ben_cuban_id   uuid;
  v_op_missing_id  uuid; v_ben_missing_id uuid;
  v_op_manual_id   uuid;
  v_op_partial_id  uuid; v_ben_partial_id uuid;
  v_op_nongyd_id   uuid; v_ben_nongyd_id  uuid;
  v_op_closed_id   uuid; v_ben_closed_id  uuid;
  v_op_read_id     uuid; v_ben_read_id    uuid;

  v_amount         numeric;
  v_ben_amount     numeric;
  v_currency       text;
  v_ben_currency   text;
  v_rate           numeric;
  v_origin         text;
  v_amt_origin     text;
  v_locked         jsonb;

  v_fail_count     integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see corrections.sql's fixture comment for why. Operations and
  -- beneficiaries are created directly (no deals/pipeline needed): this
  -- migration's triggers fire on remittance_operations/remittance_
  -- beneficiaries writes regardless of what wrote them.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'destamt-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'destamt-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'destination amount test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'destamt owner', 'destamt-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'destamt agent', 'destamt-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000501', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- Fixed test rates, dated far in the future so they are always "latest"
  -- regardless of what real staging data exists. Since 113 `tasas` is a view
  -- over calculator_rate_versions (usd = usdt_sell_gyd, gyd = cup_global_rate),
  -- so the rates are appended there; the Zelle tier price (216) is set too, since
  -- 215-218 a Zelle beneficiary is priced by cerebro_zelle_cotizar_gyd.
  INSERT INTO calculator_rate_versions (account_id, cup_global_rate, usdt_sell_gyd, zelle_sell_gyd, set_by, effective_at)
  VALUES (v_account_id, 3, 260, 260, v_owner_user, now() + interval '1000 days');

  -- ---- case 1: zelle, single beneficiary -------------------------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 26100)
  RETURNING id INTO v_op_zelle_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_zelle_id, 'zelle', 'Beneficiary Zelle', 'vigente', 'staging_test', 1)
  RETURNING id INTO v_ben_zelle_id;

  SELECT quoted_destination_amount, destination_currency, quoted_destination_rate, quoted_destination_origin
    INTO v_amount, v_currency, v_rate, v_origin
    FROM remittance_operations WHERE id = v_op_zelle_id;
  SELECT amount, currency, amount_origin INTO v_ben_amount, v_ben_currency, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_zelle_id;

  IF v_amount IS DISTINCT FROM 100 OR v_currency IS DISTINCT FROM 'USD' OR v_rate IS DISTINCT FROM 260 OR v_origin IS DISTINCT FROM 'calculated'
     OR v_ben_amount IS DISTINCT FROM 100 OR v_ben_currency IS DISTINCT FROM 'USD' OR v_amt_origin IS DISTINCT FROM 'calculated'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected op 100 USD rate 260 calculated + beneficiary 100 USD calculated; got op amount=%, currency=%, rate=%, origin=%, ben amount=%, currency=%, origin=%',
      v_amount, v_currency, v_rate, v_origin, v_ben_amount, v_ben_currency, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 1] zelle single beneficiary calculates 100 USD at rate 260 for both operation and beneficiary';
  END IF;

  -- ---- case 2: cuban_card, single beneficiary --------------------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 75000)
  RETURNING id INTO v_op_cuban_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_cuban_id, 'cuban_card', 'Beneficiary Cuban', 'vigente', 'staging_test', 1)
  RETURNING id INTO v_ben_cuban_id;

  SELECT quoted_destination_amount, destination_currency, quoted_destination_rate, quoted_destination_origin
    INTO v_amount, v_currency, v_rate, v_origin
    FROM remittance_operations WHERE id = v_op_cuban_id;
  SELECT amount, currency, amount_origin INTO v_ben_amount, v_ben_currency, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_cuban_id;

  IF v_amount IS DISTINCT FROM 225000 OR v_currency IS DISTINCT FROM 'CUP' OR v_rate IS DISTINCT FROM 3 OR v_origin IS DISTINCT FROM 'calculated'
     OR v_ben_amount IS DISTINCT FROM 225000 OR v_ben_currency IS DISTINCT FROM 'CUP' OR v_amt_origin IS DISTINCT FROM 'calculated'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected op 225000 CUP rate 3 calculated + beneficiary 225000 CUP calculated; got op amount=%, currency=%, rate=%, origin=%, ben amount=%, currency=%, origin=%',
      v_amount, v_currency, v_rate, v_origin, v_ben_amount, v_ben_currency, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 2] cuban_card single beneficiary calculates 225000 CUP at rate 3 for both operation and beneficiary';
  END IF;

  -- ---- case 3: source amount change recalculates -----------------------
  UPDATE remittance_operations SET quoted_source_amount = 52000 WHERE id = v_op_zelle_id;

  SELECT quoted_destination_amount, quoted_destination_rate, quoted_destination_origin
    INTO v_amount, v_rate, v_origin
    FROM remittance_operations WHERE id = v_op_zelle_id;
  SELECT amount, amount_origin INTO v_ben_amount, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_zelle_id;

  IF v_amount IS DISTINCT FROM 200 OR v_rate IS DISTINCT FROM 260 OR v_origin IS DISTINCT FROM 'calculated'
     OR v_ben_amount IS DISTINCT FROM 200 OR v_amt_origin IS DISTINCT FROM 'calculated'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected recalculation to 200 USD on quoted_source_amount change; got op amount=%, rate=%, origin=%, ben amount=%, origin=%',
      v_amount, v_rate, v_origin, v_ben_amount, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 3] changing quoted_source_amount recalculates the destination amount (200 USD)';
  END IF;

  -- ---- case 4: a second vigente beneficiary clears the calculation -----
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_zelle_id, 'zelle', 'Beneficiary Zelle 2', 'vigente', 'staging_test', 2)
  RETURNING id INTO v_ben_zelle2_id;

  SELECT quoted_destination_amount, quoted_destination_rate, quoted_destination_origin
    INTO v_amount, v_rate, v_origin
    FROM remittance_operations WHERE id = v_op_zelle_id;
  SELECT amount, amount_origin INTO v_ben_amount, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_zelle_id;

  IF v_amount IS NOT NULL OR v_rate IS NOT NULL OR v_origin IS NOT NULL
     OR v_ben_amount IS NOT NULL OR v_amt_origin IS NOT NULL
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected a second vigente beneficiary to clear the calculated amount; got op amount=%, rate=%, origin=%, first beneficiary amount=%, origin=%',
      v_amount, v_rate, v_origin, v_ben_amount, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 4] a second vigente beneficiary clears the operation''s calculated amount and the first beneficiary''s amount';
  END IF;

  -- ---- case 5: no rate on file -> stays NULL, no error -----------------
  -- (113) `tasas` is a view and calculator_rate_versions is append-only, and an
  -- appended version with NULL rates does not hide the older ones; rows cannot be
  -- deleted either (remittance_calculator_entries references them). So "no usd
  -- rate on file" is reached by blanking the usd selling rate and the Zelle tier
  -- prices of every version, with the append-only trigger switched off for that
  -- UPDATE only. Zelle then has neither a tier price nor the usd fallback (215-218).
  -- ROLLBACK restores everything.
  ALTER TABLE calculator_rate_versions DISABLE TRIGGER calculator_rate_versions_append_only;
  UPDATE calculator_rate_versions
     SET usdt_sell_gyd = NULL, zelle_sell_gyd = NULL, zelle_sell_gyd_1000 = NULL, zelle_sell_gyd_2000 = NULL;
  ALTER TABLE calculator_rate_versions ENABLE TRIGGER calculator_rate_versions_append_only;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 10000)
  RETURNING id INTO v_op_missing_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_missing_id, 'zelle', 'Beneficiary Missing Rate', 'vigente', 'staging_test', 1)
  RETURNING id INTO v_ben_missing_id;

  SELECT quoted_destination_amount, quoted_destination_origin INTO v_amount, v_origin
    FROM remittance_operations WHERE id = v_op_missing_id;
  SELECT amount, amount_origin INTO v_ben_amount, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_missing_id;

  -- Restore the usd rate for the remaining cases.
  INSERT INTO calculator_rate_versions (account_id, cup_global_rate, usdt_sell_gyd, zelle_sell_gyd, set_by, effective_at)
  VALUES (v_account_id, 3, 260, 260, v_owner_user, now() + interval '1000 days');

  IF v_amount IS NOT NULL OR v_origin IS NOT NULL OR v_ben_amount IS NOT NULL OR v_amt_origin IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected no calculation without a usd rate on file; got op amount=%, origin=%, ben amount=%, origin=%',
      v_amount, v_origin, v_ben_amount, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 5] a missing exchange rate leaves both amounts NULL without raising an error';
  END IF;

  -- ---- case 6: an operator correction locks and wins over automation ---
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 30000)
  RETURNING id INTO v_op_manual_id;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  PERFORM crm_corregir_operacion(v_op_manual_id, jsonb_build_object('quoted_destination_amount', 105));
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT quoted_destination_amount, quoted_destination_origin, quoted_destination_rate, admin_locked_fields
    INTO v_amount, v_origin, v_rate, v_locked
    FROM remittance_operations WHERE id = v_op_manual_id;

  IF v_amount IS DISTINCT FROM 105 OR v_origin IS DISTINCT FROM 'manual' OR v_rate IS NOT NULL OR NOT (v_locked ? 'quoted_destination_amount') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6a] expected a human correction to set 105/manual/rate NULL and lock the field; got amount=%, origin=%, rate=%, locked=%',
      v_amount, v_origin, v_rate, v_locked;
  ELSE
    RAISE NOTICE 'PASS [case 6a] an operator correction stamps origin=manual, clears the rate, and locks quoted_destination_amount';
  END IF;

  -- Automation then changes quoted_source_amount (no JWT): the lock must
  -- stop the trigger from recalculating over the human's value.
  UPDATE remittance_operations SET quoted_source_amount = 999999 WHERE id = v_op_manual_id;

  SELECT quoted_destination_amount, quoted_destination_origin INTO v_amount, v_origin
    FROM remittance_operations WHERE id = v_op_manual_id;

  IF v_amount IS DISTINCT FROM 105 OR v_origin IS DISTINCT FROM 'manual' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6b] expected the locked manual value to survive an automation quoted_source_amount change; got amount=%, origin=%',
      v_amount, v_origin;
  ELSE
    RAISE NOTICE 'PASS [case 6b] a locked manual destination amount survives an automation-driven quoted_source_amount change';
  END IF;

  -- ---- case 7: beneficiary with a pre-existing non-calculated amount ---
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 26000)
  RETURNING id INTO v_op_partial_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position, amount, currency)
  VALUES (gen_random_uuid(), v_op_partial_id, 'zelle', 'Beneficiary Partial', 'vigente', 'staging_test', 1, 50, 'USD')
  RETURNING id INTO v_ben_partial_id;

  SELECT amount, amount_origin INTO v_ben_amount, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_partial_id;
  SELECT quoted_destination_amount, quoted_destination_origin INTO v_amount, v_origin
    FROM remittance_operations WHERE id = v_op_partial_id;

  IF v_ben_amount IS DISTINCT FROM 50 OR v_amt_origin IS NOT NULL
     OR v_amount IS DISTINCT FROM 100 OR v_origin IS DISTINCT FROM 'calculated'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected the beneficiary''s pre-existing amount (50) to survive while the operation is still calculated (100); got ben amount=%, origin=%, op amount=%, origin=%',
      v_ben_amount, v_amt_origin, v_amount, v_origin;
  ELSE
    RAISE NOTICE 'PASS [case 7] a beneficiary''s pre-existing non-calculated amount is left untouched while the operation is still calculated';
  END IF;

  -- ---- case 8: non-GYD source currency -> not calculated ---------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'USD', 500)
  RETURNING id INTO v_op_nongyd_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_nongyd_id, 'zelle', 'Beneficiary NonGYD', 'vigente', 'staging_test', 1)
  RETURNING id INTO v_ben_nongyd_id;

  SELECT quoted_destination_amount, quoted_destination_origin INTO v_amount, v_origin
    FROM remittance_operations WHERE id = v_op_nongyd_id;
  SELECT amount, amount_origin INTO v_ben_amount, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_nongyd_id;

  IF v_amount IS NOT NULL OR v_origin IS NOT NULL OR v_ben_amount IS NOT NULL OR v_amt_origin IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected no calculation for a non-GYD source_currency; got op amount=%, origin=%, ben amount=%, origin=%',
      v_amount, v_origin, v_ben_amount, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 8] a non-GYD source_currency is never calculated';
  END IF;

  -- ---- case 9: a closed (cancelled) operation is not calculated --------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'cancelled', 'remesa', 'GYD', 26000)
  RETURNING id INTO v_op_closed_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_closed_id, 'zelle', 'Beneficiary Closed', 'vigente', 'staging_test', 1)
  RETURNING id INTO v_ben_closed_id;

  SELECT quoted_destination_amount, quoted_destination_origin INTO v_amount, v_origin
    FROM remittance_operations WHERE id = v_op_closed_id;
  SELECT amount, amount_origin INTO v_ben_amount, v_amt_origin
    FROM remittance_beneficiaries WHERE id = v_ben_closed_id;

  IF v_amount IS NOT NULL OR v_origin IS NOT NULL OR v_ben_amount IS NOT NULL OR v_amt_origin IS NOT NULL THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] expected no calculation for a cancelled operation; got op amount=%, origin=%, ben amount=%, origin=%',
      v_amount, v_origin, v_ben_amount, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 9] a cancelled (closed) operation is never calculated';
  END IF;

  -- ---- case 10: crm_operaciones_de_conversacion surfaces the 3 columns -
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 26100)
  RETURNING id INTO v_op_read_id;

  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_read_id, 'zelle', 'Beneficiary Read', 'vigente', 'staging_test', 1)
  RETURNING id INTO v_ben_read_id;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  SELECT operation_quoted_destination_amount, operation_quoted_destination_rate, operation_quoted_destination_origin, beneficiary_amount, beneficiary_amount_origin
    INTO v_amount, v_rate, v_origin, v_ben_amount, v_amt_origin
    FROM crm_operaciones_de_conversacion(v_conv_id)
   WHERE operation_id = v_op_read_id;
  PERFORM set_config('request.jwt.claims', '', true);

  IF v_amount IS DISTINCT FROM 100 OR v_rate IS DISTINCT FROM 260 OR v_origin IS DISTINCT FROM 'calculated'
     OR v_ben_amount IS DISTINCT FROM 100 OR v_amt_origin IS DISTINCT FROM 'calculated'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] expected crm_operaciones_de_conversacion to surface the calculated columns; got op amount=%, rate=%, origin=%, ben amount=%, origin=%',
      v_amount, v_rate, v_origin, v_ben_amount, v_amt_origin;
  ELSE
    RAISE NOTICE 'PASS [case 10] crm_operaciones_de_conversacion returns operation_quoted_destination_rate, operation_quoted_destination_origin and beneficiary_amount_origin';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'destination-amount: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'destination-amount: ALL PASS (11 expectations)';
END $$;

ROLLBACK TO SAVEPOINT destination_amount;
