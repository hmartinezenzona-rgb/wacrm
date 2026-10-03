-- =====================================================================
-- Assertion for migration 189 (the operations panel reads a cash recipient: address and ID-card photo).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
-- The caller is simulated through request.jwt.claims, the way auth.uid() reads it.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_member uuid; v_r record;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990018901', 'test189') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO messages (conversation_id, sender_type, content_type, media_url, message_id)
  VALUES (v_conv, 'customer', 'image', 'https://example.invalid/carnet-189.jpg', 'wamid.test189');
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 29000, 'efectivo_usd') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, address, id_photo_wamid, position, block_index, source, status)
  VALUES (v_op, 'efectivo_usd', '53821203', 'Calle 1 #23, Plaza, La Habana', 'wamid.test189', 1, 1, 'manual', 'vigente');

  SELECT p.user_id INTO v_member FROM profiles p WHERE p.account_id = v_acc AND p.account_role IS NOT NULL LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_member, 'role', 'authenticated')::text, true);

  SELECT * INTO v_r FROM crm_operaciones_de_conversacion(v_conv) WHERE operation_id = v_op;
  IF v_r.beneficiary_type IS DISTINCT FROM 'efectivo_usd' OR v_r.beneficiary_phone IS DISTINCT FROM '53821203' THEN
    RAISE EXCEPTION 'case 1: the cash recipient row must come through, got % %', v_r.beneficiary_type, v_r.beneficiary_phone; END IF;
  IF v_r.beneficiary_address IS DISTINCT FROM 'Calle 1 #23, Plaza, La Habana' THEN
    RAISE EXCEPTION 'case 2: address must come through, got %', v_r.beneficiary_address; END IF;
  IF v_r.beneficiary_id_photo_wamid IS DISTINCT FROM 'wamid.test189'
     OR v_r.beneficiary_id_photo_url IS DISTINCT FROM 'https://example.invalid/carnet-189.jpg' THEN
    RAISE EXCEPTION 'case 3: the ID photo must come through with its message URL, got % %', v_r.beneficiary_id_photo_wamid, v_r.beneficiary_id_photo_url; END IF;
  IF v_r.operation_quoted_destination_amount IS DISTINCT FROM 100 OR v_r.operation_destination_currency IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case 4: 29,000 GYD cash must read 100 USD (188), got % %', v_r.operation_quoted_destination_amount, v_r.operation_destination_currency; END IF;
  IF NOT v_r.operation_beneficiaries_complete THEN
    RAISE EXCEPTION 'case 5: phone + address + ID photo is a complete cash recipient (188)'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
