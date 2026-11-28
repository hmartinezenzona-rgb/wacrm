-- =====================================================================
-- Assertion for migration 332 (funding case in the panel).
-- Self-reverting: one DO block ending in RAISE EXCEPTION 'ALL PASS'.
-- Cases:
--   1. the panel returns the active case with amounts, deposits and allocations.
--   2. a non-member cannot read it (42501).
--   3. an incident case shows the conflict note; a non-member cannot resolve it.
--   4. the owner's resolver clears the incident and re-runs the engine; the conflict returns if unfixed.
--   5. after fixing the card, the resolver allocates and the panel leaves incident.
--   6. a closed case is still returned (the latest case when there is no active one).
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_case uuid;
  v_panel jsonb; v_state text; v_ok boolean; v_err text; v_n int;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ------------------------------------------------------------------
  -- Case 1: a healthy case.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599332001', 'test332a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 332 A', 'a332@example.com', 100, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('33200000000001', 26000, 'GYD', 'PRUEBA 332', now(), now(), v_op);
  PERFORM funding_reconciliar(v_conv, 'test332');
  SELECT case_id INTO v_case FROM remittance_operations WHERE id = v_op;
  IF v_case IS NULL THEN RAISE EXCEPTION 'case 1: no case after the reconciliation'; END IF;

  v_panel := funding_caso_panel(v_conv);
  IF (v_panel -> 'case' ->> 'id')::uuid IS DISTINCT FROM v_case THEN
    RAISE EXCEPTION 'case 1: the panel returned the wrong case';
  END IF;
  IF v_panel -> 'case' ->> 'status' IS DISTINCT FROM 'allocating' THEN
    RAISE EXCEPTION 'case 1: status %, expected allocating', v_panel -> 'case' ->> 'status';
  END IF;
  IF (v_panel -> 'case' ->> 'depositado')::numeric <> 26000
     OR (v_panel -> 'case' ->> 'asignado')::numeric <> 26000
     OR (v_panel -> 'case' ->> 'disponible')::numeric <> 0 THEN
    RAISE EXCEPTION 'case 1: amounts are %/%/% (expected 26000/26000/0)',
      v_panel -> 'case' ->> 'depositado', v_panel -> 'case' ->> 'asignado', v_panel -> 'case' ->> 'disponible';
  END IF;
  IF jsonb_array_length(v_panel -> 'case' -> 'deposits') <> 1
     OR jsonb_array_length(v_panel -> 'case' -> 'allocations') <> 1 THEN
    RAISE EXCEPTION 'case 1: expected one deposit and one allocation';
  END IF;

  -- ------------------------------------------------------------------
  -- Case 2: a non-member cannot read the panel.
  -- ------------------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN
    PERFORM funding_caso_panel(v_conv);
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM; GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  IF NOT v_ok OR v_state <> '42501' THEN
    RAISE EXCEPTION 'case 2: a non-member read the panel (ok %, state %, error %)', v_ok, v_state, v_err;
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ------------------------------------------------------------------
  -- Case 3: an incident case shows the conflict and a non-member cannot resolve it.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599332002', 'test332b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'clasica', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 50, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source)
  VALUES (v_op, 'cuban_card', 'PRUEBA 332 B', '9234123456789012', '5355512301', 50, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('33200000000002', 26000, 'GYD', 'PRUEBA 332', now(), now(), v_op);
  PERFORM funding_reconciliar(v_conv, 'test332');
  SELECT case_id INTO v_case FROM remittance_operations WHERE id = v_op;

  v_panel := funding_caso_panel(v_conv);
  IF v_panel -> 'case' ->> 'status' IS DISTINCT FROM 'incident' THEN
    RAISE EXCEPTION 'case 3: status %, expected incident', v_panel -> 'case' ->> 'status';
  END IF;
  IF COALESCE(v_panel -> 'case' ->> 'note', '') NOT LIKE '%conflicto%' THEN
    RAISE EXCEPTION 'case 3: the note does not carry the conflict: %', v_panel -> 'case' ->> 'note';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN
    PERFORM funding_caso_resolver_panel(v_case);
  EXCEPTION WHEN OTHERS THEN
    v_ok := true; v_err := SQLERRM; GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
  END;
  IF NOT v_ok OR v_state <> '42501' THEN
    RAISE EXCEPTION 'case 3: a non-member resolved the case (ok %, state %, error %)', v_ok, v_state, v_err;
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- ------------------------------------------------------------------
  -- Case 4: the resolver re-runs the engine; the conflict returns while unfixed.
  -- ------------------------------------------------------------------
  v_panel := funding_caso_resolver_panel(v_case);
  IF v_panel ->> 'status' IS DISTINCT FROM 'incident' THEN
    RAISE EXCEPTION 'case 4: resolving an unfixed conflict returned %, expected incident', v_panel ->> 'status';
  END IF;

  -- ------------------------------------------------------------------
  -- Case 5: after fixing the card, the resolver allocates.
  -- ------------------------------------------------------------------
  UPDATE remittance_beneficiaries SET card_number = '9760123456789012' WHERE operation_id = v_op;
  v_panel := funding_caso_resolver_panel(v_case);
  IF v_panel ->> 'status' IS DISTINCT FROM 'allocating' THEN
    RAISE EXCEPTION 'case 5: after fixing the card the status is %, expected allocating', v_panel ->> 'status';
  END IF;
  SELECT count(*) INTO v_n FROM funding_allocations WHERE operation_id = v_op AND status = 'committed';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: expected one allocation after resolving, found %', v_n; END IF;

  -- ------------------------------------------------------------------
  -- Case 6: a closed case is still returned when there is no active one.
  -- ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599332003', 'test332c') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 13000, quoted_destination_amount = 50, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 332 C', 'c332@example.com', 50, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('33200000000003', 13000, 'GYD', 'PRUEBA 332', now(), now(), v_op);
  PERFORM funding_reconciliar(v_conv, 'test332');
  SELECT case_id INTO v_case FROM remittance_operations WHERE id = v_op;
  PERFORM funding_case_cerrar(v_case, 'test332', 'test332');

  v_panel := funding_caso_panel(v_conv);
  IF (v_panel -> 'case' ->> 'id')::uuid IS DISTINCT FROM v_case
     OR v_panel -> 'case' ->> 'status' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'case 6: the closed case was not returned (% / %)',
      v_panel -> 'case' ->> 'id', v_panel -> 'case' ->> 'status';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
