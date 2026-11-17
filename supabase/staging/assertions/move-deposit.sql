-- =====================================================================
-- Assertion for migration 381 (crm_mover_deposito: an agent releases a verified deposit from an operation, or moves it to another open
-- operation of the same conversation, from the operations panel).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA381', phones 5990381xxxx, deposits 'PRUEBA381-...'.
-- The deposit moves WHOLE (one ledger row). Releasing makes it free again (the picker of 380 lists it); moving gives it to the target, which
-- becomes ready_to_transfer when it covers its request (an empty request becomes the deposit) or stays in verification. The source goes back
-- to awaiting a deposit when that was its only money. The customer notice of every new state is muted. Cases:
--   1  release: the deposit is free (no operation, not consumed), its funding-case link is gone, the source is awaiting_deposit and muted, audit
--      `human_deposit_release`; the deposit appears in crm_depositos_sin_dueno
--   2  move: the deposit belongs to the target, the target is ready_to_transfer (covered), an empty request becomes the deposit, the source is
--      awaiting_deposit, one audit row `human_deposit_move` on each operation
--   3  the source keeps another deposit: it falls from ready_to_transfer to deposit_verification when what is left does not cover it
--   4  a target whose request is larger than the deposit stays in deposit_verification
--   5  refused: a deposit that is not linked, an unknown deposit, a deposit of another operation, a closed source, a closed target, a target of
--      another conversation, the same operation, an operation of a mixed send, a user who is not a member
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_ct2 uuid; v_conv uuid; v_conv2 uuid; v_a uuid; v_b uuid; v_c uuid; v_other uuid; v_r jsonb; v_row remittance_operations%ROWTYPE;
  v_n int; v_ok boolean; v_case uuid; v_free jsonb;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990381001', 'PRUEBA381 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990381002', 'PRUEBA381 b') RETURNING id INTO v_ct2;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct2) RETURNING id INTO v_conv2;
  -- A: ready_to_transfer with its deposit of 13000; B: empty request; C: asks 26000
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 0, 'zelle') RETURNING id INTO v_b;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 26000, 'zelle') RETURNING id INTO v_c;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv2, v_ct2, 'awaiting_deposit', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_other;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('PRUEBA381-D1', 13000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '1 hour', now(), v_a);
  v_case := funding_case_abrir(v_conv, 'prueba');
  INSERT INTO case_deposits (case_id, deposit_trans_id, linked_by) VALUES (v_case, 'PRUEBA381-D1', 'prueba');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1 release
  v_r := crm_mover_deposito(v_a, 'PRUEBA381-D1', NULL);
  IF EXISTS (SELECT 1 FROM depositos_mmg WHERE trans_id = 'PRUEBA381-D1' AND (operation_id IS NOT NULL OR consumido_en IS NOT NULL)) THEN
    RAISE EXCEPTION 'case 1: the released deposit must be free'; END IF;
  IF EXISTS (SELECT 1 FROM case_deposits WHERE deposit_trans_id = 'PRUEBA381-D1') THEN RAISE EXCEPTION 'case 1: the funding-case link must be gone'; END IF;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_a;
  IF v_row.status <> 'awaiting_deposit' OR v_row.customer_notice_muted_for IS DISTINCT FROM 'awaiting_deposit' THEN
    RAISE EXCEPTION 'case 1: the source must await a deposit and be muted: % / %', v_row.status, v_row.customer_notice_muted_for; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_a AND action = 'human_deposit_release' AND before ->> 'trans_id' = 'PRUEBA381-D1') THEN
    RAISE EXCEPTION 'case 1: the audit row human_deposit_release is missing'; END IF;
  v_free := crm_depositos_sin_dueno(v_a);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_free) e WHERE e ->> 'trans_id' = 'PRUEBA381-D1') THEN RAISE EXCEPTION 'case 1: the released deposit must appear as free'; END IF;
  IF (v_r ->> 'released')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'case 1: the answer must say released: %', v_r; END IF;

  -- 2 move to an operation with an empty request
  UPDATE depositos_mmg SET consumido_en = now(), operation_id = v_a WHERE trans_id = 'PRUEBA381-D1';
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_a;
  v_r := crm_mover_deposito(v_a, 'PRUEBA381-D1', v_b);
  IF (SELECT operation_id FROM depositos_mmg WHERE trans_id = 'PRUEBA381-D1') IS DISTINCT FROM v_b THEN RAISE EXCEPTION 'case 2: the deposit must belong to the target'; END IF;
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_b;
  IF v_row.status <> 'ready_to_transfer' OR v_row.quoted_source_amount <> 13000 OR v_row.customer_notice_muted_for IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 2: the target must be ready (covered), take the deposit as its amount and be muted: % / % / %', v_row.status, v_row.quoted_source_amount, v_row.customer_notice_muted_for; END IF;
  IF (SELECT status FROM remittance_operations WHERE id = v_a) <> 'awaiting_deposit' THEN RAISE EXCEPTION 'case 2: the source must await a deposit'; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE action = 'human_deposit_move' AND row_id IN (v_a, v_b);
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 2: one audit row on each operation, got %', v_n; END IF;
  IF (v_r ->> 'moved')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'case 2: the answer must say moved: %', v_r; END IF;

  -- 3 the source keeps another deposit
  UPDATE remittance_operations SET status = 'ready_to_transfer', quoted_source_amount = 26000 WHERE id = v_c;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id) VALUES
    ('PRUEBA381-D2', 13000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '2 hours', now(), v_c),
    ('PRUEBA381-D3', 13000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now() - interval '3 hours', now(), v_c);
  PERFORM crm_mover_deposito(v_c, 'PRUEBA381-D2', NULL);
  IF (SELECT status FROM remittance_operations WHERE id = v_c) <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case 3: with 13000 left of 26000 the source must be in deposit_verification, got %', (SELECT status FROM remittance_operations WHERE id = v_c); END IF;

  -- 4 a target with a larger request stays in verification
  UPDATE remittance_operations SET status = 'awaiting_deposit', quoted_source_amount = 26000 WHERE id = v_a;
  PERFORM crm_mover_deposito(v_c, 'PRUEBA381-D3', v_a);
  IF (SELECT status FROM remittance_operations WHERE id = v_a) <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case 4: a target asking 26000 with 13000 must be in deposit_verification, got %', (SELECT status FROM remittance_operations WHERE id = v_a); END IF;

  -- 5 refusals
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-D2', NULL); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5a: a deposit that is not linked must be refused'; END IF;
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-NO-EXISTE', NULL); EXCEPTION WHEN SQLSTATE 'P0002' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5b: an unknown deposit must be refused'; END IF;
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_b, 'PRUEBA381-D3', NULL); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5c: a deposit of another operation must be refused'; END IF;
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-D3', v_a); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5d: moving to the same operation must be refused'; END IF;
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-D3', v_other); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5e: a target of another conversation must be refused'; END IF;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_c;
  PERFORM set_config('wacrm.origin', '', true);
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-D3', v_c); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5f: a closed target must be refused'; END IF;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_a;
  PERFORM set_config('wacrm.origin', '', true);
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-D3', NULL); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5g: a closed source must be refused'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false; BEGIN PERFORM crm_mover_deposito(v_a, 'PRUEBA381-D3', NULL); EXCEPTION WHEN SQLSTATE '42501' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5h: a user who is not a member must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
