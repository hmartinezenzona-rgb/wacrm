-- =====================================================================
-- Assertion for migration 188 (the cash USD rate lives once, in the calculator rates).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/remesa-closing-and-cash.md (A1). Owner, 2026-10-02: the cash rate changes, and changing it in ONE
-- place must reach every place that uses it. Rates are set in the Calculator (calculator_rate_versions; `tasas` is
-- a view over it), so the cash rate is one more column there; the remesa's received amount, the cash minimum
-- (100 USD x rate) and the service text the bot reads all come from it.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_efectivo(p_tag text, p_gyd numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900188' || p_tag, 'test188' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'deposit_verification', 'remesa', 'GYD', p_gyd, 'efectivo_usd') RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE
  v_acc uuid; v_op uuid; v_op2 uuid; v_r record; v_txt text; v_ok boolean;
BEGIN
  SELECT account_id INTO v_acc FROM calculator_rate_versions ORDER BY effective_at DESC LIMIT 1;

  -- 1. The cash rate is a calculator rate read by crm_tasa_vigente('efectivo') (seeded at 290), and the view `tasas`
  --    keeps exactly gyd and usd (its readers print every row as a CUP rate).
  IF crm_tasa_vigente('efectivo') IS DISTINCT FROM 290 THEN
    RAISE EXCEPTION 'case 1: tasa efectivo must read 290, got %', crm_tasa_vigente('efectivo'); END IF;
  IF (SELECT efectivo_usd_gyd FROM calculator_rates_vigentes(v_acc)) IS DISTINCT FROM 290 THEN
    RAISE EXCEPTION 'case 1: the current calculator version must carry efectivo_usd_gyd 290'; END IF;
  IF (SELECT string_agg(DISTINCT moneda, ',' ORDER BY moneda) FROM tasas) IS DISTINCT FROM 'gyd,usd' THEN
    RAISE EXCEPTION 'case 1: the view tasas must keep exactly gyd and usd, got %', (SELECT string_agg(DISTINCT moneda, ',') FROM tasas); END IF;

  -- 2. The minimum is 100 USD x the rate.
  IF cerebro_minimo_efectivo_gyd() IS DISTINCT FROM 29000 THEN
    RAISE EXCEPTION 'case 2: cash minimum must be 29,000, got %', cerebro_minimo_efectivo_gyd(); END IF;

  -- 3. A cash beneficiary: 29,000 GYD -> 100 USD (floor), calculated.
  v_op := pg_temp.op_efectivo('01', 29000);
  IF cerebro_minimo_gyd(v_op) IS DISTINCT FROM 29000 THEN
    RAISE EXCEPTION 'case 3: cerebro_minimo_gyd of a cash remesa must be 29,000, got %', cerebro_minimo_gyd(v_op); END IF;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
  VALUES (v_op, 'efectivo_usd', '53821203', 1, 1, 'manual', 'vigente');
  SELECT quoted_destination_amount AS a, destination_currency AS c, quoted_destination_origin AS o INTO v_r
    FROM remittance_operations WHERE id = v_op;
  IF v_r.a IS DISTINCT FROM 100 OR v_r.c IS DISTINCT FROM 'USD' OR v_r.o IS DISTINCT FROM 'calculated' THEN
    RAISE EXCEPTION 'case 3: 29,000 GYD cash must receive 100 USD calculated, got % % %', v_r.a, v_r.c, v_r.o; END IF;

  -- 4. Changing the rate ONCE (a new calculator version) reaches every place.
  PERFORM set_config('request.jwt.claims', json_build_object('sub',
    (SELECT p.user_id FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner','admin') LIMIT 1),
    'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_acc, '{"efectivo_usd_gyd": 300}'::jsonb, NULL);
  IF crm_tasa_vigente('efectivo') IS DISTINCT FROM 300 OR cerebro_minimo_efectivo_gyd() IS DISTINCT FROM 30000 THEN
    RAISE EXCEPTION 'case 4: after setting 300 the rate/minimum must be 300/30,000, got %/%',
      crm_tasa_vigente('efectivo'), cerebro_minimo_efectivo_gyd(); END IF;
  v_op2 := pg_temp.op_efectivo('02', 29000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
  VALUES (v_op2, 'efectivo_usd', '53821203', 1, 1, 'manual', 'vigente');
  IF (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op2) IS DISTINCT FROM 96 THEN
    RAISE EXCEPTION 'case 4: 29,000 at 300 must floor to 96 USD, got %', (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op2); END IF;
  SELECT hechos INTO v_txt FROM cerebro_servicio_get('efectivo_usd');
  IF v_txt NOT LIKE '%300 GYD por cada 1 USD%' OR v_txt NOT LIKE '%30,000 GYD%' OR v_txt LIKE '%{%' THEN
    RAISE EXCEPTION 'case 4: the service text must read the live rate and minimum, got: %', left(v_txt, 300); END IF;
  -- the other rates are untouched by a cash-only change
  IF crm_tasa_vigente('gyd') IS DISTINCT FROM (SELECT cup_global_rate FROM calculator_rates_vigentes(v_acc)) THEN
    RAISE EXCEPTION 'case 4: the CUP rate changed'; END IF;

  -- 5. A cash recipient is complete with phone + address + ID photo; no card needed. A card still needs its phone.
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 5: phone alone is not a complete cash recipient'; END IF;
  UPDATE remittance_beneficiaries SET address = 'Calle 1, Habana', id_photo_wamid = 'wamid.test188'
   WHERE operation_id = v_op AND status = 'vigente';
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 5: phone + address + ID photo must be complete'; END IF;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, position, block_index, source, status)
  VALUES (v_op2, 'cuban_card', '9238123432101987', 2, 2, 'manual', 'vigente');
  UPDATE remittance_beneficiaries SET status = 'reemplazado' WHERE operation_id = v_op2 AND beneficiary_type = 'efectivo_usd';
  IF crm_beneficiarios_completos(v_op2) THEN RAISE EXCEPTION 'case 5: a card without phone must stay incomplete'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
