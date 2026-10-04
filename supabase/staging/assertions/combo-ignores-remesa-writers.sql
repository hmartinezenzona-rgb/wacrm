-- =====================================================================
-- Assertion for migration 210 (the remesa beneficiary writers leave a combo alone). Self-reverting: one DO block
-- that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- Owner test round 2, 2026-10-04: in a combo conversation the customer typed "53458767", "53821069", "53845687".
-- The typed-number auto registration (cerebro_guardar_beneficiario_auto -> cerebro_escribir_bloque_beneficiario)
-- wrote them as 'cuban_card' generations on the combo and marked the combo recipients 'reemplazado'; the bot then
-- asked again for data it had.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_res text; v_state text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990021001', 'test210') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (v_conv, 'customer', 'text', 'quiero mandar dos combos', now() - interval '5 minutes');
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Juan Perez', '53458767', 'calle 40 entre 30/45', 'bulevar de Santa Fe', '', 30000, 1);
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Julian Gonzalez', '53821069', 'calle 40 entre 30/45', 'bulevar de Santa Fe', '', 25000, 2);
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'combo';

  -- What the combo must still look like after each writer: the two combo recipients, untouched, and nothing else.
  -- 1. The typed-number auto registration (runs before the bot on every message with a Cuban number).
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', '53845687');
  PERFORM cerebro_guardar_beneficiario_auto(v_conv, '', '53845687', '', '53845687', 'assert210');
  SELECT string_agg(b.beneficiary_type || ':' || coalesce(b.name, '-') || ':' || b.status, ',' ORDER BY b.created_at) INTO v_state
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op;
  IF v_state IS DISTINCT FROM 'combo:Juan Perez:vigente,combo:Julian Gonzalez:vigente' THEN
    RAISE EXCEPTION 'case 1: the auto registration touched the combo: %', v_state; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv AND service_type <> 'combo') THEN
    RAISE EXCEPTION 'case 1: a typed number in a combo conversation opened another operation'; END IF;

  -- 2. The shared writer itself refuses a combo operation.
  PERFORM cerebro_escribir_bloque_beneficiario(v_conv, v_op, E'Tarjeta: 9227069999999999\nCelular: 53845687');
  -- 3. The remesa tools, if the model calls them by mistake.
  PERFORM cerebro_guardar_beneficiario(v_conv, 'X', '', '53845687', 'assert210', v_op, 'assert');
  PERFORM cerebro_guardar_reparto(v_conv, '', '53845687', '', '', '53821069', '', '', '', '', 'assert210', v_op, 'assert');
  SELECT string_agg(b.beneficiary_type || ':' || coalesce(b.name, '-') || ':' || b.status, ',' ORDER BY b.created_at) INTO v_state
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op;
  IF v_state IS DISTINCT FROM 'combo:Juan Perez:vigente,combo:Julian Gonzalez:vigente' THEN
    RAISE EXCEPTION 'case 2/3: a remesa writer touched the combo: %', v_state; END IF;

  -- 4. The combo tool still works afterwards: the contact phone lands on combo 2.
  PERFORM crm_registrar_destinatario_combo(v_conv, '', '', '', '', '53845687', NULL, 2);
  IF (SELECT contact_phone FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND name = 'Julian Gonzalez')
     IS DISTINCT FROM '53845687' THEN
    RAISE EXCEPTION 'case 4: the combo tool no longer updates combo 2'; END IF;

  RAISE EXCEPTION 'ALL PASS';
END $$;
