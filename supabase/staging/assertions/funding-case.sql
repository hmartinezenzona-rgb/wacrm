-- =====================================================================
-- Assertion for migration 330 (funding case + allocation ledger).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Cases:
--   1. open is idempotent and a second active case per conversation is refused.
--   2. a verified GYD deposit links once; unverified, voided, non-GYD and foreign-case deposits are refused.
--   3. allocations commit within the available balance, set the operation's case, and are idempotent.
--   4. over-allocation, another conversation's operation, and a completed operation are refused.
--   5. release returns the balance and is idempotent; a completed operation's allocation cannot be released.
--   6. a case closes only with disponible = 0; a closed case refuses links and allocations.
--   7. the conservation invariant holds after every step.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_ct1 uuid; v_ct2 uuid; v_conv1 uuid; v_conv2 uuid;
  v_op1 uuid; v_op2 uuid; v_op3 uuid; v_op4 uuid;
  v_case1 uuid; v_case1b uuid; v_case2 uuid; v_case3 uuid;
  v_alloc1 uuid; v_alloc1b uuid; v_alloc2 uuid; v_alloc2b uuid; v_alloc3 uuid;
  v_dep numeric; v_asig numeric; v_disp numeric;
  v_ok boolean; v_err text; v_n int;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599330001', 'test330a') RETURNING id INTO v_ct1;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct1) RETURNING id INTO v_conv1;
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599330002', 'test330b') RETURNING id INTO v_ct2;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct2) RETURNING id INTO v_conv2;

  v_op1 := cerebro_crear_operacion(v_conv1);
  v_op2 := cerebro_crear_operacion(v_conv1);
  v_op3 := cerebro_crear_operacion(v_conv2);
  v_op4 := cerebro_crear_operacion(v_conv1);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op4;

  -- Verified GYD deposits (unlinked; the case links them), then the invalid flavours.
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en)
  VALUES ('33000000000001', 100000, 'GYD', 'PRUEBA 330', now(), now()),
         ('33000000000002', 50000, 'GYD', 'PRUEBA 330', now(), now()),
         ('33000000000003', 10000, 'GYD', 'PRUEBA 330', now(), NULL),
         ('33000000000004', 10000, 'GYD', 'PRUEBA 330', now(), now()),
         ('33000000000005', 10000, 'USD', 'PRUEBA 330', now(), now());
  UPDATE depositos_mmg SET anulado_en = now(), motivo_anulacion = 'PRUEBA 330' WHERE trans_id = '33000000000004';

  -- ------------------------------------------------------------------
  -- Case 1: open is idempotent; one active case per conversation.
  -- ------------------------------------------------------------------
  v_case1 := funding_case_abrir(v_conv1, 'test330');
  v_case1b := funding_case_abrir(v_conv1, 'test330');
  IF v_case1 IS NULL OR v_case1b <> v_case1 THEN
    RAISE EXCEPTION 'case 1: opening the case twice returned % and %', v_case1, v_case1b;
  END IF;

  v_ok := false;
  BEGIN
    INSERT INTO funding_case (account_id, conversation_id) VALUES (v_acc, v_conv1);
  EXCEPTION WHEN unique_violation THEN
    v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 1: a second active case for the same conversation was allowed'; END IF;

  -- ------------------------------------------------------------------
  -- Case 2: verified deposit links; the invalid ones are refused.
  -- ------------------------------------------------------------------
  PERFORM funding_deposito_vincular(v_case1, '33000000000001', 'test330');
  PERFORM funding_deposito_vincular(v_case1, '33000000000001', 'test330');
  SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case1) s;
  IF v_dep <> 100000 OR v_asig <> 0 OR v_disp <> 100000 THEN
    RAISE EXCEPTION 'case 2: saldo says deposited %, assigned %, available % (expected 100000/0/100000)', v_dep, v_asig, v_disp;
  END IF;

  v_ok := false;
  BEGIN PERFORM funding_deposito_vincular(v_case1, '33000000000003', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 2: linked an unverified deposit'; END IF;
  IF v_err NOT LIKE '%not verified%' THEN RAISE EXCEPTION 'case 2: unexpected unverified error: %', v_err; END IF;

  v_ok := false;
  BEGIN PERFORM funding_deposito_vincular(v_case1, '33000000000004', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 2: linked a voided deposit'; END IF;
  IF v_err NOT LIKE '%voided%' THEN RAISE EXCEPTION 'case 2: unexpected voided error: %', v_err; END IF;

  v_ok := false;
  BEGIN PERFORM funding_deposito_vincular(v_case1, '33000000000005', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 2: linked a non-GYD deposit'; END IF;
  IF v_err NOT LIKE '%GYD%' THEN RAISE EXCEPTION 'case 2: unexpected currency error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 3: allocation within the balance, case link, idempotency.
  -- ------------------------------------------------------------------
  v_alloc1 := funding_asignar(v_case1, v_op1, 60000, 'data', 'alloc-1', 'test330');
  v_alloc1b := funding_asignar(v_case1, v_op1, 60000, 'data', 'alloc-1', 'test330');
  IF v_alloc1 IS NULL OR v_alloc1b <> v_alloc1 THEN
    RAISE EXCEPTION 'case 3: the idempotent allocation returned % and %', v_alloc1, v_alloc1b;
  END IF;
  IF (SELECT case_id FROM remittance_operations WHERE id = v_op1) <> v_case1 THEN
    RAISE EXCEPTION 'case 3: the operation was not linked to the case';
  END IF;
  SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case1) s;
  IF v_dep <> 100000 OR v_asig <> 60000 OR v_disp <> 40000 THEN
    RAISE EXCEPTION 'case 3: saldo says deposited %, assigned %, available % (expected 100000/60000/40000)', v_dep, v_asig, v_disp;
  END IF;
  SELECT count(*) INTO v_n FROM funding_movements WHERE case_id = v_case1 AND kind = 'commit';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 3: expected one commit movement, found %', v_n; END IF;

  v_ok := false;
  BEGIN PERFORM funding_asignar(v_case1, v_op1, 50000, 'data', 'alloc-1', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 3: an idempotency key was reused with different arguments'; END IF;
  IF v_err NOT LIKE '%different arguments%' THEN RAISE EXCEPTION 'case 3: unexpected key reuse error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 4: over-allocation, another conversation, completed operation.
  -- ------------------------------------------------------------------
  v_ok := false;
  BEGIN PERFORM funding_asignar(v_case1, v_op2, 50000, 'operator', 'alloc-over', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4: over-allocated the case'; END IF;
  IF v_err NOT LIKE '%available%' THEN RAISE EXCEPTION 'case 4: unexpected over-allocation error: %', v_err; END IF;

  v_ok := false;
  BEGIN PERFORM funding_asignar(v_case1, v_op3, 1000, 'operator', 'alloc-other-conv', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4: allocated to an operation of another conversation'; END IF;
  IF v_err NOT LIKE '%different conversations%' THEN RAISE EXCEPTION 'case 4: unexpected conversation error: %', v_err; END IF;

  v_ok := false;
  BEGIN PERFORM funding_asignar(v_case1, v_op4, 1000, 'operator', 'alloc-completed', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4: allocated to a completed operation'; END IF;
  IF v_err NOT LIKE '%closed operation%' THEN RAISE EXCEPTION 'case 4: unexpected completed error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 5: release returns the balance and is idempotent.
  -- ------------------------------------------------------------------
  v_alloc2 := funding_asignar(v_case1, v_op2, 40000, 'operator', 'alloc-2', 'test330');
  SELECT disponible INTO v_disp FROM funding_case_saldo(v_case1) s;
  IF v_disp <> 0 THEN RAISE EXCEPTION 'case 5: expected available 0 after the second allocation, got %', v_disp; END IF;

  PERFORM funding_liberar(v_alloc1, 'release-1', 'test release', 'test330');
  PERFORM funding_liberar(v_alloc1, 'release-1', 'test release', 'test330');
  SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case1) s;
  IF v_dep <> 100000 OR v_asig <> 40000 OR v_disp <> 60000 THEN
    RAISE EXCEPTION 'case 5: saldo says deposited %, assigned %, available % (expected 100000/40000/60000)', v_dep, v_asig, v_disp;
  END IF;
  SELECT count(*) INTO v_n FROM funding_movements WHERE case_id = v_case1 AND kind = 'release';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: expected one release movement, found %', v_n; END IF;

  v_ok := false;
  BEGIN PERFORM funding_case_cerrar(v_case1, 'should fail', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: closed a case with 60000 GYD unassigned'; END IF;
  IF v_err NOT LIKE '%unassigned%' THEN RAISE EXCEPTION 'case 5: unexpected close error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 6: a completed operation's allocation cannot be released; a case closes at 0.
  -- ------------------------------------------------------------------
  v_case2 := funding_case_abrir(v_conv2, 'test330');
  PERFORM funding_deposito_vincular(v_case2, '33000000000002', 'test330');
  v_alloc3 := funding_asignar(v_case2, v_op3, 50000, 'operator', 'alloc-3', 'test330');
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op3;

  v_ok := false;
  BEGIN PERFORM funding_liberar(v_alloc3, 'release-3', 'should fail', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6: released the funding of a completed operation'; END IF;
  IF v_err NOT LIKE '%completed operation%' THEN RAISE EXCEPTION 'case 6: unexpected release error: %', v_err; END IF;

  PERFORM funding_case_cerrar(v_case2, 'all assigned', 'test330');
  IF (SELECT status FROM funding_case WHERE id = v_case2) <> 'closed' THEN
    RAISE EXCEPTION 'case 6: the fully assigned case did not close'; END IF;

  v_ok := false;
  BEGIN PERFORM funding_deposito_vincular(v_case2, '33000000000001', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6: a closed case accepted a deposit'; END IF;
  IF v_err NOT LIKE '%closed%' THEN RAISE EXCEPTION 'case 6: unexpected closed-link error: %', v_err; END IF;

  v_ok := false;
  BEGIN PERFORM funding_asignar(v_case2, v_op3, 1000, 'operator', 'alloc-closed', 'test330');
  EXCEPTION WHEN OTHERS THEN v_ok := true; v_err := SQLERRM; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6: a closed case accepted an allocation'; END IF;
  IF v_err NOT LIKE '%closed%' THEN RAISE EXCEPTION 'case 6: unexpected closed-allocation error: %', v_err; END IF;

  -- ------------------------------------------------------------------
  -- Case 7: finish case 1, then a new active case can open after closing.
  -- ------------------------------------------------------------------
  v_alloc2b := funding_asignar(v_case1, v_op1, 60000, 'operator', 'alloc-4', 'test330');
  SELECT disponible INTO v_disp FROM funding_case_saldo(v_case1) s;
  IF v_disp <> 0 THEN RAISE EXCEPTION 'case 7: expected available 0, got %', v_disp; END IF;
  PERFORM funding_case_cerrar(v_case1, 'all assigned', 'test330');
  IF (SELECT status FROM funding_case WHERE id = v_case1) <> 'closed' THEN
    RAISE EXCEPTION 'case 7: case 1 did not close'; END IF;

  v_case3 := funding_case_abrir(v_conv1, 'test330');
  IF v_case3 = v_case1 THEN RAISE EXCEPTION 'case 7: opening after closing returned the closed case'; END IF;

  SELECT depositado, asignado, disponible INTO v_dep, v_asig, v_disp FROM funding_case_saldo(v_case1) s;
  IF v_dep <> v_asig + v_disp THEN
    RAISE EXCEPTION 'case 7: conservation broken (% <> % + %)', v_dep, v_asig, v_disp;
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
