-- =====================================================================
-- Assertion for migration 331 (deterministic reconciliation, phase 3a).
-- Self-reverting: temp helpers plus one DO block ending in RAISE 'ALL PASS'.
-- Cases:
--   1. a verified deposit + a complete operation -> case, link, allocation; idempotent.
--   2. a second part waits for its deposit; the second deposit funds it.
--   3. a mixed group is allocated as a whole.
--   4. an insufficient deposit allocates nothing and blocks delivery.
--   5. a 9234 card on a Clasica operation -> incident, no allocation, delivery blocked; resolver.
--   6. an unknown prefix does not conflict.
--   7. money stays in the case until the recipient data arrives (beneficiary trigger).
--   8. a voided deposit after allocation -> incident and blocked delivery.
--   9. conservation: depositado = asignado + disponible in every case.
-- =====================================================================

CREATE FUNCTION pg_temp.fc_conv(p_tag text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile for the fixture'; END IF;
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599331' || p_tag, 'test331' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  RETURN v_conv;
END $$;

CREATE FUNCTION pg_temp.fc_op(p_conv uuid, p_rail text, p_source numeric, p_dest numeric, p_cur text) RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE v_op uuid;
BEGIN
  v_op := cerebro_crear_operacion(p_conv);
  UPDATE remittance_operations
     SET service_type = CASE WHEN p_rail IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN p_rail ELSE 'remesa' END,
         delivery_method = CASE WHEN p_rail IN ('recarga', 'combo', 'visa', 'saldo', 'mexico') THEN NULL ELSE p_rail END,
         status = 'ready_to_transfer',
         quoted_source_amount = p_source,
         quoted_destination_amount = p_dest,
         destination_currency = p_cur
   WHERE id = v_op;
  RETURN v_op;
END $$;

CREATE FUNCTION pg_temp.fc_ben(p_op uuid, p_type text, p_card text, p_phone text, p_zelle text, p_amount numeric, p_cur text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, zelle_account, amount, currency, position, status, source)
  VALUES (p_op, p_type, 'PRUEBA 331', p_card, p_phone, p_zelle, p_amount, p_cur, 1, 'vigente', 'manual');
END $$;

CREATE FUNCTION pg_temp.fc_dep(p_op uuid, p_trans text, p_monto numeric) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES (p_trans, p_monto, 'GYD', 'PRUEBA 331', now(), now(), p_op);
END $$;

DO $$
DECLARE
  v_conv uuid; v_op uuid; v_op2 uuid; v_a uuid; v_b uuid;
  v_case uuid; v_status text; v_dep numeric; v_asig numeric; v_disp numeric;
  v_ok boolean; v_err text; v_n int; v_cov boolean;
BEGIN
  -- ------------------------------------------------------------------
  -- Case 1: deposit + complete operation -> case, link, allocation.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('1');
  v_op := pg_temp.fc_op(v_conv, 'zelle', 26000, 100, 'USD');
  PERFORM pg_temp.fc_ben(v_op, 'zelle', NULL, NULL, 'a331@example.com', 100, 'USD');
  PERFORM pg_temp.fc_dep(v_op, '33100000000001', 26000);
  PERFORM funding_reconciliar(v_conv, 'test331');

  SELECT case_id INTO v_case FROM remittance_operations WHERE id = v_op;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case 1: the operation was not linked to a case'; END IF;
  SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case) s;
  IF v_dep <> 26000 OR v_asig <> 26000 OR v_disp <> 0 THEN
    RAISE EXCEPTION 'case 1: saldo says deposited %, assigned %, available % (expected 26000/26000/0)', v_dep, v_asig, v_disp;
  END IF;
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: expected one committed allocation, found %', v_n; END IF;
  SELECT s.cubierto INTO v_cov FROM cerebro_fondos_operacion(v_op) s;
  IF NOT v_cov THEN RAISE EXCEPTION 'case 1: the operation is not covered'; END IF;
  IF (SELECT status FROM funding_case WHERE id = v_case) <> 'allocating' THEN
    RAISE EXCEPTION 'case 1: the case status is % instead of allocating', (SELECT status FROM funding_case WHERE id = v_case);
  END IF;

  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: a second run duplicated the allocation (% rows)', v_n; END IF;

  -- ------------------------------------------------------------------
  -- Case 2: a second part waits for its deposit; the deposit funds it.
  -- ------------------------------------------------------------------
  v_op2 := pg_temp.fc_op(v_conv, 'zelle', 13000, 50, 'USD');
  PERFORM pg_temp.fc_ben(v_op2, 'zelle', NULL, NULL, 'b331@example.com', 50, 'USD');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op2 AND status = 'committed';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 2: allocated the second part with no money for it'; END IF;

  PERFORM pg_temp.fc_dep(v_op2, '33100000000002', 13000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op2 AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 2: the second deposit did not fund the second part'; END IF;
  SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case) s;
  IF v_dep <> 39000 OR v_asig <> 39000 OR v_disp <> 0 THEN
    RAISE EXCEPTION 'case 2: saldo says deposited %, assigned %, available % (expected 39000/39000/0)', v_dep, v_asig, v_disp;
  END IF;

  -- ------------------------------------------------------------------
  -- Case 3: a mixed group is allocated as a whole.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('3');
  v_a := pg_temp.fc_op(v_conv, 'zelle', 26000, 100, 'USD');
  v_b := pg_temp.fc_op(v_conv, 'cuban_card', 13000, 50000, 'CUP');
  UPDATE remittance_operations SET mixed_group_id = v_a WHERE id IN (v_a, v_b);
  PERFORM pg_temp.fc_ben(v_a, 'zelle', NULL, NULL, 'c331@example.com', 100, 'USD');
  PERFORM pg_temp.fc_ben(v_b, 'cuban_card', '9234123456789012', '5355512345', NULL, 50000, 'CUP');
  PERFORM pg_temp.fc_dep(v_a, '33100000000003', 39000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT sum(amount_gyd) INTO v_asig FROM funding_allocations
   WHERE operation_id IN (v_a, v_b) AND status = 'committed';
  IF v_asig <> 39000 THEN RAISE EXCEPTION 'case 3: the group allocated %, expected 39000', v_asig; END IF;
  SELECT s.cubierto INTO v_cov FROM cerebro_fondos_operacion(v_b) s;
  IF NOT v_cov THEN RAISE EXCEPTION 'case 3: the group member is not covered'; END IF;

  -- ------------------------------------------------------------------
  -- Case 4: an insufficient deposit allocates nothing and blocks delivery.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('4');
  v_op := pg_temp.fc_op(v_conv, 'zelle', 26000, 100, 'USD');
  PERFORM pg_temp.fc_ben(v_op, 'zelle', NULL, NULL, 'd331@example.com', 100, 'USD');
  PERFORM pg_temp.fc_dep(v_op, '33100000000004', 10000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: allocated with only 10000 of 26000'; END IF;
  SELECT id INTO v_case FROM funding_case
   WHERE conversation_id = v_conv AND status <> 'closed'
   ORDER BY opened_at DESC LIMIT 1;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case 4: no case was opened for the deposit'; END IF;
  SELECT disponible INTO v_disp FROM funding_case_saldo(v_case) s;
  IF v_disp <> 10000 THEN RAISE EXCEPTION 'case 4: available %, expected 10000', v_disp; END IF;

  v_ok := false;
  BEGIN PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4: delivered an underfunded operation'; END IF;
  IF v_err NOT LIKE '%verified funding%' THEN RAISE EXCEPTION 'case 4: unexpected error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 5: a 9234 card on a Clasica operation -> incident; operator resolves.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('5');
  v_op := pg_temp.fc_op(v_conv, 'clasica', 26000, 50, 'USD');
  PERFORM pg_temp.fc_ben(v_op, 'cuban_card', '9234123456789012', '5355512346', NULL, 50, 'USD');
  PERFORM pg_temp.fc_dep(v_op, '33100000000005', 26000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT id INTO v_case FROM funding_case
   WHERE conversation_id = v_conv AND status <> 'closed'
   ORDER BY opened_at DESC LIMIT 1;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case 5: no case was opened for the deposit'; END IF;
  IF (SELECT status FROM funding_case WHERE id = v_case) <> 'incident' THEN
    RAISE EXCEPTION 'case 5: the prefix conflict did not set the case incident';
  END IF;
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 5: allocated despite the conflict'; END IF;

  v_ok := false;
  BEGIN PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: delivered an operation with a funding conflict'; END IF;
  IF v_err NOT LIKE '%conflict%' THEN RAISE EXCEPTION 'case 5: unexpected error: %', v_err; END IF;

  UPDATE remittance_beneficiaries SET card_number = '9760123456789012' WHERE operation_id = v_op;
  PERFORM funding_case_resolver(v_case, 'test331');
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: the resolved conflict did not allocate'; END IF;
  IF (SELECT status FROM funding_case WHERE id = v_case) <> 'allocating' THEN
    RAISE EXCEPTION 'case 5: the case did not leave incident after resolving';
  END IF;

  -- ------------------------------------------------------------------
  -- Case 6: an unknown prefix does not conflict.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('6');
  v_op := pg_temp.fc_op(v_conv, 'cuban_card', 26000, 50000, 'CUP');
  PERFORM pg_temp.fc_ben(v_op, 'cuban_card', '9210123456789012', '5355512347', NULL, 50000, 'CUP');
  PERFORM pg_temp.fc_dep(v_op, '33100000000006', 26000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 6: an unknown prefix blocked a valid allocation'; END IF;
  SELECT s.cubierto INTO v_cov FROM cerebro_fondos_operacion(v_op) s;
  IF NOT v_cov THEN RAISE EXCEPTION 'case 6: the operation is not covered'; END IF;

  -- ------------------------------------------------------------------
  -- Case 7: the money waits in the case until the recipient arrives.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('7');
  v_op := pg_temp.fc_op(v_conv, 'zelle', 26000, 100, 'USD');
  PERFORM pg_temp.fc_dep(v_op, '33100000000007', 26000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT id INTO v_case FROM funding_case
   WHERE conversation_id = v_conv AND status <> 'closed'
   ORDER BY opened_at DESC LIMIT 1;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case 7: no case was opened for the deposit'; END IF;
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 7: allocated without recipient data'; END IF;
  SELECT disponible INTO v_disp FROM funding_case_saldo(v_case) s;
  IF v_disp <> 26000 THEN RAISE EXCEPTION 'case 7: available %, expected 26000', v_disp; END IF;

  PERFORM pg_temp.fc_ben(v_op, 'zelle', NULL, NULL, 'g331@example.com', 100, 'USD');
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 7: the beneficiary trigger did not allocate'; END IF;

  -- ------------------------------------------------------------------
  -- Case 8: a voided deposit after allocation -> incident and blocked delivery.
  -- ------------------------------------------------------------------
  v_conv := pg_temp.fc_conv('8');
  v_op := pg_temp.fc_op(v_conv, 'zelle', 26000, 100, 'USD');
  PERFORM pg_temp.fc_ben(v_op, 'zelle', NULL, NULL, 'h331@example.com', 100, 'USD');
  PERFORM pg_temp.fc_dep(v_op, '33100000000008', 26000);
  PERFORM funding_reconciliar(v_conv, 'test331');
  SELECT case_id INTO v_case FROM remittance_operations WHERE id = v_op;

  UPDATE depositos_mmg SET anulado_en = now(), motivo_anulacion = 'PRUEBA 331' WHERE trans_id = '33100000000008';
  PERFORM funding_reconciliar(v_conv, 'test331');
  IF (SELECT status FROM funding_case WHERE id = v_case) <> 'incident' THEN
    RAISE EXCEPTION 'case 8: the void left the case in % instead of incident', (SELECT status FROM funding_case WHERE id = v_case);
  END IF;

  v_ok := false;
  BEGIN PERFORM crm_entregar_operacion(v_op, '{"mode":"skip_proof"}'::jsonb, true, NULL);
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 8: delivered after the deposit was voided'; END IF;
  IF v_err NOT LIKE '%conflict%' THEN RAISE EXCEPTION 'case 8: unexpected error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 9: conservation in every case.
  -- ------------------------------------------------------------------
  FOR v_case IN SELECT id FROM funding_case LOOP
    SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case) s;
    IF v_dep <> v_asig + v_disp THEN
      RAISE EXCEPTION 'case 9: conservation broken in % (% <> % + %)', v_case, v_dep, v_asig, v_disp;
    END IF;
  END LOOP;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
