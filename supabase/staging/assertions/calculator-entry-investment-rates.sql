\set ON_ERROR_STOP on
-- Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- calculator-entry-investment-rates.sql -- self-reverting assertion for
-- 236_calculator_entry_investment_rates.sql
--
-- Proves crm_corregir_tasas_entrada_calculadora:
--   case 1  CUP: cup_rate 1060 -> 960 recomputes invertido = (amount / 960) * buy and retorno; facturado, cup_global_rate,
--           usdt_sell_gyd, rate_version_id, amount, service untouched.
--   case 2  ZELLE: only usdt_buy_gyd changes -> invertido = amount * buy; cup_rate untouched.
--   case 3  RECARGA: invertido = amount * cost_gyd * buy, cup_rate follows the buy rate.
--   case 4  SALDO_MOVIL: invertido = (basis / sale) * cost_gyd * buy (amount is in saldo units, not packages).
--   case 5  COMBO and VISA are refused (22023).
--   case 6  cup_rate on a non-CUP service is refused (22023).
--   case 7  non-positive / NaN / no rates at all are refused (22023).
--   case 8  non-admin (agent) refused (42501).
--   case 9  missing entry (P0002); void entry (22023); pending entry (22023).
--   case 10 an entry archived by a weekly cut is refused (22023) and keeps its figures.
--   case 11 NO audit row is written by the edit.
--   case 12 the guard's hole stays narrow: a raw UPDATE of the same completed row is still refused (42501).
--   (237, manual rows; production-shaped fixtures with NULL cup_rate / usdt_buy_gyd / cup_global_rate)
--   case 13 manual CUP (15000 CUP, facturado 5000): needs BOTH rates (22023 with one); with 960 and 240 stores both and gives
--           invertido 3750 / retorno 1250; facturado, raw_line, date, customer untouched; a later edit with one rate keeps the other.
--   case 14 manual ZELLE: buy only -> invertido = amount * buy, cup_rate stays NULL; no buy -> 22023; cup_rate -> 22023.
--   case 15 manual RECARGA, DIRECTO and a discounted ("%") manual ZELLE are refused (22023).
--   case 16 non-admin on a manual row (42501); a manual row of an archived week (22023).
--   case 17 the manual edits wrote no audit row and a raw UPDATE of a manual row is still refused (42501).
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (BEGIN ... \i 236 ... \i 237 ... \i this file ... ROLLBACK), on STAGING only.
-- Never COMMIT. Never run against production. Builds its own fixtures (entries are inserted directly: the fixtures need no live rates).

SAVEPOINT calculator_entry_investment_rates;

DO $$
DECLARE
  v_account_id  uuid;
  v_owner_user  uuid := gen_random_uuid();
  v_admin_user  uuid := gen_random_uuid();
  v_agent_user  uuid := gen_random_uuid();
  v_contact_id  uuid;
  v_conv_id     uuid;
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_admin_claims text;
  v_agent_claims text;
  v_rate_id     uuid;

  v_op          uuid;
  v_op_void     uuid;
  v_op_pending  uuid;
  v_cup uuid; v_zelle uuid; v_recarga uuid; v_saldo uuid; v_combo uuid; v_visa uuid; v_void uuid; v_pending uuid; v_manual uuid; v_man_zelle uuid; v_man_recarga uuid; v_man_directo uuid; v_man_disc uuid; v_man_arch uuid;
  v_archived    uuid;
  v_op_arch     uuid;
  v_week        uuid;

  v_e           remittance_calculator_entries;
  v_before      remittance_calculator_entries;
  v_count       integer;
  v_audits_before integer;
  v_fail_count  integer := 0;
