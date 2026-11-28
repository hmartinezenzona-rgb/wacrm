-- =====================================================================
-- Assertion for migration 382 (crm_adjuntar_comprobante: an agent attaches an image of the chat as a receipt of an operation).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA382', phones 5990382xxxx, wamids 'wamid.PRUEBA382-...'.
-- Case 78e3540b (2026-11-17): the customer sent a new receipt in a burst of three images; the system kept one and the others never became a
-- receipt of any operation. Attaching only stores the image as a receipt (with the reference and amount of the system's reading of that image
-- when there is one, or the ones typed); the card's existing verify does the crossing against the MMG ledger. Cases:
--   1  an image with no reading: a receipt row (source admin) with no reference or amount, a mapping to the image, an audit row
--      `human_receipt_attached`; the panel's read (crm_comprobantes_de_operacion) lists it with the image
--   2  an image the system already read: the reference (digits) and the amount of the reading are prefilled
--   3  typed values win over the reading
--   4  an image the bot already hashed keeps its comp_id (no second mapping)
--   5  the same image twice on the same operation is refused
--   6  refused: an id that is not an image of this conversation, a negative amount, a closed operation, an unknown operation, a user who is
--      not a member
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_ct2 uuid; v_conv uuid; v_conv2 uuid; v_op uuid; v_r jsonb; v_row remittance_operation_receipts%ROWTYPE; v_ok boolean; v_n int; v_rec jsonb;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990382001', 'PRUEBA382 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990382002', 'PRUEBA382 b') RETURNING id INTO v_ct2;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct2) RETURNING id INTO v_conv2;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'deposit_verification', 'remesa', 'GYD', 13000, 'zelle') RETURNING id INTO v_op;
  INSERT INTO messages (conversation_id, sender_type, content_type, media_url, message_id, status, ai_generated, is_panel_action) VALUES
    (v_conv, 'customer', 'image', 'https://example.invalid/prueba382-1.jpg', 'wamid.PRUEBA382-1', 'sent', false, false),
    (v_conv, 'customer', 'image', 'https://example.invalid/prueba382-2.jpg', 'wamid.PRUEBA382-2', 'sent', false, false),
    (v_conv, 'customer', 'image', 'https://example.invalid/prueba382-3.jpg', 'wamid.PRUEBA382-3', 'sent', false, false),
    (v_conv, 'customer', 'image', 'https://example.invalid/prueba382-4.jpg', 'wamid.PRUEBA382-4', 'sent', false, false),
    (v_conv2, 'customer', 'image', 'https://example.invalid/prueba382-otra.jpg', 'wamid.PRUEBA382-OTRA', 'sent', false, false);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, message_id, status, ai_generated, is_panel_action)
  VALUES (v_conv, 'customer', 'text', 'hola', 'wamid.PRUEBA382-TEXTO', 'sent', false, false);
  INSERT INTO cerebro_lecturas_vision (creado, conversation_id, wamid, hash_imagen, tipo, monto, moneda, referencia, estado, datos)
  VALUES (now(), v_conv, 'wamid.PRUEBA382-2', 'h-prueba382-2', 'comprobante', 13000, 'GYD', 'Ref 1040 0000 9977', 'EXITOSA', '{}'::jsonb);
  INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, fecha_recibido, whatsapp_message_id)
  VALUES ('h-prueba382-4', '5990382001', 'COMP-prueb4x', now(), 'wamid.PRUEBA382-4');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- 1 no reading
  v_r := crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-1');
  SELECT * INTO v_row FROM remittance_operation_receipts WHERE operation_id = v_op AND comp_id = v_r ->> 'comp_id';
  IF v_row.id IS NULL OR v_row.source <> 'admin' OR v_row.reference IS NOT NULL OR v_row.amount IS NOT NULL OR v_row.conversation_id IS DISTINCT FROM v_conv THEN
    RAISE EXCEPTION 'case 1: the receipt row is wrong: %', to_jsonb(v_row); END IF;
  IF NOT EXISTS (SELECT 1 FROM comprobantes_hashes WHERE comp_id = v_r ->> 'comp_id' AND whatsapp_message_id = 'wamid.PRUEBA382-1') THEN RAISE EXCEPTION 'case 1: the mapping to the image is missing'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_receipt_attached' AND after ->> 'wamid' = 'wamid.PRUEBA382-1') THEN
    RAISE EXCEPTION 'case 1: the audit row human_receipt_attached is missing'; END IF;
  v_rec := crm_comprobantes_de_operacion(v_op) -> 'receipts';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rec) e WHERE e ->> 'comp_id' = v_r ->> 'comp_id' AND e ->> 'media_url' = 'https://example.invalid/prueba382-1.jpg') THEN
    RAISE EXCEPTION 'case 1: the panel read must list the receipt with its image: %', v_rec; END IF;
  IF (v_r ->> 'prefilled')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'case 1: nothing was prefilled: %', v_r; END IF;

  -- 2 prefilled from the reading
  v_r := crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-2');
  SELECT * INTO v_row FROM remittance_operation_receipts WHERE operation_id = v_op AND comp_id = v_r ->> 'comp_id';
  IF v_row.reference IS DISTINCT FROM '104000009977' OR v_row.amount IS DISTINCT FROM 13000 OR v_row.currency IS DISTINCT FROM 'GYD' OR (v_r ->> 'prefilled')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'case 2: reference (digits) and amount must come from the reading: %', to_jsonb(v_row); END IF;

  -- 3 typed values win
  v_r := crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-3', '10400000000024', 15000);
  SELECT * INTO v_row FROM remittance_operation_receipts WHERE operation_id = v_op AND comp_id = v_r ->> 'comp_id';
  IF v_row.reference IS DISTINCT FROM '10400000000024' OR v_row.amount IS DISTINCT FROM 15000 THEN RAISE EXCEPTION 'case 3: typed values must win: %', to_jsonb(v_row); END IF;

  -- 4 an image the bot already hashed
  v_r := crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-4');
  IF v_r ->> 'comp_id' <> 'COMP-prueb4x' THEN RAISE EXCEPTION 'case 4: the bot''s comp_id must be kept, got %', v_r; END IF;
  SELECT count(*) INTO v_n FROM comprobantes_hashes WHERE whatsapp_message_id = 'wamid.PRUEBA382-4';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 4: no second mapping, got %', v_n; END IF;

  -- 5 twice
  v_ok := false; BEGIN PERFORM crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-4'); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 5: the same image twice on one operation must be refused'; END IF;

  -- 6 refusals
  FOREACH v_rec IN ARRAY ARRAY['"wamid.PRUEBA382-TEXTO"', '"wamid.PRUEBA382-OTRA"', '"wamid.NO-EXISTE"']::jsonb[] LOOP
    v_ok := false; BEGIN PERFORM crm_adjuntar_comprobante(v_op, v_rec #>> '{}'); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
    IF NOT v_ok THEN RAISE EXCEPTION 'case 6a: [%] is not an image of this conversation: must be refused', v_rec; END IF;
  END LOOP;
  v_ok := false; BEGIN PERFORM crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-1', NULL, -5); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6b: a negative amount must be refused'; END IF;
  v_ok := false; BEGIN PERFORM crm_adjuntar_comprobante(gen_random_uuid(), 'wamid.PRUEBA382-1'); EXCEPTION WHEN SQLSTATE 'P0002' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6c: an unknown operation must be refused'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false; BEGIN PERFORM crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-1'); EXCEPTION WHEN SQLSTATE '42501' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6d: a user who is not a member must be refused'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_ok := false; BEGIN PERFORM crm_adjuntar_comprobante(v_op, 'wamid.PRUEBA382-1'); EXCEPTION WHEN SQLSTATE '22023' THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 6e: a closed operation must be refused'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
