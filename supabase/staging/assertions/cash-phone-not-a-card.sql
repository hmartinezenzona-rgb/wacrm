-- =====================================================================
-- Assertion for migration 194 (a Cuban phone sent during a cash delivery is the cash recipient's phone, not a card
-- beneficiary). Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging and production.
--
-- odd/tasks/remesa-closing-and-cash.md (P1 finding, owner test 2026-10-03 18:23 UTC): the customer of a cash delivery
-- sent the phone alone ("53871234"); cerebro_guardar_beneficiario_auto saved it as a cuban_card beneficiary with no card
-- (a second vigente row, so the remesa read incomplete) and told the agent "FALTA: la tarjeta. Pideselo al cliente."
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_r record; v_n int;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990019401', 'test194') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0, 'efectivo_usd') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, address, position, block_index, source, status)
  VALUES (v_op, 'efectivo_usd', 'Marlene', 'Calle 45', 1, 1, 'reparto_auto', 'vigente');

  -- 1. The phone alone, in a cash delivery: stored on the cash recipient, no card row, no "FALTA: la tarjeta".
  SELECT * INTO v_r FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53871234', '', '53871234', 'test194');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: exactly one vigente beneficiary expected, got %', v_n; END IF;
  IF (SELECT beneficiary_type || ' ' || coalesce(phone, '-') || ' ' || coalesce(name, '-') FROM remittance_beneficiaries
       WHERE operation_id = v_op AND status = 'vigente') IS DISTINCT FROM 'efectivo_usd 53871234 Marlene' THEN
    RAISE EXCEPTION 'case 1: the phone must land on the cash recipient (keeping the name)'; END IF;
  IF v_r.accion ILIKE '%tarjeta%' THEN RAISE EXCEPTION 'case 1: must not ask for a card, said: %', v_r.accion; END IF;
  IF v_r.accion NOT ILIKE '%efectivo%' THEN RAISE EXCEPTION 'case 1: must say it was saved for the cash delivery, said: %', v_r.accion; END IF;

  -- 2. A card remesa is unchanged: the phone alone still waits for its card.
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0, 'cuban_card') RETURNING id INTO v_op;
  SELECT * INTO v_r FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53871234', '', '53871234', 'test194b');
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'cuban_card'
        AND phone = '53871234') <> 1 OR v_r.accion NOT ILIKE '%tarjeta%' THEN
    RAISE EXCEPTION 'case 2: a card remesa must keep saving the phone and asking for the card, said: %', v_r.accion; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
