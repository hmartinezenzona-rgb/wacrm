-- =====================================================================
-- Assertion for migration 379 (crm_cambiar_estado: an agent moves an open operation between open states from the panel).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA379', phones 5990379xxxx.
-- Verify and force-verify only work from deposit_verification / incident, so an operation created from scratch (crm_crear_operacion) could not
-- be verified from the panel. Allowed targets: collecting_information, awaiting_deposit, deposit_verification, ready_to_transfer, from any
-- open state, and back. Completed and cancelled keep their own actions. Cases:
--   1  collecting_information -> deposit_verification: status changes, audit `human_status_change` keeps before/after, the customer notice
--      for that state is muted
--   2  an operation created from scratch can be moved to deposit_verification and then force-verified (the point of this function)
--   3  ready_to_transfer -> deposit_verification (back)
--   4  to ready_to_transfer with notify: the notice is not muted and a `human_forced_verification` audit row lets the notifier speak;
--      without notify: muted, no such audit row
--   5  leaving an incident clears its reason
--   6  the same state: nothing changes, no audit row
--   7  refused: a completed operation, a state that is not allowed (completed, cancelled, transferring, unknown), an unknown operation, a
--      user who is not a member
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_row remittance_operations%ROWTYPE; v_r jsonb; v_n int; v_ok boolean; v_s text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990379001', 'PRUEBA379 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1
  v_r := crm_cambiar_estado(v_op, 'deposit_verification');
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.status <> 'deposit_verification' OR v_row.customer_notice_muted_for IS DISTINCT FROM 'deposit_verification' THEN
    RAISE EXCEPTION 'case 1: status / mute wrong: % / %', v_row.status, v_row.customer_notice_muted_for; END IF;
  IF (v_r ->> 'changed')::boolean IS NOT TRUE OR v_r ->> 'new_status' <> 'deposit_verification' OR v_r ->> 'previous' <> 'collecting_information' THEN
    RAISE EXCEPTION 'case 1: the answer is wrong: %', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_status_change'
                  AND before ->> 'status' = 'collecting_information' AND after ->> 'status' = 'deposit_verification') THEN
    RAISE EXCEPTION 'case 1: the audit row human_status_change is missing'; END IF;

  -- 2 created from scratch -> verification -> force verify
  v_op := (crm_crear_operacion(v_conv, 'zelle', 13000) ->> 'id')::uuid;
  v_ok := false;
  BEGIN PERFORM crm_forzar_verificacion(v_op, NULL, false);
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 2: force-verify from collecting_information must still be refused (it is the reason for this function)'; END IF;
  PERFORM crm_cambiar_estado(v_op, 'deposit_verification');
  PERFORM crm_forzar_verificacion(v_op, 'PRUEBA', false);
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 2: force-verify must reach ready_to_transfer'; END IF;

  -- 3 back
  PERFORM crm_cambiar_estado(v_op, 'deposit_verification');
  IF (SELECT status FROM remittance_operations WHERE id = v_op) <> 'deposit_verification' THEN RAISE EXCEPTION 'case 3: back to deposit_verification failed'; END IF;

  -- 4 notify
  PERFORM crm_cambiar_estado(v_op, 'ready_to_transfer', false);
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.customer_notice_muted_for IS DISTINCT FROM 'ready_to_transfer' THEN RAISE EXCEPTION 'case 4: without notify the notice must be muted, got %', v_row.customer_notice_muted_for; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_forced_verification' AND reason LIKE '%panel%';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: without notify no human_forced_verification row, got %', v_n; END IF;
  PERFORM crm_cambiar_estado(v_op, 'deposit_verification');
  PERFORM crm_cambiar_estado(v_op, 'ready_to_transfer', true);
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.customer_notice_muted_for IS NOT NULL THEN RAISE EXCEPTION 'case 4: with notify the notice must not be muted, got %', v_row.customer_notice_muted_for; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_forced_verification' AND reason LIKE '%panel%';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 4: with notify one human_forced_verification row, got %', v_n; END IF;

  -- 5 leaving an incident
  UPDATE remittance_operations SET status = 'incident', incident_reason = 'sin_correo' WHERE id = v_op;
  PERFORM crm_cambiar_estado(v_op, 'collecting_information');
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op;
  IF v_row.status <> 'collecting_information' OR v_row.incident_reason IS NOT NULL THEN
    RAISE EXCEPTION 'case 5: leaving an incident must clear its reason: % / %', v_row.status, v_row.incident_reason; END IF;

  -- 6 same state
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_status_change';
  v_r := crm_cambiar_estado(v_op, 'collecting_information');
  IF (v_r ->> 'changed')::boolean IS NOT FALSE OR (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_status_change') <> v_n THEN
    RAISE EXCEPTION 'case 6: the same state must change nothing and write no audit row: %', v_r; END IF;

  -- 7 refusals
  FOREACH v_s IN ARRAY ARRAY['completed', 'cancelled', 'transferring', 'paloma', ''] LOOP
    v_ok := false;
    BEGIN PERFORM crm_cambiar_estado(v_op, v_s);
    EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
    IF NOT v_ok THEN RAISE EXCEPTION 'case 7a: the state [%] must be refused', v_s; END IF;
  END LOOP;
  v_ok := false;
  BEGIN PERFORM crm_cambiar_estado(gen_random_uuid(), 'awaiting_deposit');
  EXCEPTION WHEN SQLSTATE 'P0002' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7b: an unknown operation must be refused'; END IF;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_ok := false;
  BEGIN PERFORM crm_cambiar_estado(v_op, 'collecting_information');
  EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7c: a completed operation must be refused'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN PERFORM crm_cambiar_estado(v_op, 'collecting_information');
  EXCEPTION WHEN SQLSTATE '42501' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7d: a user who is not a member must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
