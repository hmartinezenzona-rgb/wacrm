\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 225 (crm_agregar_beneficiario accepts a cash USD recipient from the panel).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection
-- closes, so nothing is kept). Each passing case NOTICEs.
-- Owner, staging 2026-10-07: with the service set to cash USD the panel offered no way to add the recipient. Only the
-- bot wrote that row (crm_registrar_datos_entrega_efectivo: name, phone, address, ID-card photo wamid).
-- Model asserted (taken from 150/188/191 and crm_beneficiarios_completos):
--   * the cash recipient row: beneficiary_type efectivo_usd, name (optional), phone (required, normalised like a combo
--     phone), address (required), no card / zelle account / delivery method; the ID-card photo comes from the chat, so a
--     panel-added recipient stays incomplete until the photo arrives;
--   * the amount is NOT asked for: the existing calculation prices a lone recipient (floor(deposit / cash rate) USD);
--   * one cash recipient per operation, only on an operation whose rail is cash (or has no rail yet);
--   * same lock + one audit row as the other added recipients; closed / non-member refused; nothing is sent.
-- Rates are read from the database, so the expectations follow staging's rates.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t225_op(p_user uuid, p_acc uuid, p_phone text, p_service text, p_dm text, p_amount numeric,
                                p_status text DEFAULT 'collecting_information', p_locks jsonb DEFAULT '{}'::jsonb) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (p_user, p_acc, p_phone, 'test225') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (p_user, p_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency,
                                     quoted_source_amount, admin_locked_fields)
  VALUES (p_acc, v_conv, v_ct, 'collecting_information', p_service, p_dm, 'GYD', p_amount, p_locks)
  RETURNING id INTO v_op;
  IF p_status <> 'collecting_information' THEN
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = p_status WHERE id = v_op;
    PERFORM set_config('wacrm.origin', '', true);
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t225_add(p_op uuid, p_datos jsonb, p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  v_r := crm_agregar_beneficiario(p_op, p_datos);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.t225_try(p_op uuid, p_datos jsonb, p_uid uuid) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t225_add(p_op, p_datos, p_uid);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.t225_svc(p_op uuid, p_svc text, p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  v_r := crm_cambiar_servicio(p_op, p_svc);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.t225_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990225%')
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990225%')
       + (SELECT count(*) FROM net.http_request_queue);
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_rate numeric := crm_tasa_vigente('efectivo');
  v_min numeric := cerebro_minimo_efectivo_gyd();
  v_dep numeric;
  v_amt numeric;
  v_stranger uuid := gen_random_uuid();
  v_card constant text := '9760039001240356';
  v_op uuid; v_op2 uuid; v_r jsonb; v_o remittance_operations%ROWTYPE; v_b remittance_beneficiaries%ROWTYPE;
  v_n int; v_base bigint; v_closed1 uuid; v_closed2 uuid;
BEGIN
  IF NOT (v_rate > 0 AND v_min > 0) THEN RAISE EXCEPTION 'setup: the cash rate and minimum are needed (%, %)', v_rate, v_min; END IF;
  -- above the cash minimum, and not a whole number of dollars so the rounding down is exercised
  v_dep := ceil(v_min / 1000) * 1000 + 1000;
  v_amt := floor(v_dep / v_rate);
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  v_closed1 := pg_temp.t225_op(v_user, v_acc, '59902250090', 'remesa', 'efectivo_usd', v_dep, 'completed');
  v_closed2 := pg_temp.t225_op(v_user, v_acc, '59902250091', 'remesa', 'efectivo_usd', v_dep, 'cancelled');
  v_base := pg_temp.t225_side();

  -- ---- a. a CUP remesa becomes cash (its card is retired) and gets its cash recipient ----
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250001', 'remesa', 'cuban_card', v_dep);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', v_card, '58528291', 1, 1, 'notes_parse', 'vigente');
  PERFORM pg_temp.t225_svc(v_op, 'efectivo_usd', v_user);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 0 THEN
    RAISE EXCEPTION 'setup a: the card must be retired when the service becomes cash'; END IF;

  v_r := pg_temp.t225_add(v_op, jsonb_build_object('beneficiary_type', 'efectivo_usd', 'name', '  Maria Perez ',
                          'phone', '+53 5212 3456', 'address', ' Calle 1 #23, Plaza, La Habana '), v_user);
  SELECT * INTO v_b FROM remittance_beneficiaries WHERE id = (v_r ->> 'id')::uuid;
  IF v_b.beneficiary_type <> 'efectivo_usd' OR v_b.status <> 'vigente' OR v_b.operation_id <> v_op OR v_b.source <> 'admin_addition'
     OR v_b.name IS DISTINCT FROM 'Maria Perez' OR v_b.phone IS DISTINCT FROM '52123456'
     OR v_b.address IS DISTINCT FROM 'Calle 1 #23, Plaza, La Habana' OR v_b.id_photo_wamid IS NOT NULL
     OR v_b.card_number IS NOT NULL OR v_b.zelle_account IS NOT NULL OR v_b.position <> 1 THEN
    RAISE EXCEPTION 'case a1: unexpected cash recipient row %', to_jsonb(v_b); END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_b.amount IS DISTINCT FROM v_amt OR v_b.currency IS DISTINCT FROM 'USD' OR v_b.amount_origin IS DISTINCT FROM 'calculated' THEN
    RAISE EXCEPTION 'case a2: the cash amount must be floor(% / %) = % USD calculated, got % % %', v_dep, v_rate, v_amt, v_b.amount, v_b.currency, v_b.amount_origin; END IF;
  IF v_o.quoted_destination_amount IS DISTINCT FROM v_b.amount OR v_o.destination_currency IS DISTINCT FROM 'USD'
     OR v_o.quoted_destination_origin IS DISTINCT FROM 'calculated' OR v_o.quoted_destination_rate IS DISTINCT FROM v_rate THEN
    RAISE EXCEPTION 'case a2: the operation quote must equal the recipient amount, got % / % / % / %',
      v_o.quoted_destination_amount, v_o.destination_currency, v_o.quoted_destination_origin, v_o.quoted_destination_rate; END IF;
  IF (v_r ->> 'complete') <> 'false' THEN RAISE EXCEPTION 'case a3: without the ID photo the recipient is not complete (188), got %', v_r; END IF;
  IF NOT (v_o.admin_locked_fields ? 'beneficiaries') OR (v_o.admin_locked_fields ? 'quoted_destination_amount')
     OR (v_o.admin_locked_fields ? 'destination_currency') THEN
    RAISE EXCEPTION 'case a4: the recipients must be locked and the calculated quote must not be, got %', v_o.admin_locked_fields; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_b.id AND action = 'human_beneficiary_added';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case a5: expected one human_beneficiary_added audit row, got %', v_n; END IF;
  IF v_o.status <> 'collecting_information' THEN RAISE EXCEPTION 'case a6: the status must not change'; END IF;
  -- the customer's ID photo arrives later through the bot's writer: the recipient becomes complete
  UPDATE remittance_beneficiaries SET id_photo_wamid = 'wamid.test225' WHERE id = v_b.id;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case a7: phone + address + ID photo is a complete cash recipient'; END IF;
  RAISE NOTICE 'PASS a: cash recipient added (% USD calculated = operation quote), incomplete until the photo, locked, audited', v_amt;

  -- ---- b. required fields and formats ----
  v_op2 := pg_temp.t225_op(v_user, v_acc, '59902250002', 'remesa', 'efectivo_usd', v_dep);
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","address":"Calle 1, La Habana"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b1: the phone is required'; END IF;
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"52123456"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b2: the address is required'; END IF;
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"   "}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b2: a blank address is refused'; END IF;
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"123","address":"Calle 1, La Habana"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b3: an invalid phone is refused'; END IF;
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"abcdefgh","address":"Calle 1, La Habana"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b3: a non-numeric phone is refused'; END IF;
  -- the amount, currency and card / zelle data are not the cash recipient's to give
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1","amount":50,"currency":"USD"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b4: amount and currency are calculated, not given'; END IF;
  IF pg_temp.t225_try(v_op2, jsonb_build_object('beneficiary_type', 'efectivo_usd', 'phone', '52123456', 'address', 'Calle 1', 'card_number', v_card), v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b4: a card number is not a cash field'; END IF;
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1","bogus":"x"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case b4: unknown fields are refused'; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op2) <> 0 THEN
    RAISE EXCEPTION 'case b: a refused add must write nothing'; END IF;
  -- the name is optional (191)
  v_r := pg_temp.t225_add(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1, La Habana"}'::jsonb, v_user);
  SELECT * INTO v_b FROM remittance_beneficiaries WHERE id = (v_r ->> 'id')::uuid;
  IF v_b.name IS NOT NULL OR v_b.amount IS DISTINCT FROM v_amt THEN RAISE EXCEPTION 'case b5: a nameless cash recipient is valid and priced, got % %', v_b.name, v_b.amount; END IF;
  RAISE NOTICE 'PASS b: phone and address required, phone validated, amount/currency/card not accepted, name optional';

  -- ---- c. one cash recipient per operation ----
  IF pg_temp.t225_try(v_op2, '{"beneficiary_type":"efectivo_usd","phone":"52123457","address":"Calle 2, La Habana"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case c: a second cash recipient must be refused (the bot keeps one)'; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op2 AND status = 'vigente') <> 1 THEN
    RAISE EXCEPTION 'case c: still one recipient'; END IF;
  RAISE NOTICE 'PASS c: a second cash recipient is refused';

  -- ---- d. the rail: cash needs a cash operation (or one with no rail yet) ----
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250003', 'remesa', 'zelle', v_dep);
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case d1: a cash recipient on a zelle operation must be refused'; END IF;
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250004', 'combo', NULL, 25000);
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case d2: a cash recipient on a combo must be refused'; END IF;
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250005', 'recarga', NULL, 5200);
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case d3: a cash recipient on a recharge must be refused'; END IF;
  -- no rail yet: allowed; the calculation prices the operation and the lone recipient, and its writes stay unlocked
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250006', 'remesa', NULL, v_dep);
  IF (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op) IS NOT NULL THEN
    RAISE EXCEPTION 'setup d4: an operation with no rail has no quote yet'; END IF;
  v_r := pg_temp.t225_add(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1, La Habana"}'::jsonb, v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  SELECT * INTO v_b FROM remittance_beneficiaries WHERE id = (v_r ->> 'id')::uuid;
  IF v_b.amount IS DISTINCT FROM v_amt OR v_b.currency IS DISTINCT FROM 'USD'
     OR v_o.quoted_destination_amount IS DISTINCT FROM v_amt OR v_o.destination_currency IS DISTINCT FROM 'USD'
     OR v_o.quoted_destination_origin IS DISTINCT FROM 'calculated' THEN
    RAISE EXCEPTION 'case d4: the first cash recipient must price a rail-less operation (% % / % %)', v_b.amount, v_b.currency, v_o.quoted_destination_amount, v_o.destination_currency; END IF;
  IF (v_o.admin_locked_fields ? 'quoted_destination_amount') OR (v_o.admin_locked_fields ? 'destination_currency') THEN
    RAISE EXCEPTION 'case d4: the calculated quote must not be locked, got %', v_o.admin_locked_fields; END IF;
  -- an operation whose recipients were locked by an earlier correction: the recipient still takes the quote
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250007', 'remesa', 'efectivo_usd', v_dep,
                          'collecting_information', '{"beneficiaries":{"by":"x","at":"2026-10-01T00:00:00Z"}}'::jsonb);
  v_r := pg_temp.t225_add(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1, La Habana"}'::jsonb, v_user);
  SELECT * INTO v_b FROM remittance_beneficiaries WHERE id = (v_r ->> 'id')::uuid;
  IF v_b.amount IS DISTINCT FROM v_amt OR v_b.currency IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case d5: a locked operation must still price the recipient, got % %', v_b.amount, v_b.currency; END IF;
  RAISE NOTICE 'PASS d: cash refused on zelle / combo / recarga, allowed with no rail yet, priced in every lock state';

  -- ---- e. the other recipient types are unchanged ----
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250008', 'remesa', 'cuban_card', 5200);
  v_r := pg_temp.t225_add(v_op, jsonb_build_object('beneficiary_type', 'cuban_card', 'card_number', v_card, 'phone', '58528291',
                          'amount', 100, 'currency', 'CUP'), v_user);
  IF NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE id = (v_r ->> 'id')::uuid AND beneficiary_type = 'cuban_card' AND amount = 100 AND currency = 'CUP') THEN
    RAISE EXCEPTION 'case e1: a card recipient must still be added as before'; END IF;
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"cuban_card","card_number":"9760039001240356","amount":100,"currency":"CUP","address":"x"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case e2: address is still refused for a card recipient'; END IF;
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"cuban_card","amount":100,"currency":"CUP"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case e3: a card recipient still needs its card'; END IF;
  RAISE NOTICE 'PASS e: card recipients unchanged';

  -- ---- f. refusals ----
  v_op := pg_temp.t225_op(v_user, v_acc, '59902250009', 'remesa', 'efectivo_usd', v_dep);
  IF pg_temp.t225_try(v_closed1, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case f: a completed operation must be refused'; END IF;
  IF pg_temp.t225_try(v_closed2, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, v_user) <> '22023' THEN
    RAISE EXCEPTION 'case f: a cancelled operation must be refused'; END IF;
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, v_stranger) <> '42501' THEN
    RAISE EXCEPTION 'case f: a non-member must be refused'; END IF;
  IF pg_temp.t225_try(v_op, '{"beneficiary_type":"efectivo_usd","phone":"52123456","address":"Calle 1"}'::jsonb, NULL) <> '42501' THEN
    RAISE EXCEPTION 'case f: an unauthenticated call must be refused'; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id IN (v_op, v_closed1, v_closed2)) <> 0 THEN
    RAISE EXCEPTION 'case f: refused adds must write nothing'; END IF;
  RAISE NOTICE 'PASS f: closed, non-member and unauthenticated are refused';

  -- ---- g. nothing was sent ----
  IF pg_temp.t225_side() <> v_base THEN
    RAISE EXCEPTION 'case g: messages/outbox/net queue grew from % to %', v_base, pg_temp.t225_side(); END IF;
  RAISE NOTICE 'PASS g: no messages, outbox rows or http requests';

  RAISE NOTICE 'ALL PASS (cash-recipient-add)';
END $$;

ROLLBACK;
