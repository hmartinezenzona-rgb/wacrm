-- =====================================================================
-- Assertion for migration 190 (panel closing actions: close manually without notifying, delete a remesa, add a
-- card beneficiary without phone). Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Runs on staging and production. The caller is simulated through request.jwt.claims (an owner/admin member).
--
-- odd/tasks/remesa-closing-and-cash.md (B+D). Owner, 2026-10-02:
--   - Rubislandi deposited, the owner transferred, the customer never sent the phone: the owner adds the card
--     without phone and CLOSES the remesa so it counts in the calculator, WITHOUT a message to the customer.
--   - Bruce's misread resend opened a second remesa in Incidencia: the owner DELETES it (trash icon).
-- Delete is a soft delete (status cancelled + audit), refused once money is verified or the remesa is completed.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t190(p_tag text, p_status text, p_gyd numeric) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900190' || p_tag, 'test190' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, p_status, 'remesa', 'GYD', p_gyd) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE
  v_acc uuid; v_admin uuid; v_op uuid; v_op2 uuid; v_r record; v_ok boolean; v_n int;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. Rubislandi: a verified remesa, the card is added WITHOUT phone.
  v_op := pg_temp.op_t190('01', 'ready_to_transfer', 5000);
  PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "cuban_card", "card_number": "9205129976951757",
                                           "delivery_method": "cuban_card", "amount": 15000, "currency": "CUP"}'::jsonb);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r.card_number IS DISTINCT FROM '9205129976951757' OR v_r.phone IS NOT NULL THEN
    RAISE EXCEPTION 'case 1: the card must be added without phone, got % / %', v_r.card_number, v_r.phone; END IF;
  -- a phone, when given, is still validated
  v_ok := false;
  BEGIN
    PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "cuban_card", "card_number": "9205129976951758",
                                             "phone": "12", "delivery_method": "cuban_card", "amount": 1, "currency": "CUP"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_ok := SQLERRM LIKE '%phone%';
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 1: a malformed phone must still be refused'; END IF;

  -- 2. ... and CLOSED manually: completed, delivery_mode closed_manually (the notifier stays silent), audited with
  --    the reason, fed to the calculator.
  PERFORM crm_cerrar_operacion_manual(v_op, 'Transferido por el admin; el cliente nunca mando el celular');
  SELECT * INTO v_r FROM remittance_operations WHERE id = v_op;
  IF v_r.status IS DISTINCT FROM 'completed' OR v_r.delivery_mode IS DISTINCT FROM 'closed_manually'
     OR v_r.delivered_by IS DISTINCT FROM v_admin THEN
    RAISE EXCEPTION 'case 2: expected completed / closed_manually / delivered_by admin, got % / % / %', v_r.status, v_r.delivery_mode, v_r.delivered_by; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_manual_close'
                  AND reason LIKE 'Transferido por el admin%') THEN
    RAISE EXCEPTION 'case 2: the manual close must be audited with its reason'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE operation_id = v_op) THEN
    RAISE EXCEPTION 'case 2: the closed remesa must reach the calculator'; END IF;

  -- 3. A manual close needs verified money: a remesa still collecting data is refused.
  v_op2 := pg_temp.op_t190('03', 'collecting_information', 0);
  v_ok := false;
  BEGIN PERFORM crm_cerrar_operacion_manual(v_op2, 'motivo'); EXCEPTION WHEN OTHERS THEN v_ok := true; END;
  IF NOT v_ok OR (SELECT status FROM remittance_operations WHERE id = v_op2) <> 'collecting_information' THEN
    RAISE EXCEPTION 'case 3: a remesa without a verified deposit must not be closed manually'; END IF;

  -- 4. Bruce: a remesa in Incidencia without verified money is DELETED (soft): cancelled, audited, out of the panel.
  v_op2 := pg_temp.op_t190('04', 'incident', 28000);
  PERFORM crm_eliminar_operacion(v_op2, 'Comprobante repetido y mal leido');
  IF (SELECT status FROM remittance_operations WHERE id = v_op2) IS DISTINCT FROM 'cancelled' THEN
    RAISE EXCEPTION 'case 4: a deleted remesa must be cancelled'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op2 AND action = 'human_operation_deleted'
                  AND reason = 'Comprobante repetido y mal leido') THEN
    RAISE EXCEPTION 'case 4: the deletion must be audited with its reason'; END IF;
  SELECT count(*) INTO v_n FROM crm_operaciones_de_conversacion((SELECT conversation_id FROM remittance_operations WHERE id = v_op2))
   WHERE operation_id = v_op2;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: a deleted remesa must leave the panel'; END IF;

  -- 5. Money is protected: a verified remesa and a completed one cannot be deleted.
  v_op2 := pg_temp.op_t190('05', 'ready_to_transfer', 13000);
  v_ok := false;
  BEGIN PERFORM crm_eliminar_operacion(v_op2, 'x'); EXCEPTION WHEN OTHERS THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: a verified remesa must not be deleted'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_eliminar_operacion(v_op, 'x'); EXCEPTION WHEN OTHERS THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: a completed remesa must not be deleted'; END IF;

  -- 6. Only an owner/admin: someone outside the account gets 42501.
  v_op2 := pg_temp.op_t190('06', 'incident', 1000);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN PERFORM crm_eliminar_operacion(v_op2, 'x'); EXCEPTION WHEN insufficient_privilege THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6: a non-member must get insufficient_privilege'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
