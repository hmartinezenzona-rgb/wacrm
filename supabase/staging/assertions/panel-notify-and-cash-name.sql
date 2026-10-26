-- =====================================================================
-- Assertion for migration 191 (notify-customer choice on panel actions, closing actions without a typed reason,
-- the cash recipient's name). Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Runs on staging and production. The caller is simulated through request.jwt.claims (an owner/admin member).
--
-- odd/tasks/remesa-closing-and-cash.md (A4, E1, E2, E3). Owner, 2026-10-03:
--   - A4: the bot repeats the cash recipient's name but it was never stored.
--   - E1/E3: closing manually and deleting take no typed reason; a fixed internal note is audited instead.
--   - E2: every panel action that messages the customer carries a "notify" choice: on by default, except the manual
--     close (off by default). The choice travels on the operation row as customer_notice_muted_for = the status the
--     silence applies to, written in the same statement as the status change (the notifier reads that row image).
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_t191(p_tag text, p_status text, p_method text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900191' || p_tag, 'test191' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, p_status, 'remesa', 'GYD', 29000, p_method) RETURNING id INTO v_op;
  RETURN v_op;
END $$;

DO $$
DECLARE
  v_acc uuid; v_admin uuid; v_op uuid; v_conv uuid; v_r record; v_n int;
BEGIN
  SELECT account_id INTO v_acc FROM conversations LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;

  -- 1. A4: the bot stores the cash recipient's name; a later call without it keeps it.
  v_op := pg_temp.op_t191('01', 'collecting_information', 'efectivo_usd');
  SELECT conversation_id INTO v_conv FROM remittance_operations WHERE id = v_op;
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, '53904458', 'Cipres 2D Bajos, Cerro', NULL, 'Anabel Frenes Vera');
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, NULL, NULL, 'wamid.test191');
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r.name IS DISTINCT FROM 'Anabel Frenes Vera' OR v_r.id_photo_wamid IS DISTINCT FROM 'wamid.test191' THEN
    RAISE EXCEPTION 'case 1: the name must be stored and kept, got % / %', v_r.name, v_r.id_photo_wamid; END IF;
  -- the name alone is a change worth recording
  PERFORM crm_registrar_datos_entrega_efectivo(v_conv, NULL, NULL, NULL, 'Anabel Frenes');
  IF (SELECT name FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') IS DISTINCT FROM 'Anabel Frenes' THEN
    RAISE EXCEPTION 'case 1: a corrected name must replace the previous one'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE action = 'automation_cash_delivery_data_registered'
                  AND after ->> 'name' = 'Anabel Frenes') THEN
    RAISE EXCEPTION 'case 1: the audit must carry the name'; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 2. E2: force-verify notifies by default and can be silenced.
  v_op := pg_temp.op_t191('02', 'deposit_verification', 'cuban_card');
  PERFORM crm_forzar_verificacion(v_op, 'comprobante revisado');
  IF (SELECT customer_notice_muted_for FROM remittance_operations WHERE id = v_op) IS NOT NULL THEN
    RAISE EXCEPTION 'case 2: force-verify notifies by default'; END IF;
  v_op := pg_temp.op_t191('03', 'deposit_verification', 'cuban_card');
  PERFORM crm_forzar_verificacion(v_op, 'comprobante revisado', false);
  IF (SELECT customer_notice_muted_for FROM remittance_operations WHERE id = v_op) IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 2: a silenced force-verify must mute ready_to_transfer'; END IF;

  -- 3. E2: deliver notifies by default and can be silenced (the beneficiary is complete).
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', '9235123487786543', '53821204', 1, 1, 'manual', 'vigente');
  -- (329) Delivery now requires verified funding.
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32940000000001', 29000, 'GYD', 'PRUEBA 191', now(), now(), v_op);
  PERFORM crm_entregar_operacion(v_op, '{"mode": "skip_proof"}'::jsonb, false);
  SELECT status, customer_notice_muted_for AS m INTO v_r FROM remittance_operations WHERE id = v_op;
  IF v_r.status <> 'completed' OR v_r.m IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'case 3: a silenced delivery must complete and mute completed, got % / %', v_r.status, v_r.m; END IF;
  v_op := pg_temp.op_t191('04', 'ready_to_transfer', 'cuban_card');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', '9235123487786543', '53821204', 1, 1, 'manual', 'vigente');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('32940000000002', 29000, 'GYD', 'PRUEBA 191', now(), now(), v_op);
  PERFORM crm_entregar_operacion(v_op, '{"mode": "skip_proof"}'::jsonb);
  IF (SELECT customer_notice_muted_for FROM remittance_operations WHERE id = v_op) IS NOT NULL THEN
    RAISE EXCEPTION 'case 3: a delivery notifies by default'; END IF;

  -- 4. E1 + E2: a manual close needs no typed reason, audits a fixed note, and is SILENT by default.
  v_op := pg_temp.op_t191('05', 'ready_to_transfer', 'cuban_card');
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT status, customer_notice_muted_for AS m INTO v_r FROM remittance_operations WHERE id = v_op;
  IF v_r.status <> 'completed' OR v_r.m IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'case 4: a manual close is completed and silent by default, got % / %', v_r.status, v_r.m; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_manual_close'
                  AND reason = 'Closed manually from the panel') THEN
    RAISE EXCEPTION 'case 4: the manual close must audit the fixed note'; END IF;
  v_op := pg_temp.op_t191('06', 'ready_to_transfer', 'cuban_card');
  PERFORM crm_cerrar_operacion_manual(v_op, NULL, true);
  IF (SELECT customer_notice_muted_for FROM remittance_operations WHERE id = v_op) IS NOT NULL THEN
    RAISE EXCEPTION 'case 4: a manual close with the bell on must notify'; END IF;

  -- 5. E3: delete needs no typed reason and audits a fixed note.
  v_op := pg_temp.op_t191('07', 'collecting_information', 'cuban_card');
  PERFORM crm_eliminar_operacion(v_op);
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_operation_deleted'
                  AND reason = 'Deleted from the panel') THEN
    RAISE EXCEPTION 'case 5: the deletion must audit the fixed note'; END IF;

  -- 6. E2: the panel's deposit verification also takes the choice.
  SELECT count(*) INTO v_n FROM pg_proc WHERE proname = 'crm_verificar_deposito'
     AND pg_get_function_identity_arguments(oid) = 'p_operation_id uuid, p_items jsonb, p_notify boolean';
  IF v_n <> 1 OR (SELECT count(*) FROM pg_proc WHERE proname = 'crm_verificar_deposito') <> 1 THEN
    RAISE EXCEPTION 'case 6: crm_verificar_deposito must have exactly one signature with p_notify'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
