-- =====================================================================
-- Assertions for 235 (the ledger bills the deposit): an operation-fed ledger line's facturado is the money that came in for that
-- line (its share of the operation's deposited GYD), not delivered units x price. invertido is unchanged (what the delivery
-- costs) and retorno = facturado - invertido, so the rounding leftover lands in the return.
--
-- RUN ONLY INSIDE A TRANSACTION THAT IS ROLLED BACK; builds its own account, users, rates and operations, leaves nothing.
--   BEGIN; <this file>; ROLLBACK;     (never `psql -1` alone)
-- Every expectation that fails RAISEs a WARNING; the script ends in an exception when any failed.
--
-- Rates of the fixture account: cup_global_rate 1.5, usdt_buy_gyd 240, usdt_sell_gyd 260, usdt_sell_cup 400, efectivo_usd_gyd 290,
-- recarga_costo_usdt 20, saldo_costo_usdt 3.  Zelle sells by tier (cerebro_zelle_tiers reads the newest rate version): 260 (50-999 USD),
-- 250 (1,000-1,999), 245 (2,000+).
-- =====================================================================

CREATE FUNCTION pg_temp.lbd_op(p_acct uuid, p_conv uuid, p_gyd numeric, p_method text, p_service text DEFAULT 'remesa') RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acct, p_conv, 'ready_to_transfer', p_service, 'GYD', p_gyd, p_method) RETURNING id INTO v;
  RETURN v;
END $$;

CREATE FUNCTION pg_temp.lbd_done(p_op uuid, p_actor uuid) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_actor, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = p_actor WHERE id = p_op;
  PERFORM set_config('request.jwt.claims', '', true);
END $$;

-- One check: label, the line of (operation, service), expected amount / facturado / invertido / retorno.
CREATE FUNCTION pg_temp.lbd_chk(p_label text, p_op uuid, p_service text, p_amount numeric, p_fact numeric, p_inv numeric, p_ret numeric) RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE e remittance_calculator_entries;
BEGIN
  SELECT * INTO e FROM remittance_calculator_entries WHERE operation_id = p_op AND service = p_service AND source = 'completed_operation';
  IF e.id IS NULL OR e.status IS DISTINCT FROM 'completed' OR e.amount IS DISTINCT FROM p_amount OR e.facturado_gyd IS DISTINCT FROM p_fact
     OR e.invertido_gyd IS DISTINCT FROM p_inv OR e.retorno_gyd IS DISTINCT FROM p_ret THEN
    RAISE WARNING 'FAIL [%] expected % / fact % / inv % / ret %; got status=% amount=% fact=% inv=% ret=%',
      p_label, p_amount, p_fact, p_inv, p_ret, e.status, e.amount, e.facturado_gyd, e.invertido_gyd, e.retorno_gyd;
    RETURN 1;
  END IF;
  RAISE NOTICE 'PASS [%]', p_label;
  RETURN 0;
END $$;

