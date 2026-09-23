-- rounding-parity.sql — self-reverting assertion for
-- 111_usd_amount_rounds_down.sql
--
-- Proves the one thing 111 exists for: the panel and the calculator ledger
-- now put the SAME number of whole units on the same remesa, rounded DOWN
-- in the business's favour. A deposit of 75,000 GYD at rate 260 is 288.46
-- units, so both must say 288 — the panel through crm_calcular_monto_destino,
-- the ledger through the feed trigger. Delivering 289 would hand over
-- 289 x 260 = 75,140 GYD of value against a 75,000 GYD deposit, 140 GYD out
-- of the business's pocket; this is the n8n bot's rule, now applied here too.
--
-- Also checks that 111 changed only the rounding: an exact division still
-- yields that exact count (no phantom missing unit), a cuban card is
-- untouched, a closed operation is never recalculated, and an admin-locked
-- amount still wins.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK. Never
-- COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT rounding_parity;

DO $$
DECLARE
  v_account_id  uuid;
  v_owner_user  uuid := gen_random_uuid();
  v_agent_user  uuid := gen_random_uuid();
  v_contact_id  uuid;
  v_conv_id     uuid;
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_op_frac     uuid;
  v_op_exact    uuid;
  v_op_cup      uuid;
  v_op_closed   uuid;
  v_op_locked   uuid;

  v_panel       numeric;
  v_ledger      numeric;
  v_currency    text;
  v_agent_claims text;

  v_fail_count  integer := 0;
BEGIN
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'round-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'round-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'rounding parity account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'round owner', 'round-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'round agent', 'round-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550000905', v_account_id, 'Cliente Redondeo')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  -- The panel reads `tasas`; the ledger reads calculator_rate_versions.
  -- Both are given 260 for the dollar rail so any difference that shows up
  -- is the ROUNDING, not the rate.
  INSERT INTO tasas (fecha, moneda, tasa_cup, fuente, actualizada_at) VALUES
    (current_date + 1000, 'usd', 260, 'staging_test', now()),
    (current_date + 1000, 'gyd', 3, 'staging_test', now());

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 3, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 975));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- case 1: the panel rounds a fractional quotient DOWN ----------------
  -- 75000 / 260 = 288.46
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 75000, 'zelle')
  RETURNING id INTO v_op_frac;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_frac, 'zelle', 'Beneficiario Zelle', 'vigente', 'staging_test', 1);

  SELECT quoted_destination_amount, destination_currency INTO v_panel, v_currency
    FROM remittance_operations WHERE id = v_op_frac;

  IF v_panel IS DISTINCT FROM 288 OR v_currency IS DISTINCT FROM 'USD' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected the panel to quote 288 USD for 75000/260, got % %', v_panel, v_currency;
  ELSE
    RAISE NOTICE 'PASS [case 1] the panel rounds 288.46 down to 288';
  END IF;

  -- ---- case 2: and the ledger agrees on the very same remesa ------------
  PERFORM set_config('request.jwt.claims', v_agent_claims, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_frac;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT amount INTO v_ledger FROM remittance_calculator_entries WHERE operation_id = v_op_frac;

  IF v_ledger IS DISTINCT FROM v_panel THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] panel says % units, ledger says % — they must match', v_panel, v_ledger;
  ELSE
    RAISE NOTICE 'PASS [case 2] panel and ledger record the same % units for one remesa', v_ledger;
  END IF;

  -- ---- case 3: an exact division gains no phantom unit ------------------
  -- 78000 / 260 = 300 exactly; rounding up must not make it 301.
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 78000, 'zelle')
  RETURNING id INTO v_op_exact;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_exact, 'zelle', 'Beneficiario Exacto', 'vigente', 'staging_test', 1);

  SELECT quoted_destination_amount INTO v_panel FROM remittance_operations WHERE id = v_op_exact;
  IF v_panel IS DISTINCT FROM 300 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected exactly 300 for 78000/260, got %', v_panel;
  ELSE
    RAISE NOTICE 'PASS [case 3] an exact quotient stays exact — no phantom unit';
  END IF;

  -- ---- case 4: a cuban card is untouched by this change -----------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 75000, 'cuban_card')
  RETURNING id INTO v_op_cup;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, card_number, phone, status, source, position)
  VALUES (gen_random_uuid(), v_op_cup, 'cuban_card', '9224069992922522', '53821203', 'vigente', 'staging_test', 1);

  SELECT quoted_destination_amount, destination_currency INTO v_panel, v_currency
    FROM remittance_operations WHERE id = v_op_cup;
  IF v_panel IS DISTINCT FROM 225000 OR v_currency IS DISTINCT FROM 'CUP' THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected 225000 CUP for 75000*3, got % %', v_panel, v_currency;
  ELSE
    RAISE NOTICE 'PASS [case 4] the CUP conversion is unchanged';
  END IF;

  -- ---- case 5: a closed operation is never recalculated -----------------
  -- Reuses the remesa from case 1, which is already completed at 288. The
  -- rate then moves, and the function is asked to recalculate it: a closed
  -- remesa must keep the figure it was actually delivered at, whatever the
  -- rate does afterwards.
  INSERT INTO tasas (fecha, moneda, tasa_cup, fuente, actualizada_at)
  VALUES (current_date + 1001, 'usd', 300, 'staging_test', now());

  PERFORM crm_calcular_monto_destino(v_op_frac);

  SELECT quoted_destination_amount INTO v_panel FROM remittance_operations WHERE id = v_op_frac;
  IF v_panel IS DISTINCT FROM 288 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] a completed remesa moved from 288 to % after a rate change — history must not move', v_panel;
  ELSE
    RAISE NOTICE 'PASS [case 5] a later rate change never rewrites a remesa already delivered';
  END IF;

  -- ---- case 6: an admin-locked amount still wins ------------------------
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method, quoted_destination_amount, destination_currency, quoted_destination_origin, admin_locked_fields)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'deposit_verification', 'remesa', 'GYD', 75000, 'zelle', 250, 'USD', 'manual',
          jsonb_build_object('quoted_destination_amount', jsonb_build_object('by', 'tester', 'at', now())))
  RETURNING id INTO v_op_locked;
  INSERT INTO remittance_beneficiaries (id, operation_id, beneficiary_type, name, status, source, position)
  VALUES (gen_random_uuid(), v_op_locked, 'zelle', 'Beneficiario Bloqueado', 'vigente', 'staging_test', 1);

  PERFORM crm_calcular_monto_destino(v_op_locked);

  SELECT quoted_destination_amount INTO v_panel FROM remittance_operations WHERE id = v_op_locked;
  IF v_panel IS DISTINCT FROM 250 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] an admin-locked amount was overwritten with %', v_panel;
  ELSE
    RAISE NOTICE 'PASS [case 6] a human correction still beats the calculation';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'rounding-parity: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'rounding-parity: ALL PASS (6 expectations)';
END $$;

ROLLBACK TO SAVEPOINT rounding_parity;
