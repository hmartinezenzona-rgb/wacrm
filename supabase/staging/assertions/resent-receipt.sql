-- =====================================================================
-- Assertion for migration 203 (a receipt sent again in another photo is the same payment). Self-reverting: one DO
-- block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/remesa-closing-and-cash.md (C). Production, Bruce 2026-10-02: his 29,000 GYD receipt (read 14:16 on
-- 2026-10-02, ref 20402130026768, verified) was sent again in another photo, read as 28,000 GYD, ref 20321203276682,
-- date 2023-10-02 14:16 (year misread). The image hash differed, so it opened a second remesa (incident, sin_correo).
-- cerebro_comprobante_reenviado(phone, date, amount, ref) returns the original's comp_id when the same customer has a
-- receipt in the last 48 h with the same month-day hour:minute (any year) and an amount within 10%.
-- =====================================================================
DO $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_phone text := '5990020301';
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, v_phone, 'test203') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 29000) RETURNING id INTO v_op;
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, receipt_status, reference, receipt_date, source)
  VALUES (v_op, v_conv, 'COMP-test203orig', 29000, 'GYD', 'EXITOSA', '20402130026768', '2026-10-02 14:16', 'bot');

  -- 1. Bruce's resend: same month-day hour:minute, year misread, amount 28,000 (within 10%), another reference.
  IF cerebro_comprobante_reenviado(v_phone, '2023-10-02 14:16', 28000, '20321203276682') IS DISTINCT FROM 'COMP-test203orig' THEN
    RAISE EXCEPTION 'case 1: Bruce''s resend must be recognised, got %', cerebro_comprobante_reenviado(v_phone, '2023-10-02 14:16', 28000, '20321203276682'); END IF;
  -- the phone may come with +, spaces or the country code as WhatsApp sends it
  IF cerebro_comprobante_reenviado('+' || v_phone, '2026-10-02 14:16', 29000, NULL) IS DISTINCT FROM 'COMP-test203orig' THEN
    RAISE EXCEPTION 'case 1: the phone format must not matter'; END IF;

  -- 2. Another minute, another payment.
  IF cerebro_comprobante_reenviado(v_phone, '2026-10-02 14:17', 29000, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'case 2: a different minute is a different payment'; END IF;
  -- 3. Same minute but a clearly different amount: a different payment.
  IF cerebro_comprobante_reenviado(v_phone, '2026-10-02 14:16', 10000, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'case 3: a clearly different amount is a different payment'; END IF;
  -- 4. Another customer: never matched.
  IF cerebro_comprobante_reenviado('5990020399', '2026-10-02 14:16', 29000, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'case 4: another customer must not match'; END IF;
  -- 5. No date read: nothing to compare.
  IF cerebro_comprobante_reenviado(v_phone, NULL, 29000, NULL) IS NOT NULL OR cerebro_comprobante_reenviado(v_phone, '', 29000, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'case 5: no date, no match'; END IF;
  -- 6. A cancelled (deleted) operation's receipt does not count.
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
  IF cerebro_comprobante_reenviado(v_phone, '2023-10-02 14:16', 28000, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'case 6: a deleted remesa''s receipt must not count'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
