-- =====================================================================
-- Assertion for migration 366 (part 2): a reparto collapsed to one card leaves no empty recipient.
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'; any failure RAISEs its own message.
-- Real case (operation af44d909, 2026-11-12): two recipients x 18,000 CUP; the customer says "todo en la misma tarjeta"
-- and the bot calls the tool with ONLY person 1 = 36,000 CUP: person 2 (18,000, no card) was carried over, then a call
-- with person 2 = "0 CUP" wrote a recipient with amount 0, no card and no phone.
-- Kept behavior: the call patches by position (what is not sent is kept), so a later call that only completes person 2
-- (or only patches one field) still works.
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.fx(p_tag text, p_status text, p_base numeric, OUT o_conv uuid, OUT o_op uuid) LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900366' || p_tag, 'PRUEBA 366' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO o_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, o_conv, v_ct, p_status, 'remesa', 'GYD', p_base) RETURNING id INTO o_op;
END $$;

-- The tool call: three slots (card, amount); each card comes with a phone.
CREATE OR REPLACE FUNCTION pg_temp.rp(p_conv uuid, p_op uuid, p_t1 text, p_m1 text, p_t2 text, p_m2 text, p_t3 text DEFAULT '', p_m3 text DEFAULT '')
RETURNS text LANGUAGE sql AS $$
  SELECT accion FROM cerebro_guardar_reparto(p_conv, p_t1, CASE WHEN p_t1 <> '' THEN '53821201' ELSE '' END, p_m1,
                                              p_t2, CASE WHEN p_t2 <> '' THEN '53821202' ELSE '' END, p_m2,
                                              p_t3, CASE WHEN p_t3 <> '' THEN '53821203' ELSE '' END, p_m3, 'x' || gen_random_uuid()::text, p_op)
$$;

CREATE OR REPLACE FUNCTION pg_temp.slots(p_op uuid) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(b.position || '=' || coalesce(b.card_number, '_') || ':' || coalesce(b.phone, '_') || ':'
                             || coalesce(b.amount::text, '_') || b.currency, ' | ' ORDER BY b.position), '')
    FROM remittance_beneficiaries b WHERE b.operation_id = p_op AND b.status = 'vigente'
$$;

DO $$
DECLARE
  c1 constant text := '9238123432101987';
  c2 constant text := '9238123432101237';
  c3 constant text := '9205129978614908';
  v_conv uuid; v_op uuid; v_r text;
BEGIN
  -- 1. Real case: person 1 with card 18,000 and person 2 18,000 without card, then ONLY person 1 with 36,000.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('01', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', '', '18000');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:18000CUP | 2=_:_:18000CUP' THEN RAISE EXCEPTION 'case 1 setup: %', pg_temp.slots(v_op); END IF;
  PERFORM pg_temp.rp(v_conv, v_op, '', '36000', '', '');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:36000CUP' THEN RAISE EXCEPTION 'case 1: one recipient expected, got %', pg_temp.slots(v_op); END IF;
  RAISE NOTICE 'PASS 1: person 2 is not carried over';

  -- 2. Then the model also sends person 2 = "0 CUP": nothing is written for an empty person; nothing asked for.
  v_r := pg_temp.rp(v_conv, v_op, '', '36000', '', '0 CUP');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:36000CUP' THEN RAISE EXCEPTION 'case 2: zero person written, got %', pg_temp.slots(v_op); END IF;
  IF v_r LIKE '%FALTA%' THEN RAISE EXCEPTION 'case 2: must not ask for a second card/phone: %', v_r; END IF;
  RAISE NOTICE 'PASS 2: an amount-0 person without card or phone is never written';

  -- 3. One call: person 1 with the full amount and person 2 = 0 over a saved person 2 without card.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('03', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', '', '18000');
  v_r := pg_temp.rp(v_conv, v_op, c1, '36000', '', '0');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:36000CUP' THEN RAISE EXCEPTION 'case 3: %', pg_temp.slots(v_op); END IF;
  IF v_r NOT LIKE '%Completo.%' THEN RAISE EXCEPTION 'case 3: one complete recipient expected: %', v_r; END IF;
  RAISE NOTICE 'PASS 3: card + full amount + person 2 zero = one complete recipient';

  -- 3b. The collapsed person 2 HAD a card: sending only person 1 with the full amount still leaves one recipient.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('13', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '18000');
  PERFORM pg_temp.rp(v_conv, v_op, '', '36000', '', '');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:36000CUP' THEN RAISE EXCEPTION 'case 3b: %', pg_temp.slots(v_op); END IF;
  RAISE NOTICE 'PASS 3b: collapse also drops a person that had a card';

  -- 3c. Only person 2 is zeroed over a saved person 2 without card: person 1 stays untouched.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('23', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', '', '18000');
  PERFORM pg_temp.rp(v_conv, v_op, '', '', '', '0 CUP');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:18000CUP' THEN RAISE EXCEPTION 'case 3c: %', pg_temp.slots(v_op); END IF;
  RAISE NOTICE 'PASS 3c: zeroing a person without card removes only that person';

  -- 4. Kept: a raise of person 1 that does NOT cover the rest is a patch (person 2 stays).
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('04', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', c2, '18000');
  PERFORM pg_temp.rp(v_conv, v_op, '', '20000', '', '');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:20000CUP | 2=' || c2 || ':53821202:18000CUP' THEN RAISE EXCEPTION 'case 4: patch must keep person 2, got %', pg_temp.slots(v_op); END IF;
  RAISE NOTICE 'PASS 4: a partial change of one person keeps the other';

  -- 5. Kept: person 2 has an amount and no card yet; the card that arrives later patches person 2 and keeps person 1.
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('05', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '18000', '', '18000');
  PERFORM pg_temp.rp(v_conv, v_op, '', '', c2, '');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:18000CUP | 2=' || c2 || ':53821202:18000CUP' THEN
    RAISE EXCEPTION 'case 5: the late card of person 2 must patch it, got %', pg_temp.slots(v_op); END IF;
  RAISE NOTICE 'PASS 5: person 2 data that arrives later still completes the reparto';

  -- 6. Kept: a person with a card keeps being written even when its amount is not sent yet (3 persons, call touches only person 3).
  SELECT * INTO v_conv, v_op FROM pg_temp.fx('06', 'collecting_information', 10000);
  PERFORM pg_temp.rp(v_conv, v_op, c1, '12000', c2, '12000', c3, '');
  PERFORM pg_temp.rp(v_conv, v_op, '', '', '', '', '', '12000');
  IF pg_temp.slots(v_op) <> '1=' || c1 || ':53821201:12000CUP | 2=' || c2 || ':53821202:12000CUP | 3=' || c3 || ':53821203:12000CUP' THEN
    RAISE EXCEPTION 'case 6: three persons, got %', pg_temp.slots(v_op); END IF;
  RAISE NOTICE 'PASS 6: three-person reparto completes by position';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
