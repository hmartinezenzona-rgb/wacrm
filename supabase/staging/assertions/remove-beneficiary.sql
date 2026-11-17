-- =====================================================================
-- Assertion for migration 377 (crm_quitar_beneficiario: an agent removes a current recipient from the operations panel).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA377', phones 5990377xxxx.
-- Removing is a soft change: the row becomes 'reemplazado' (history kept), the operation is locked against automation for its recipients
-- and an audit row keeps what was removed. Cases:
--   1  one of two Zelle recipients is removed: that row is reemplazado with replaced_at, the other stays vigente, the audit row
--      `human_beneficiary_removed` keeps the removed account, the operation is locked for beneficiaries, the answer carries `complete`
--   2  the only recipient of an operation is removed: allowed, the operation stays open and is no longer complete
--   3  a combo recipient is removed: the combo total follows (sum of the vigente combo amounts)
--   4  refused: a completed operation, a recipient that is not current, an unknown id, a user who is not a member
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_b1 uuid; v_b2 uuid; v_r jsonb; v_n int; v_ok boolean; v_row remittance_beneficiaries%ROWTYPE;
  v_ba text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990377001', 'PRUEBA377 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 26000, 'zelle') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'PRUEBA Titular Uno', 'prueba377a@example.com', 50, 'USD', 1, 1, 'notes_parse', 'vigente') RETURNING id INTO v_b1;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'PRUEBA Titular Dos', 'prueba377b@example.com', 50, 'USD', 2, 2, 'notes_parse', 'vigente') RETURNING id INTO v_b2;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1 remove one of two
  v_r := crm_quitar_beneficiario(v_b1);
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE id = v_b1;
  IF v_row.status <> 'reemplazado' OR v_row.replaced_at IS NULL THEN RAISE EXCEPTION 'case 1: the row must be reemplazado with replaced_at, got % / %', v_row.status, v_row.replaced_at; END IF;
  IF (SELECT status FROM remittance_beneficiaries WHERE id = v_b2) <> 'vigente' THEN RAISE EXCEPTION 'case 1: the other recipient must stay vigente'; END IF;
  IF (v_r ->> 'id')::uuid <> v_b1 OR NOT (v_r ? 'complete') THEN RAISE EXCEPTION 'case 1: the answer must carry id and complete, got %', v_r; END IF;
  SELECT (before ->> 'zelle_account') INTO v_ba FROM remittance_admin_audit
   WHERE row_id = v_b1 AND action = 'human_beneficiary_removed' ORDER BY created_at DESC LIMIT 1;
  IF v_ba IS DISTINCT FROM 'prueba377a@example.com' THEN RAISE EXCEPTION 'case 1: the audit row must keep the removed account, got %', v_ba; END IF;
  IF NOT (SELECT admin_locked_fields ? 'beneficiaries' FROM remittance_operations WHERE id = v_op) THEN RAISE EXCEPTION 'case 1: the operation must be locked for beneficiaries'; END IF;
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'collecting_information' THEN RAISE EXCEPTION 'case 1: the operation must stay open'; END IF;

  -- 2 the only recipient
  v_r := crm_quitar_beneficiario(v_b2);
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 2: no vigente recipient must remain, got %', v_n; END IF;
  IF (v_r ->> 'complete')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'case 2: an operation without recipients is not complete, got %', v_r; END IF;
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'collecting_information' THEN RAISE EXCEPTION 'case 2: the operation must stay open'; END IF;

  -- 3 combo total follows
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990377002', 'PRUEBA377 b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM crm_registrar_destinatario_combo(v_conv, 'PRUEBA Ana', '53111222', 'Calle 1 #2, Vedado, La Habana', 'Casa azul', NULL, 30000, 1);
  PERFORM crm_registrar_destinatario_combo(v_conv, 'PRUEBA Luis', '53333444', 'Calle 5, Holguin', 'Frente al parque', NULL, 25000, 2);
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'combo';
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 55000 THEN RAISE EXCEPTION 'case 3: fixture total must be 55000'; END IF;
  SELECT id INTO v_b1 FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND name = 'PRUEBA Ana';
  PERFORM crm_quitar_beneficiario(v_b1);
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 25000 THEN
    RAISE EXCEPTION 'case 3: the combo total must follow the remaining recipients (25000), got %', (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op); END IF;

  -- 4 refusals
  -- 4a not current
  v_ok := false;
  BEGIN PERFORM crm_quitar_beneficiario(v_b1);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4a: removing a recipient that is not current must be refused'; END IF;
  -- 4b unknown id
  v_ok := false;
  BEGIN PERFORM crm_quitar_beneficiario(gen_random_uuid());
  EXCEPTION WHEN SQLSTATE 'P0002' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4b: an unknown recipient must be refused'; END IF;
  -- 4c completed operation
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'PRUEBA Titular Tres', 'prueba377c@example.com', 50, 'USD', 1, 1, 'notes_parse', 'vigente') RETURNING id INTO v_b2;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_ok := false;
  BEGIN PERFORM crm_quitar_beneficiario(v_b2);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4c: removing a recipient of a completed operation must be refused'; END IF;
  IF (SELECT status FROM remittance_beneficiaries WHERE id = v_b2) <> 'vigente' THEN RAISE EXCEPTION 'case 4c: the recipient must be untouched'; END IF;
  -- 4d not a member
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'PRUEBA Titular Cuatro', 'prueba377d@example.com', 50, 'USD', 1, 1, 'notes_parse', 'vigente') RETURNING id INTO v_b2;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN PERFORM crm_quitar_beneficiario(v_b2);
  EXCEPTION WHEN SQLSTATE '42501' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 4d: a user who is not a member must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
