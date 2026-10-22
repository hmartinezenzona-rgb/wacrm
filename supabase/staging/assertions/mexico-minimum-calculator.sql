-- =====================================================================
-- Assertion for migration 272 (Mexico: 13,000 GYD minimum + calculator service mapping).
-- Self-reverting: ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Fixtures use service_type 'mexico' (allowed since 223) and nothing from 271.
--   1 cerebro_minimo_gyd(mexico op) = 13,000 (not the CUP 5,000), rail-less and with a delivery_method
--   2 a 6,000 GYD Mexico op is under the minimum, a 13,000 one is not
--   3 config minimo_gyd_mexico overrides the default (tested inside the transaction)
--   4 calculator_service_for_operation('mexico') and calculator_resolve_operation_service(mexico op) = CLASICA
--   5 calculator_operation_parts prices the Mexico op as one USD part, rates asked = usdt buy/sell (single rate)
--   6 completed Mexico op fed to the ledger: one USD line at the single sell rate (only when staging has rates)
--   7 other services unchanged (CUP 5,000, zelle 13,000, recarga, visa 5,000, combo 25,000, existing mappings)
-- =====================================================================
CREATE FUNCTION pg_temp.m_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990272' || lpad(p_n::text, 4, '0'), 'PRUEBA mexico ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.m_op(p_c record, p_svc text, p_rail text, p_amt numeric, p_status text DEFAULT 'deposit_verification') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, p_status, p_svc, p_rail, 'GYD', p_amt, clock_timestamp()) RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

DO $$
DECLARE
  c record; v_mx3 uuid; v_mx uuid; v_mx2 uuid; v_cup uuid; v_zl uuid; v_rc uuid; v_vs uuid; v_cb uuid;
  v_fail int := 0; v_rates calculator_rate_versions; v_part record; v_n int; v_e record; v_exp numeric;