DO $$
DECLARE
  v_account_id uuid; v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_contact uuid; v_conv uuid;
  v_hash CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_fail integer := 0;
  v_carlos uuid; v_exact uuid; v_cup uuid; v_tier uuid; v_tier_left uuid; v_cash uuid; v_cash_left uuid;
  v_clasica uuid; v_tropical uuid; v_mixed uuid; v_mixed2 uuid; v_visa uuid; v_combo uuid; v_saldo uuid; v_recarga uuid;
  v_lock uuid; v_rcpt uuid; v_old uuid; v_pend uuid;
  v_before jsonb; v_after jsonb; v_manual uuid; v_n integer; v_e remittance_calculator_entries;
  v_bad text;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'lbd-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent]) u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'ledger-bills-the-deposit test account', v_owner) RETURNING id INTO v_account_id;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'lbd owner', 'lbd-' || v_owner || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin, 'lbd admin', 'lbd-' || v_admin || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent, 'lbd agent', 'lbd-' || v_agent || '@test.invalid', v_account_id, 'agent');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '15550000935', v_account_id, 'Cliente LBD') RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_contact, v_account_id) RETURNING id INTO v_conv;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('cup_global_rate', 1.5, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260,
    'usdt_sell_cup', 400, 'efectivo_usd_gyd', 290, 'recarga_costo_usdt', 20, 'saldo_costo_usdt', 3,
    'zelle_sell_gyd', 260, 'zelle_sell_gyd_1000', 250, 'zelle_sell_gyd_2000', 245));
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- operations (legacy single-service shape: the rail is the delivery method) ----------
  v_carlos     := pg_temp.lbd_op(v_account_id, v_conv, 47100,  'zelle');
  v_exact      := pg_temp.lbd_op(v_account_id, v_conv, 65000,  'zelle');
  v_cup        := pg_temp.lbd_op(v_account_id, v_conv, 75000,  'cuban_card');
  v_tier       := pg_temp.lbd_op(v_account_id, v_conv, 250000, 'zelle');
  v_tier_left  := pg_temp.lbd_op(v_account_id, v_conv, 259740, 'zelle');
  v_cash       := pg_temp.lbd_op(v_account_id, v_conv, 29000,  'efectivo_usd');
  v_cash_left  := pg_temp.lbd_op(v_account_id, v_conv, 47100,  'efectivo_usd');
  v_clasica    := pg_temp.lbd_op(v_account_id, v_conv, 26100,  'clasica');
  v_tropical   := pg_temp.lbd_op(v_account_id, v_conv, 53010,  'tropical');
  v_visa       := pg_temp.lbd_op(v_account_id, v_conv, 10000,  NULL, 'visa');
  v_combo      := pg_temp.lbd_op(v_account_id, v_conv, 40000,  NULL, 'combo');
  v_saldo      := pg_temp.lbd_op(v_account_id, v_conv, 3000,   NULL, 'saldo');
  v_recarga    := pg_temp.lbd_op(v_account_id, v_conv, 6200,   NULL, 'recarga');
  UPDATE remittance_operations SET combo_costo_gyd = 30000 WHERE id = v_combo;

  -- Edge: a destination amount fixed by a human (200 USD) on a 65,000 deposit; receipts that sum less than the deposit.
  v_lock := pg_temp.lbd_op(v_account_id, v_conv, 65000, 'zelle');
  UPDATE remittance_operations
     SET quoted_destination_amount = 200, destination_currency = 'USD', quoted_destination_origin = 'admin',
         admin_locked_fields = jsonb_build_object('quoted_destination_amount', jsonb_build_object('at', now(), 'by', v_admin))
   WHERE id = v_lock;
  v_rcpt := pg_temp.lbd_op(v_account_id, v_conv, 65000, 'zelle');
  INSERT INTO remittance_operation_receipts (operation_id, comp_id, amount, currency, receipt_status, source)
  VALUES (v_rcpt, 'lbd-r1', 60000, 'GYD', 'verified', 'bot');

  -- A MIXED reparto: a card for 30,000 CUP and a Zelle for 207 USD from a 75,000 deposit; a second one whose CUP share has decimals.
  v_mixed := pg_temp.lbd_op(v_account_id, v_conv, 75000, NULL);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source, block_index)
  VALUES (v_mixed, 'cuban_card', 'Tarjeta L', '1234123412341234', '55599998888', 30000, 'CUP', 1, 'vigente', 'admin_addition', 1);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source, block_index)
  VALUES (v_mixed, 'zelle', 'Zelle L', 'l@zelle.test', 207, 'USD', 2, 'vigente', 'admin_addition', 1);
  v_mixed2 := pg_temp.lbd_op(v_account_id, v_conv, 75000, NULL);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source, block_index)
  VALUES (v_mixed2, 'cuban_card', 'Tarjeta L2', '4321432143214321', '55588887777', 10000, 'CUP', 1, 'vigente', 'admin_addition', 1);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source, block_index)
  VALUES (v_mixed2, 'zelle', 'Zelle L2', 'l2@zelle.test', 250, 'USD', 2, 'vigente', 'admin_addition', 1);

  -- A line fed BEFORE this rule (old shape: 181 x 260 = 47,060): its operation is completed afterwards and must not rewrite it.
  v_old := pg_temp.lbd_op(v_account_id, v_conv, 47100, 'zelle');
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
         basis_gyd, usdt_sell_gyd, facturado_gyd, invertido_gyd, retorno_gyd, completed_at)
  VALUES (v_account_id, 'completed_operation', 'completed', v_old, current_date, 'Cliente LBD', 'ZELLE', 181, 'USD', 47100, 260, 47060, 43440, 3620, now());

  -- A manual entry typed by hand (no deposit known).
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
         facturado_gyd, invertido_gyd, retorno_gyd, completed_at, actor_user_id)
  VALUES (v_account_id, 'manual', 'completed', NULL, current_date, 'Manual LBD', 'ZELLE', 181, 'USD', 47060, 43440, 3620, now(), v_agent)
  RETURNING id INTO v_manual;

  -- ---- complete everything (the trigger feeds the ledger) ----------------------------
  PERFORM pg_temp.lbd_done(o, v_agent) FROM unnest(ARRAY[v_carlos, v_exact, v_cup, v_tier, v_tier_left, v_cash, v_cash_left, v_clasica, v_tropical,
                                                          v_visa, v_combo, v_saldo, v_recarga, v_lock, v_rcpt, v_mixed, v_mixed2, v_old]) o;

  -- ---- the cases ---------------------------------------------------------------------
  -- 1. Carlos: 47,100 GYD Zelle at 260 -> 181 USD; facturado is the deposit, the 40 GYD leftover lands in the return.
  v_fail := v_fail + pg_temp.lbd_chk('1 carlos 47,100 -> 181 USD', v_carlos, 'ZELLE', 181, 47100, 43440, 3660);
  -- 2. An exact case is unchanged.
  v_fail := v_fail + pg_temp.lbd_chk('2 exact 65,000 -> 250 USD', v_exact, 'ZELLE', 250, 65000, 60000, 5000);
  -- 3. CUP unchanged (facturado already was the deposit).
  v_fail := v_fail + pg_temp.lbd_chk('3 cup 75,000', v_cup, 'CUP', 112500, 75000, 67500, 7500);
  -- 4. Zelle tiers: exactly 1,000 USD at 250 (unchanged) and 259,740 -> 1,038 USD at 250 (259,500 billed before, 259,740 now).
  v_fail := v_fail + pg_temp.lbd_chk('4a tier 250,000 -> 1,000 USD', v_tier, 'ZELLE', 1000, 250000, 240000, 10000);
  v_fail := v_fail + pg_temp.lbd_chk('4b tier 259,740 -> 1,038 USD', v_tier_left, 'ZELLE', 1038, 259740, 249120, 10620);
  -- 5. Cash USD: 29,000 -> 100 at 290 exact; 47,100 -> 162 at 290 (46,980 before, 47,100 now).
  v_fail := v_fail + pg_temp.lbd_chk('5a cash 29,000 -> 100 USD', v_cash, 'EFECTIVO', 100, 29000, 24000, 5000);
  v_fail := v_fail + pg_temp.lbd_chk('5b cash 47,100 -> 162 USD', v_cash_left, 'EFECTIVO', 162, 47100, 38880, 8220);
  -- 6. Clasica 26,100 at 260 -> 100 USD (26,000 before); Tropical 53,010 -> 203 USD (52,780 before).
  v_fail := v_fail + pg_temp.lbd_chk('6a clasica 26,100 -> 100 USD', v_clasica, 'CLASICA', 100, 26100, 24000, 2100);
  v_fail := v_fail + pg_temp.lbd_chk('6b tropical 53,010 -> 203 USD', v_tropical, 'TROPICAL', 203, 53010, 48720, 4290);
  -- 7. Fixed-price services are unchanged: visa 10,000 (invertido 0), combo 40,000 (cost 30,000), saldo 3 packages, recarga 1 unit.
  v_fail := v_fail + pg_temp.lbd_chk('7a visa 10,000', v_visa, 'VISA', 10000, 10000, 0, 10000);
  v_fail := v_fail + pg_temp.lbd_chk('7b combo 40,000 cost 30,000', v_combo, 'COMBO', 40000, 40000, 30000, 10000);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_saldo AND service = 'SALDO_MOVIL';
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.facturado_gyd IS DISTINCT FROM 3000 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [7c saldo 3,000] got status=% facturado=%', v_e.status, v_e.facturado_gyd;
  ELSE RAISE NOTICE 'PASS [7c saldo 3,000]'; END IF;
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_recarga AND service = 'RECARGA';
  IF v_e.status IS DISTINCT FROM 'completed' OR v_e.facturado_gyd IS DISTINCT FROM 6200 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [7d recarga 6,200] got status=% facturado=%', v_e.status, v_e.facturado_gyd;
  ELSE RAISE NOTICE 'PASS [7d recarga 6,200]'; END IF;
  -- 7e. Where facturado already was the deposit, the NEW figure equals the OLD formula (nothing moved): CUP = amount / rate,
  --     recarga = units x price, saldo = packages x price (sale_gyd holds the unit price; the saldo amount is in SM).
  SELECT string_agg(service || ' ' || operation_id, '; ') INTO v_bad
    FROM remittance_calculator_entries
   WHERE account_id = v_account_id AND source = 'completed_operation' AND status = 'completed'
     AND ((service = 'CUP'  AND facturado_gyd IS DISTINCT FROM amount / cup_global_rate)
       OR (service IN ('RECARGA', 'SALDO_MOVIL') AND facturado_gyd IS DISTINCT FROM CASE service WHEN 'RECARGA' THEN amount ELSE floor(basis_gyd / sale_gyd) END * sale_gyd));
  IF v_bad IS NOT NULL THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [7e] fixed-price lines whose facturado moved: %', v_bad;
  ELSE RAISE NOTICE 'PASS [7e CUP / recarga / saldo facturado equals the old formula]'; END IF;
  -- 8. A mixed reparto: the parts add up EXACTLY to the deposit (CUP share 20,000 + Zelle share 55,000 = 75,000).
  v_fail := v_fail + pg_temp.lbd_chk('8a mixed CUP part', v_mixed, 'CUP', 30000, 20000, 18000, 2000);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_mixed AND service = 'ZELLE';
  IF v_e.facturado_gyd IS DISTINCT FROM 55000 OR v_e.amount IS DISTINCT FROM 211 OR v_e.invertido_gyd IS DISTINCT FROM 50640 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [8b mixed Zelle part] expected 211 USD / 55000 / 50640; got % / % / %', v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd;
  ELSE RAISE NOTICE 'PASS [8b mixed Zelle part]'; END IF;
  -- 8c. A CUP share with decimals (10,000 CUP / 1.5 = 6,666.67) still adds up to the cent.
  SELECT sum(facturado_gyd) INTO v_e.facturado_gyd FROM remittance_calculator_entries WHERE operation_id = v_mixed2 AND status = 'completed';
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE operation_id = v_mixed2 AND status = 'completed';
  IF v_n <> 2 OR v_e.facturado_gyd IS DISTINCT FROM 75000 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [8c mixed with decimals] parts % sum %', v_n, v_e.facturado_gyd;
  ELSE RAISE NOTICE 'PASS [8c mixed with decimals adds up to 75,000]'; END IF;
  -- 9. A line fed before the rule is not rewritten when its operation completes afterwards.
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_old AND service = 'ZELLE';
  IF v_e.facturado_gyd IS DISTINCT FROM 47060 OR v_e.retorno_gyd IS DISTINCT FROM 3620 OR v_e.status IS DISTINCT FROM 'completed' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [9 old line] must stay 47060 / 3620, got % / % %', v_e.facturado_gyd, v_e.retorno_gyd, v_e.status;
  ELSE RAISE NOTICE 'PASS [9 a completed line fed before is not rewritten]'; END IF;
  -- 10. Re-feeding is idempotent: same rows, same figures.
  SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id) INTO v_before
    FROM (SELECT id, operation_id, service, status, amount, basis_gyd, facturado_gyd, invertido_gyd, retorno_gyd FROM remittance_calculator_entries
           WHERE account_id = v_account_id) x;
  PERFORM calculator_feed_operation(o) FROM unnest(ARRAY[v_carlos, v_exact, v_cup, v_tier_left, v_cash_left, v_mixed, v_mixed2, v_old, v_visa, v_combo, v_saldo, v_recarga]) o;
  SELECT jsonb_agg(to_jsonb(x) ORDER BY x.id) INTO v_after
    FROM (SELECT id, operation_id, service, status, amount, basis_gyd, facturado_gyd, invertido_gyd, retorno_gyd FROM remittance_calculator_entries
           WHERE account_id = v_account_id) x;
  IF v_before IS DISTINCT FROM v_after THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [10 idempotent] the ledger changed after re-feeding';
  ELSE RAISE NOTICE 'PASS [10 re-feeding changes nothing]'; END IF;
  -- 11. A manual entry is untouched.
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_manual;
  IF v_e.facturado_gyd IS DISTINCT FROM 47060 OR v_e.retorno_gyd IS DISTINCT FROM 3620 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [11 manual] must stay 47060 / 3620, got % / %', v_e.facturado_gyd, v_e.retorno_gyd;
  ELSE RAISE NOTICE 'PASS [11 a manual entry is untouched]'; END IF;

  -- 12. EDGES (the rule is general; these document what it yields).
  --   a destination amount fixed by a human (200 USD) does not reach the ledger: the line still delivers floor(65,000 / 260) = 250 and bills 65,000.
  v_fail := v_fail + pg_temp.lbd_chk('12a human-fixed destination 200 USD on 65,000', v_lock, 'ZELLE', 250, 65000, 60000, 5000);
  --   quoted_source_amount (65,000) differs from the receipts (60,000): the ledger follows quoted_source_amount, as before.
  v_fail := v_fail + pg_temp.lbd_chk('12b quoted 65,000 vs receipts 60,000', v_rcpt, 'ZELLE', 250, 65000, 60000, 5000);

  -- 13. Pending (a rate is missing) keeps its behaviour: no figures at all.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_account_id, jsonb_build_object('usdt_sell_gyd', NULL));
  PERFORM set_config('request.jwt.claims', '', true);
  v_pend := pg_temp.lbd_op(v_account_id, v_conv, 47100, 'clasica');
  PERFORM pg_temp.lbd_done(v_pend, v_agent);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_pend AND service = 'CLASICA';
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR v_e.facturado_gyd IS NOT NULL OR v_e.invertido_gyd IS NOT NULL OR v_e.retorno_gyd IS NOT NULL THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [13 pending] got status=% fact=%', v_e.status, v_e.facturado_gyd;
  ELSE RAISE NOTICE 'PASS [13 a line with a missing rate stays pending, no figures]'; END IF;

  -- 13b. Resolving that pending line by hand (the admin enters the missing sale rate) applies the same rule: 47,100 -> 181 USD, billed 47,100.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM crm_resolve_pending_entry(v_e.id, jsonb_build_object('usdt_sell_gyd', 260), 'fixture: rate entered');
  PERFORM set_config('request.jwt.claims', '', true);
  v_fail := v_fail + pg_temp.lbd_chk('13b resolved pending line bills the deposit', v_pend, 'CLASICA', 181, 47100, 43440, 3660);

  -- 14. THE INVARIANT: for every operation-fed operation of the fixture whose lines are all completed, sum(facturado) = the operation's GYD.
  --     (v_old is the deliberate pre-rule line: 47,060 against 47,100.)
  SELECT string_agg(op || ' deposit ' || dep || ' billed ' || fact, '; ') INTO v_bad
    FROM (SELECT e.operation_id AS op, o.quoted_source_amount AS dep, sum(e.facturado_gyd) AS fact
            FROM remittance_calculator_entries e JOIN remittance_operations o ON o.id = e.operation_id
           WHERE e.account_id = v_account_id AND e.source = 'completed_operation' AND e.operation_id <> v_old
           GROUP BY e.operation_id, o.quoted_source_amount
          HAVING bool_and(e.status = 'completed') AND sum(e.facturado_gyd) <> o.quoted_source_amount) q;
  IF v_bad IS NOT NULL THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [14 invariant] operations billing a different amount than they received: %', v_bad;
  ELSE RAISE NOTICE 'PASS [14 sum(facturado) = the operation''s GYD for every fed operation]'; END IF;
  SELECT count(*) INTO v_n FROM (SELECT 1 FROM remittance_calculator_entries e
         WHERE e.account_id = v_account_id AND e.source = 'completed_operation' AND e.status = 'completed' AND e.operation_id <> v_old
           AND e.retorno_gyd IS DISTINCT FROM e.facturado_gyd - e.invertido_gyd) z;
  IF v_n <> 0 THEN v_fail := v_fail + 1; RAISE WARNING 'FAIL [14b] % lines where retorno <> facturado - invertido', v_n; END IF;

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'ledger-bills-the-deposit: % expectation(s) FAILED - see the WARNINGs above', v_fail;
  END IF;
  RAISE NOTICE 'ledger-bills-the-deposit: all expectations passed';
END $$;

SELECT 'ledger-bills-the-deposit assertions: ALL PASSED' AS result;