BEGIN
  v_admin_claims := json_build_object('sub', v_admin_user, 'role', 'authenticated')::text;
  v_agent_claims := json_build_object('sub', v_agent_user, 'role', 'authenticated')::text;

  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cir-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cir-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cir-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'calculator investment rates test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'cir owner', 'cir-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user, 'cir admin', 'cir-admin-' || v_admin_user || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user, 'cir agent', 'cir-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO contacts (id, user_id, phone, account_id, name)
  VALUES (gen_random_uuid(), v_owner_user, '15550009902', v_account_id, 'Cliente CIR')
  RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
  VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id)
  RETURNING id INTO v_conv_id;

  -- A rate version only to give the entries a rate_version_id (the edit must leave it alone).
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object(
    'cup_global_rate', 3, 'usdt_buy_gyd', 205, 'usdt_sell_gyd', 215, 'usdt_sell_cup', 1060));
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT id INTO v_rate_id FROM calculator_rate_versions WHERE account_id = v_account_id ORDER BY effective_at DESC LIMIT 1;

  -- Operations (not completed: no feed fires). One per (operation, service) set of fixtures.
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'zelle') RETURNING id INTO v_op;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'zelle') RETURNING id INTO v_op_void;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'zelle') RETURNING id INTO v_op_pending;
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), v_account_id, v_conv_id, 'ready_to_transfer', 'remesa', 'GYD', 10000, 'zelle') RETURNING id INTO v_op_arch;

  -- ---- completed chat-fed fixtures (snapshot as the feed stores it, 235) ---------------------------------------------
  -- CUP: 106,000 CUP at 1060 -> 100 USDT x 205 = 20,500 invertido; facturado = 106,000 / 3.
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op, current_date, 'CUP CIR', 'CUP', 106000, 'CUP',
    3, 1060, 205, 215, v_rate_id, 35333.333333333333, 20500, 14833.333333333333, now()) RETURNING id INTO v_cup;
  -- ZELLE: 100 USD.
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op, current_date, 'ZELLE CIR', 'ZELLE', 100, 'USD',
    3, 1060, 205, 215, v_rate_id, 21500, 20500, 1000, now()) RETURNING id INTO v_zelle;
  -- RECARGA: 2 recharges, 1.5 USDT cost each, cup_rate snapshot = buy rate (199).
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, cost_gyd, sale_gyd, basis_gyd)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op, current_date, 'RECARGA CIR', 'RECARGA', 2, 'REC',
    3, 205, 205, 1000, v_rate_id, 2000, 615, 1385, now(), 1.5, 1000, 2000) RETURNING id INTO v_recarga;
  -- SALDO_MOVIL: 3 packages of 1,000 GYD (basis 3,000), amount in saldo units (3 x 360), cost 2 USDT per package.
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, cost_gyd, sale_gyd, basis_gyd)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op, current_date, 'SALDO CIR', 'SALDO_MOVIL', 1080, 'SM',
    3, 205, 205, 1000, v_rate_id, 3000, 1230, 1770, now(), 2, 1000, 3000) RETURNING id INTO v_saldo;
  -- COMBO and VISA (no rates).
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, cost_gyd, sale_gyd, basis_gyd)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op, current_date, 'COMBO CIR', 'COMBO', 5000, 'GYD',
    v_rate_id, 5000, 3000, 2000, now(), 3000, 5000, 5000) RETURNING id INTO v_combo;
  -- VISA lives on another operation (one entry per operation and service is enough here: (account, operation, service) is unique).
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, cost_gyd, sale_gyd, basis_gyd)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op_pending, current_date, 'VISA CIR', 'VISA', 4000, 'GYD',
    v_rate_id, 4000, 0, 4000, now(), 0, 4000, 4000) RETURNING id INTO v_visa;
  -- Void entry (revived-shaped: figures untouched).
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at, voided_at, void_reason)
  VALUES (v_account_id, 'completed_operation', 'void', v_op_void, current_date, 'VOID CIR', 'ZELLE', 100, 'USD',
    3, 1060, 205, 215, v_rate_id, 21500, 20500, 1000, now(), now(), 'fixture') RETURNING id INTO v_void;
  -- Pending entry (no figures, 104).
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    missing_inputs)
  VALUES (v_account_id, 'completed_operation', 'verified_pending', v_op_pending, current_date, 'PEND CIR', 'ZELLE', 100, 'USD',
    ARRAY['usdtSellGyd']) RETURNING id INTO v_pending;
  -- Manual entries as production holds them (228): no snapshot at all, figures as typed.
  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at, raw_line)
  VALUES (v_account_id, 'manual', 'completed', current_date, 'Manual CIR', 'CUP', 15000, 'CUP',
    5000, 3750, 1250, now(), '• Manual CIR 15k CUP (240/960)') RETURNING id INTO v_manual;
  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at, raw_line)
  VALUES (v_account_id, 'manual', 'completed', current_date, 'Manual Zelle CIR', 'ZELLE', 100, 'USD',
    26000, 24000, 2000, now(), '• Manual Zelle CIR 100 Zelle (240/260)') RETURNING id INTO v_man_zelle;
  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at, raw_line)
  VALUES (v_account_id, 'manual', 'completed', current_date, 'Manual Recarga CIR', 'RECARGA', 2, 'REC',
    2000, 600, 1400, now(), '• Manual Recarga CIR 2 Recarga (1.5/1000/200)') RETURNING id INTO v_man_recarga;
  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at, raw_line)
  VALUES (v_account_id, 'manual', 'completed', current_date, 'Manual Directo CIR', 'DIRECTO', 4000, 'GYD',
    4000, 0, 4000, now(), '• Manual Directo CIR visa 4000') RETURNING id INTO v_man_directo;
  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at, raw_line)
  VALUES (v_account_id, 'manual', 'completed', current_date, 'Manual Desc CIR', 'ZELLE', 110, 'USD',
    28600, 24000, 4600, now(), '• Manual Desc CIR 110 Zelle (10%/240/260)') RETURNING id INTO v_man_disc;
  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
    facturado_gyd, invertido_gyd, retorno_gyd, completed_at, raw_line)
  VALUES (v_account_id, 'manual', 'completed', current_date, 'Manual Arch CIR', 'ZELLE', 50, 'USD',
    13000, 12000, 1000, now(), '• Manual Arch CIR 50 Zelle (240/260)') RETURNING id INTO v_man_arch;
  -- An entry archived by a weekly cut.
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    cup_global_rate, cup_rate, usdt_buy_gyd, usdt_sell_gyd, rate_version_id, facturado_gyd, invertido_gyd, retorno_gyd, completed_at)
  VALUES (v_account_id, 'completed_operation', 'completed', v_op_arch, current_date, 'ARCH CIR', 'CUP', 106000, 'CUP',
    3, 1060, 205, 215, v_rate_id, 35333.333333333333, 20500, 14833.333333333333, now()) RETURNING id INTO v_archived;
  INSERT INTO remittance_calculator_weeks (account_id, manual_totals, chat_totals)
  VALUES (v_account_id, '{}'::jsonb, '{}'::jsonb) RETURNING id INTO v_week;
  INSERT INTO remittance_calculator_week_entries (entry_id, week_id, account_id) VALUES (v_archived, v_week, v_account_id);
  INSERT INTO remittance_calculator_week_entries (entry_id, week_id, account_id) VALUES (v_man_arch, v_week, v_account_id);

  SELECT count(*) INTO v_audits_before FROM remittance_admin_audit WHERE account_id = v_account_id;

  -- ===========================================================================
  -- CASE 1 -- CUP: 1060 -> 960 changes only the investment.
  -- ===========================================================================
  SELECT * INTO v_before FROM remittance_calculator_entries WHERE id = v_cup;
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, NULL, 960);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_cup;
  IF v_e.cup_rate IS DISTINCT FROM 960 OR v_e.usdt_buy_gyd IS DISTINCT FROM 205
     OR abs(v_e.invertido_gyd - (106000.0 / 960) * 205) > 0.000001
     OR abs(v_e.retorno_gyd - (v_e.facturado_gyd - v_e.invertido_gyd)) > 0.000001
     OR v_e.facturado_gyd IS DISTINCT FROM v_before.facturado_gyd OR v_e.cup_global_rate IS DISTINCT FROM v_before.cup_global_rate
     OR v_e.usdt_sell_gyd IS DISTINCT FROM v_before.usdt_sell_gyd OR v_e.rate_version_id IS DISTINCT FROM v_before.rate_version_id
     OR v_e.amount IS DISTINCT FROM v_before.amount OR v_e.service IS DISTINCT FROM v_before.service OR v_e.status IS DISTINCT FROM 'completed'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] CUP edit: cup_rate=% buy=% invertido=% retorno=% facturado=%', v_e.cup_rate, v_e.usdt_buy_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.facturado_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 1] a CUP entry re-costed at 960: only invertido/retorno (and its own rate) changed';
  END IF;
  -- Both rates at once.
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, 200, 1000);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_cup;
  IF abs(v_e.invertido_gyd - 106000.0 / 1000 * 200) > 0.000001 OR v_e.cup_rate <> 1000 OR v_e.usdt_buy_gyd <> 200 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1b] CUP edit of both rates: invertido=% cup_rate=% buy=%', v_e.invertido_gyd, v_e.cup_rate, v_e.usdt_buy_gyd;
  ELSE
    RAISE NOTICE 'PASS [case 1b] both rates of a CUP entry in one call';
  END IF;

  -- ===========================================================================
  -- CASE 2 -- ZELLE: buy rate only.
  -- ===========================================================================
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_tasas_entrada_calculadora(v_zelle, 190, NULL);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_zelle;
  IF v_e.usdt_buy_gyd <> 190 OR v_e.invertido_gyd <> 19000 OR v_e.retorno_gyd <> 2500 OR v_e.facturado_gyd <> 21500 OR v_e.cup_rate <> 1060 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] ZELLE edit: buy=% invertido=% retorno=% cup_rate=%', v_e.usdt_buy_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.cup_rate;
  ELSE
    RAISE NOTICE 'PASS [case 2] a ZELLE entry re-costed at the new buy rate';
  END IF;

  -- ===========================================================================
  -- CASE 3 -- RECARGA: units x USDT cost x buy; cup_rate follows.
  -- ===========================================================================
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_tasas_entrada_calculadora(v_recarga, 200, NULL);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_recarga;
  IF v_e.invertido_gyd <> 600 OR v_e.retorno_gyd <> 1400 OR v_e.usdt_buy_gyd <> 200 OR v_e.cup_rate <> 200 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] RECARGA edit: invertido=% retorno=% buy=% cup_rate=%', v_e.invertido_gyd, v_e.retorno_gyd, v_e.usdt_buy_gyd, v_e.cup_rate;
  ELSE
    RAISE NOTICE 'PASS [case 3] a RECARGA entry re-costed (cup_rate follows the buy rate)';
  END IF;

  -- ===========================================================================
  -- CASE 4 -- SALDO_MOVIL: packages (basis / package price) x USDT cost x buy.
  -- ===========================================================================
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  PERFORM crm_corregir_tasas_entrada_calculadora(v_saldo, 200, NULL);
  PERFORM set_config('request.jwt.claims', '', true);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_saldo;
  IF v_e.invertido_gyd <> 1200 OR v_e.retorno_gyd <> 1800 OR v_e.usdt_buy_gyd <> 200 OR v_e.cup_rate <> 200 OR v_e.amount <> 1080 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] SALDO_MOVIL edit: invertido=% retorno=% buy=% cup_rate=% amount=%', v_e.invertido_gyd, v_e.retorno_gyd, v_e.usdt_buy_gyd, v_e.cup_rate, v_e.amount;
  ELSE
    RAISE NOTICE 'PASS [case 4] a SALDO_MOVIL entry re-costed from its package count';
  END IF;

  -- ===========================================================================
  -- CASE 5 -- COMBO and VISA are refused.
  -- ===========================================================================
  FOR v_count IN 1..2 LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims', v_admin_claims, true);
      PERFORM crm_corregir_tasas_entrada_calculadora(CASE v_count WHEN 1 THEN v_combo ELSE v_visa END, 200, NULL);
      PERFORM set_config('request.jwt.claims', '', true);
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 5.%] expected 22023 for a COMBO/VISA entry', v_count;
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('request.jwt.claims', '', true);
      IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 5.%] COMBO/VISA refused (%)', v_count, SQLERRM;
      ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 5.%] expected 22023, got % (%)', v_count, SQLSTATE, SQLERRM; END IF;
    END;
  END LOOP;

  -- ===========================================================================
  -- CASE 6 -- cup_rate on a non-CUP service.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_tasas_entrada_calculadora(v_zelle, NULL, 960);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected 22023 for cup_rate on a ZELLE entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 6] cup_rate on a non-CUP entry refused';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 6] expected 22023, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;

  -- ===========================================================================
  -- CASE 7 -- non-positive / NaN / no rate at all.
  -- ===========================================================================
  FOR v_count IN 1..5 LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims', v_admin_claims, true);
      CASE v_count
        WHEN 1 THEN PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, 0, NULL);
        WHEN 2 THEN PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, -5, NULL);
        WHEN 3 THEN PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, NULL, 0);
        WHEN 4 THEN PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, 'NaN'::numeric, NULL);
        ELSE PERFORM crm_corregir_tasas_entrada_calculadora(v_cup, NULL, NULL);
      END CASE;
      PERFORM set_config('request.jwt.claims', '', true);
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7.%] expected 22023', v_count;
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('request.jwt.claims', '', true);
      IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 7.%] invalid rate refused (%)', v_count, SQLERRM;
      ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 7.%] expected 22023, got % (%)', v_count, SQLSTATE, SQLERRM; END IF;
    END;
  END LOOP;

  -- ===========================================================================
  -- CASE 8 -- a non-admin is refused.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    PERFORM crm_corregir_tasas_entrada_calculadora(v_zelle, 100, NULL);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected 42501 for an agent';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN RAISE NOTICE 'PASS [case 8] admin+ only';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 8] expected 42501, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;

  -- ===========================================================================
  -- CASE 9 -- missing (P0002), void, pending (22023).
  -- ===========================================================================
  FOR v_count IN 1..3 LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims', v_admin_claims, true);
      PERFORM crm_corregir_tasas_entrada_calculadora(
        CASE v_count WHEN 1 THEN gen_random_uuid() WHEN 2 THEN v_void ELSE v_pending END, 100, NULL);
      PERFORM set_config('request.jwt.claims', '', true);
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 9.%] expected a refusal', v_count;
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('request.jwt.claims', '', true);
      IF SQLSTATE = (CASE v_count WHEN 1 THEN 'P0002' ELSE '22023' END) THEN RAISE NOTICE 'PASS [case 9.%] refused (%)', v_count, SQLERRM;
      ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 9.%] unexpected % (%)', v_count, SQLSTATE, SQLERRM; END IF;
    END;
  END LOOP;

  -- ===========================================================================
  -- CASE 10 -- an archived-week entry is refused and untouched.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_tasas_entrada_calculadora(v_archived, NULL, 960);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 10] expected 22023 for an archived entry';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' AND (SELECT invertido_gyd = 20500 AND cup_rate = 1060 FROM remittance_calculator_entries WHERE id = v_archived) THEN
      RAISE NOTICE 'PASS [case 10] an archived entry is refused and keeps its figures';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 10] got % (%)', SQLSTATE, SQLERRM; END IF;
  END;

  -- ===========================================================================
  -- CASE 11 -- no audit row (owner decision).
  -- ===========================================================================
  SELECT count(*) INTO v_count FROM remittance_admin_audit WHERE account_id = v_account_id;
  IF v_count <> v_audits_before THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 11] expected no audit rows from the rate edits, found %', v_count - v_audits_before;
  ELSE
    RAISE NOTICE 'PASS [case 11] the rate edits wrote no audit row';
  END IF;

  -- ===========================================================================
  -- CASE 12 -- the hole is narrow: a raw UPDATE is still refused.
  -- ===========================================================================
  BEGIN
    UPDATE remittance_calculator_entries SET usdt_buy_gyd = 1, invertido_gyd = 1 WHERE id = v_cup;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 12] expected the guard to refuse a raw UPDATE outside the RPC';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN RAISE NOTICE 'PASS [case 12] a raw UPDATE is still refused';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 12] expected 42501, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;


  -- ===========================================================================
  -- CASE 13 -- manual CUP without a snapshot (237): both rates required, stored, figures recomputed.
  -- ===========================================================================
  SELECT count(*) INTO v_audits_before FROM remittance_admin_audit WHERE account_id = v_account_id;
  SELECT * INTO v_before FROM remittance_calculator_entries WHERE id = v_manual;
  FOR v_count IN 1..2 LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims', v_admin_claims, true);
      IF v_count = 1 THEN PERFORM crm_corregir_tasas_entrada_calculadora(v_manual, 240, NULL);
      ELSE PERFORM crm_corregir_tasas_entrada_calculadora(v_manual, NULL, 960); END IF;
      PERFORM set_config('request.jwt.claims', '', true);
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 13.%] expected 22023 (a manual CUP row needs both rates)', v_count;
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('request.jwt.claims', '', true);
      IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 13.%] one rate is not enough (%)', v_count, SQLERRM;
      ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 13.%] expected 22023, got % (%)', v_count, SQLSTATE, SQLERRM; END IF;
    END;
  END LOOP;

  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  v_e := crm_corregir_tasas_entrada_calculadora(v_manual, 240, 960);
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_e.usdt_buy_gyd = 240 AND v_e.cup_rate = 960 AND v_e.invertido_gyd = 3750 AND v_e.retorno_gyd = 1250
     AND v_e.facturado_gyd = v_before.facturado_gyd AND v_e.raw_line IS NOT DISTINCT FROM v_before.raw_line
     AND v_e.entry_date = v_before.entry_date AND v_e.customer_name = v_before.customer_name AND v_e.amount = 15000
     AND v_e.source = 'manual' AND v_e.cup_global_rate IS NULL AND v_e.status = 'completed' THEN
    RAISE NOTICE 'PASS [case 13] manual CUP stored 240/960 -> invertido 3750, retorno 1250, the rest untouched';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 13] manual CUP row after the edit: %', to_jsonb(v_e);
  END IF;

  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  v_e := crm_corregir_tasas_entrada_calculadora(v_manual, NULL, 1060);
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_e.usdt_buy_gyd = 240 AND v_e.cup_rate = 1060 AND abs(v_e.invertido_gyd - (15000 / 1060.0) * 240) < 0.000001 THEN
    RAISE NOTICE 'PASS [case 13b] a later edit with one rate keeps the stored other one';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 13b] manual CUP second edit: %', to_jsonb(v_e);
  END IF;

  -- ===========================================================================
  -- CASE 14 -- manual ZELLE: buy only; cup_rate stays NULL.
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_tasas_entrada_calculadora(v_man_zelle, NULL, 960);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 14.1] expected 22023 (cup_rate on a non-CUP manual row)';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 14.1] cup_rate refused off CUP';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 14.1] expected 22023, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;
  PERFORM set_config('request.jwt.claims', v_admin_claims, true);
  v_e := crm_corregir_tasas_entrada_calculadora(v_man_zelle, 238, NULL);
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_e.usdt_buy_gyd = 238 AND v_e.cup_rate IS NULL AND v_e.invertido_gyd = 23800 AND v_e.retorno_gyd = 2200 AND v_e.facturado_gyd = 26000 THEN
    RAISE NOTICE 'PASS [case 14] manual ZELLE at 238 -> invertido 23800, retorno 2200, cup_rate stays NULL';
  ELSE
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 14] manual ZELLE row after the edit: %', to_jsonb(v_e);
  END IF;

  -- ===========================================================================
  -- CASE 15 -- manual services whose formula cannot be rebuilt from the row.
  -- ===========================================================================
  FOR v_count IN 1..3 LOOP
    BEGIN
      PERFORM set_config('request.jwt.claims', v_admin_claims, true);
      PERFORM crm_corregir_tasas_entrada_calculadora(
        CASE v_count WHEN 1 THEN v_man_recarga WHEN 2 THEN v_man_directo ELSE v_man_disc END, 200, NULL);
      PERFORM set_config('request.jwt.claims', '', true);
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 15.%] expected 22023', v_count;
    EXCEPTION WHEN OTHERS THEN
      PERFORM set_config('request.jwt.claims', '', true);
      IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 15.%] refused (%)', v_count, SQLERRM;
      ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 15.%] expected 22023, got % (%)', v_count, SQLSTATE, SQLERRM; END IF;
    END;
  END LOOP;

  -- ===========================================================================
  -- CASE 16 -- a non-admin on a manual row (42501); a manual row of an archived week (22023).
  -- ===========================================================================
  BEGIN
    PERFORM set_config('request.jwt.claims', v_agent_claims, true);
    PERFORM crm_corregir_tasas_entrada_calculadora(v_man_zelle, 200, NULL);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 16.1] expected 42501 for an agent on a manual row';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN RAISE NOTICE 'PASS [case 16.1] admin+ only on manual rows';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 16.1] expected 42501, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;
  BEGIN
    PERFORM set_config('request.jwt.claims', v_admin_claims, true);
    PERFORM crm_corregir_tasas_entrada_calculadora(v_man_arch, 200, NULL);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 16.2] expected 22023 for a manual row of an archived week';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN RAISE NOTICE 'PASS [case 16.2] archived-week manual row refused';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 16.2] expected 22023, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;

  -- ===========================================================================
  -- CASE 17 -- no audit row from the manual edits; a raw UPDATE of a manual row is still refused.
  -- ===========================================================================
  SELECT count(*) INTO v_count FROM remittance_admin_audit WHERE account_id = v_account_id;
  IF v_count <> v_audits_before THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 17.1] expected no audit rows from the manual rate edits, found %', v_count - v_audits_before;
  ELSE
    RAISE NOTICE 'PASS [case 17.1] the manual rate edits wrote no audit row';
  END IF;
  BEGIN
    UPDATE remittance_calculator_entries SET usdt_buy_gyd = 1, invertido_gyd = 1 WHERE id = v_manual;
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 17.2] expected the guard to refuse a raw UPDATE of a manual row';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '42501' THEN RAISE NOTICE 'PASS [case 17.2] a raw UPDATE of a manual row is still refused';
    ELSE v_fail_count := v_fail_count + 1; RAISE WARNING 'FAIL [case 17.2] expected 42501, got % (%)', SQLSTATE, SQLERRM; END IF;
  END;

  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'calculator-entry-investment-rates: % expectation(s) FAILED -- see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'calculator-entry-investment-rates: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT calculator_entry_investment_rates;