BEGIN
  SELECT * INTO c FROM pg_temp.m_conv(1);
  v_mx  := pg_temp.m_op(c, 'mexico', NULL, 13000);
  v_mx2 := pg_temp.m_op(c, 'mexico', 'cuban_card', 6000);
  v_cup := pg_temp.m_op(c, 'remesa', 'cuban_card', 5000);
  v_zl  := pg_temp.m_op(c, 'remesa', 'zelle', 13000);
  v_rc  := pg_temp.m_op(c, 'recarga', NULL, 5200);
  v_vs  := pg_temp.m_op(c, 'visa', NULL, 5000);
  v_cb  := pg_temp.m_op(c, 'combo', NULL, 25000);

  -- 1
  IF cerebro_minimo_gyd(v_mx) IS DISTINCT FROM 13000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 1a rail-less mexico minimum = %', cerebro_minimo_gyd(v_mx); END IF;
  IF cerebro_minimo_gyd(v_mx2) IS DISTINCT FROM 13000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 1b mexico with a stale delivery_method minimum = %', cerebro_minimo_gyd(v_mx2); END IF;
  -- 2
  IF NOT (6000 < cerebro_minimo_gyd(v_mx2)) THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 2a 6,000 should be under the minimum'; END IF;
  IF NOT (13000 >= cerebro_minimo_gyd(v_mx)) THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 2b 13,000 should meet the minimum'; END IF;
  -- 3
  INSERT INTO cerebro_config (clave, valor, descripcion) VALUES ('minimo_gyd_mexico', '15000', 'test272') ON CONFLICT (clave) DO UPDATE SET valor = EXCLUDED.valor;
  IF cerebro_minimo_gyd(v_mx) IS DISTINCT FROM 15000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 3 config override ignored: %', cerebro_minimo_gyd(v_mx); END IF;
  -- 4
  IF calculator_service_for_operation('mexico') IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 4a service_for_operation(mexico) = %', calculator_service_for_operation('mexico'); END IF;
  IF calculator_resolve_operation_service(v_mx, NULL) IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 4b resolve(mexico op) = %', calculator_resolve_operation_service(v_mx, NULL); END IF;
  IF calculator_resolve_operation_service(v_mx2, 'cuban_card') IS DISTINCT FROM 'CLASICA' THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 4c resolve(mexico op with stale rail) = %', calculator_resolve_operation_service(v_mx2, 'cuban_card'); END IF;
  -- 5
  v_rates := calculator_rates_vigentes(c.acc);
  SELECT count(*) INTO v_n FROM calculator_operation_parts((SELECT o FROM remittance_operations o WHERE o.id = v_mx), v_rates);
  SELECT * INTO v_part FROM calculator_operation_parts((SELECT o FROM remittance_operations o WHERE o.id = v_mx), v_rates);
  IF v_n <> 1 OR v_part.service IS DISTINCT FROM 'CLASICA' OR v_part.basis IS DISTINCT FROM 13000 THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 5a parts: % rows, service %, basis %', v_n, v_part.service, v_part.basis; END IF;
  IF calculator_missing_rates('CLASICA', v_rates) @> ARRAY['cupGlobalRate'] OR calculator_missing_rates('CLASICA', v_rates) @> ARRAY['usdtSellCup'] THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 5b mexico must not ask CUP rates'; END IF;
  -- 6
  IF v_rates.usdt_sell_gyd IS NOT NULL AND v_rates.usdt_buy_gyd IS NOT NULL THEN
    v_mx3 := pg_temp.m_op(c, 'mexico', NULL, 13000);
    PERFORM set_config('wacrm.origin', 'admin', true);  -- a completion by automation is suppressed (099)
    UPDATE remittance_operations SET status = 'completed', completed_at = clock_timestamp() WHERE id = v_mx3;
    PERFORM set_config('wacrm.origin', '', true);
    PERFORM calculator_feed_operation(v_mx3);
    SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_mx3 AND source = 'completed_operation';
    v_exp := 13000 / v_rates.usdt_sell_gyd;
    IF NOT FOUND OR v_e.service <> 'CLASICA' OR v_e.amount_currency <> 'USD' OR v_e.usdt_sell_gyd IS DISTINCT FROM v_rates.usdt_sell_gyd
       OR abs(v_e.amount - v_exp) > 0.01 OR v_e.status <> 'completed' THEN
      v_fail := v_fail + 1; RAISE NOTICE 'FAIL 6 ledger line: found %, service %, currency %, amount % (expected ~%), sell %, status %',
        FOUND, v_e.service, v_e.amount_currency, v_e.amount, v_exp, v_e.usdt_sell_gyd, v_e.status;
    END IF;
  ELSE
    RAISE NOTICE 'SKIP 6: staging has no USDT buy/sell rates';
  END IF;
  -- 7
  DELETE FROM cerebro_config WHERE clave = 'minimo_gyd_mexico';
  IF cerebro_minimo_gyd(v_cup) IS DISTINCT FROM 5000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7a cup minimum = %', cerebro_minimo_gyd(v_cup); END IF;
  IF cerebro_minimo_gyd(v_zl)  IS DISTINCT FROM 13000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7b zelle minimum = %', cerebro_minimo_gyd(v_zl); END IF;
  IF cerebro_minimo_gyd(v_vs)  IS DISTINCT FROM 5000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7c visa minimum = %', cerebro_minimo_gyd(v_vs); END IF;
  IF cerebro_minimo_gyd(v_cb)  IS DISTINCT FROM 25000 THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7d combo minimum = %', cerebro_minimo_gyd(v_cb); END IF;
  IF cerebro_minimo_gyd(v_rc) IS NULL THEN v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7e recarga minimum null'; END IF;
  IF calculator_service_for_operation('cuban_card') <> 'CUP' OR calculator_service_for_operation('zelle') <> 'ZELLE'
     OR calculator_service_for_operation('visa') <> 'VISA' OR calculator_service_for_operation('saldo') <> 'SALDO_MOVIL'
     OR calculator_service_for_operation('combo') <> 'COMBO' OR calculator_service_for_operation('recarga') <> 'RECARGA'
     OR calculator_service_for_operation('nonsense') IS NOT NULL THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7f existing mappings changed'; END IF;
  IF calculator_resolve_operation_service(v_cup, 'cuban_card') <> 'CUP' OR calculator_resolve_operation_service(v_rc, NULL) <> 'RECARGA'
     OR calculator_resolve_operation_service(v_vs, NULL) <> 'VISA' OR calculator_resolve_operation_service(v_cb, NULL) <> 'COMBO' THEN
    v_fail := v_fail + 1; RAISE NOTICE 'FAIL 7g existing resolve changed'; END IF;

  IF v_fail > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
