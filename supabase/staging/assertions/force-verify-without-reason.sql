-- =====================================================================
-- Assertion for migration 192 (force-verify from the panel takes no typed reason). Self-reverting: one DO block that
-- ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
-- odd/tasks/remesa-closing-and-cash.md (E4). Owner, 2026-10-03: like closing and deleting (191), forcing a verification
-- is confirmed with a check icon and no reason field; a fixed internal note is audited instead.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_admin uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990019201', 'test192') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'deposit_verification', 'remesa', 'GYD', 5000, 'cuban_card') RETURNING id INTO v_op;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  PERFORM crm_forzar_verificacion(v_op, NULL, false);
  IF (SELECT status FROM remittance_operations WHERE id = v_op) IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 1: force-verify without a reason must verify'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_forced_verification'
                  AND reason = 'Verified manually from the panel') THEN
    RAISE EXCEPTION 'case 1: the fixed note must be audited'; END IF;
  IF (SELECT customer_notice_muted_for FROM remittance_operations WHERE id = v_op) IS DISTINCT FROM 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 1: the notify choice (191) must still apply'; END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'crm_forzar_verificacion') <> 1 THEN
    RAISE EXCEPTION 'case 2: exactly one crm_forzar_verificacion'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
