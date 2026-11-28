-- =====================================================================
-- Assertion for migration 334 (panel assign/release actions).
-- Self-reverting: one DO block ending in RAISE EXCEPTION 'ALL PASS'.
-- Cases:
--   1. the panel exposes the open operation and its committed amount.
--   2. an agent assigns GYD to the operation; the case and the operation update; idempotent.
--   3. over-assignment and a non-member are refused.
--   4. an agent releases the allocation; the case balance returns.
--   5. a non-member cannot release; a completed operation's allocation cannot be released.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_case uuid; v_alloc uuid;
  v_panel jsonb; v_case_json jsonb; v_state text; v_ok boolean; v_err text;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599334001', 'test334') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 334', 'a334@example.com', 100, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('33400000000001', 50000, 'GYD', 'PRUEBA 334', now(), now(), v_op);
  PERFORM funding_reconciliar(v_conv, 'test334');

  SELECT case_id INTO v_case FROM remittance_operations WHERE id = v_op;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case: no funding case after reconciliation'; END IF;

  -- 1. The panel shows the operation and its committed amount.
  v_panel := funding_caso_panel(v_conv);
  v_case_json := v_panel -> 'case';
  IF NOT (v_case_json ? 'operations') THEN
    RAISE EXCEPTION 'case 1: the panel does not expose operations';
  END IF;
  IF jsonb_array_length(v_case_json -> 'operations') <> 1 THEN
    RAISE EXCEPTION 'case 1: expected one open operation, got %', jsonb_array_length(v_case_json -> 'operations');
  END IF;
  IF v_case_json -> 'operations' -> 0 ->> 'id' <> v_op::text
     OR v_case_json -> 'operations' -> 0 ->> 'service' <> 'zelle'
     OR (v_case_json -> 'operations' -> 0 ->> 'quoted_source_amount')::numeric <> 26000
     OR (v_case_json -> 'operations' -> 0 ->> 'allocated')::numeric <> 26000 THEN
    RAISE EXCEPTION 'case 1: wrong operation row: %', v_case_json -> 'operations' -> 0;
  END IF;
  IF (v_case_json ->> 'asignado')::numeric <> 26000 OR (v_case_json ->> 'disponible')::numeric <> 24000 THEN
    RAISE EXCEPTION 'case 1: amounts % / % (expected 26000 / 24000)',
      v_case_json ->> 'asignado', v_case_json ->> 'disponible';
  END IF;

  -- 2. Assign 5,000 to the same operation; idempotent.
  v_panel := funding_caso_asignar_panel(v_case, v_op, 5000, 'panel-a1');
  IF (v_panel -> 'case' ->> 'asignado')::numeric <> 31000
     OR (v_panel -> 'case' ->> 'disponible')::numeric <> 19000 THEN
    RAISE EXCEPTION 'case 2: after assign % / % (expected 31000 / 19000)',
      v_panel -> 'case' ->> 'asignado', v_panel -> 'case' ->> 'disponible';
  END IF;
  IF (v_panel -> 'case' -> 'operations' -> 0 ->> 'allocated')::numeric <> 31000 THEN
    RAISE EXCEPTION 'case 2: the operation allocated amount did not update';
  END IF;

  v_panel := funding_caso_asignar_panel(v_case, v_op, 5000, 'panel-a1');
  IF (v_panel -> 'case' ->> 'asignado')::numeric <> 31000 THEN
    RAISE EXCEPTION 'case 2: the idempotent assign doubled the amount';
  END IF;

  -- 3. Over-assignment refused; a non-member cannot assign.
  v_ok := false;
  BEGIN
    PERFORM funding_caso_asignar_panel(v_case, v_op, 999999, 'panel-over');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM; GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  IF NOT v_ok OR v_state <> '22023' THEN
    RAISE EXCEPTION 'case 3: over-assignment was not refused (ok %, state %, error %)', v_ok, v_state, v_err;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN
    PERFORM funding_caso_asignar_panel(v_case, v_op, 1000, 'panel-nonmember');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_state := SQLSTATE;
  END;
  IF NOT v_ok OR v_state <> '42501' THEN
    RAISE EXCEPTION 'case 3: a non-member assigned (ok %, state %)', v_ok, v_state;
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 4. Release the 5,000 allocation.
  SELECT a.id INTO v_alloc
    FROM funding_allocations a
   WHERE a.operation_id = v_op AND a.amount_gyd = 5000 AND a.status = 'committed'
   ORDER BY a.created_at DESC LIMIT 1;
  IF v_alloc IS NULL THEN RAISE EXCEPTION 'case 4: the 5,000 allocation was not found'; END IF;

  v_panel := funding_caso_liberar_panel(v_alloc, 'panel-r1', 'test release');
  IF (v_panel -> 'case' ->> 'asignado')::numeric <> 26000
     OR (v_panel -> 'case' ->> 'disponible')::numeric <> 24000 THEN
    RAISE EXCEPTION 'case 4: after release % / % (expected 26000 / 24000)',
      v_panel -> 'case' ->> 'asignado', v_panel -> 'case' ->> 'disponible';
  END IF;
  IF (SELECT status FROM funding_allocations WHERE id = v_alloc) <> 'released' THEN
    RAISE EXCEPTION 'case 4: the allocation is not released';
  END IF;

  -- 5. A non-member cannot release; a completed operation's allocation cannot be released.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN
    PERFORM funding_caso_liberar_panel(v_alloc, 'panel-r-nonmember', 'x');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_state := SQLSTATE;
  END;
  IF NOT v_ok OR v_state <> '42501' THEN
    RAISE EXCEPTION 'case 5: a non-member released (ok %, state %)', v_ok, v_state;
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  SELECT a.id INTO v_alloc
    FROM funding_allocations a
   WHERE a.operation_id = v_op AND a.amount_gyd = 26000 AND a.status = 'committed'
   ORDER BY a.created_at LIMIT 1;
  IF v_alloc IS NULL THEN RAISE EXCEPTION 'case 5: the original allocation was not found'; END IF;
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;

  v_ok := false;
  BEGIN
    PERFORM funding_caso_liberar_panel(v_alloc, 'panel-r-completed', 'x');
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: a completed operation''s allocation was released'; END IF;
  IF v_err NOT LIKE '%completed operation%' THEN RAISE EXCEPTION 'case 5: unexpected error: %', v_err; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
