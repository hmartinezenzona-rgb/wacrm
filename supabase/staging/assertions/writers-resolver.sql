\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 268 (the recharge-number writers take the service from facts and the agent's declaration).
-- Self-reverting: BEGIN ... ROLLBACK is in this file. Each case runs in its own sub-block and counts its failures
-- (WARNING "FAIL [case n] ..."); the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)' when none failed.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT) or by hand as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Prerequisites: 265 (cerebro_resolver_servicio, cerebro_declarar_servicio), 266 (cerebro_aplicar_servicio),
-- 267 (cerebro_registrar_deposito). Money cases carry REAL deposits (remittance_operation_receipts rows).
-- Synthetic fixtures only: contacts 'PRUEBA writers N' with phones 5990268xxxx; fake mobiles 55501268 and 55599180.
-- odd/tasks/service-resolution.md (REDESIGN 2026-10-22; S3 part 3 lessons).
-- Cases (number = label in the failure message):
--   1  every accepted Cuban mobile format registers exactly one number 55599180 on an open recharge; 7-digit,
--      9-digit and runs not starting with 5/6 register none
--   2  Katiuska 14:32: a remesa holding a real 6,200 deposit with a phone-only recipient; crm(conv,'55599180',true,
--      'agent:registrar_numeros_recarga') converts the holder to the recharge, keeps both numbers, creates no second
--      operation, and the audit actor is the agent
--   3  no operation at all, promo live, p_abrir true -> a new recharge with the number
--   4  no promo running or ahead -> nothing is created, the promo message is returned
--   5  a remesa holding a real 5,000 deposit + crm(p_abrir) -> no second operation, the holder stays a remesa, and the
--      returned text carries the minimum 6,200 and the shortfall 1,200 (the resolver's mensaje)
--   6  a mixed group (two linked operations) + crm(p_abrir) -> still 2 operations, the mixed-group message
--   7a guardar_beneficiario_auto with the words "quiero una recarga", no declaration, no operation -> nothing is opened
--   7b same words, no declaration, a remesa holding 6,200 -> still no recharge operation (words never decide)
--   8  declared recarga (cerebro_declarar_servicio) + a remesa holding 6,200 + guardar_beneficiario_auto with a Cuban
--      number -> the holder becomes the recharge with the number; no duplicate operation
--   9  declared recarga, no operation -> the number opens the recharge (collecting); no remesa is created from words
-- =====================================================================

CREATE FUNCTION pg_temp.w_conv(p_n int) RETURNS TABLE(acc uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990268' || lpad(p_n::text, 4, '0'), 'PRUEBA writers ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_ct, v_cv;
END $f$;

-- A customer text written p_ago minutes ago.
CREATE FUNCTION pg_temp.w_msg(p_conv uuid, p_txt text, p_ago int) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_txt, clock_timestamp() - make_interval(mins => p_ago));
$f$;

-- An open operation written p_ago minutes ago, holding p_amt GYD; p_receipt = a real deposit (receipt row) of p_amt.
CREATE FUNCTION pg_temp.w_op(p_acc uuid, p_ct uuid, p_conv uuid, p_status text, p_svc text, p_amt numeric, p_ago int,
                             p_receipt boolean DEFAULT false) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_acc, p_conv, p_ct, p_status, p_svc, 'GYD', p_amt,
          clock_timestamp() - make_interval(mins => p_ago))
  RETURNING id INTO v_op;
  IF p_receipt THEN
    INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, source)
    VALUES (v_op, p_conv, 'R268-' || substr(v_op::text, 1, 8), p_amt, 'GYD', 'bot');
  END IF;
  RETURN v_op;
END $f$;

-- A phone-only recipient (no card, no Zelle) of an operation, as a vigente row.
CREATE FUNCTION pg_temp.w_ben(p_op uuid, p_type text, p_card text, p_phone text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (p_op, p_type, p_card, p_phone, 1, 1, 'test268', 'vigente');
$f$;

-- 'service/status/amount' of every operation of the conversation, oldest first; '' when there is none.
CREATE FUNCTION pg_temp.w_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';'
                             ORDER BY o.created_at, o.id), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$f$;

-- The vigente phones of the conversation's recharge recipients, sorted; '' when there are none.
CREATE FUNCTION pg_temp.w_nums(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(b.phone, ',' ORDER BY b.phone), '')
    FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
   WHERE o.conversation_id = p_conv AND b.status = 'vigente' AND b.beneficiary_type = 'recarga';
$f$;

-- How many operations of the conversation are of the given service.
CREATE FUNCTION pg_temp.w_n(p_conv uuid, p_svc text) RETURNS text
LANGUAGE sql AS $f$
  SELECT count(*)::text FROM remittance_operations WHERE conversation_id = p_conv AND service_type = p_svc;
$f$;

CREATE FUNCTION pg_temp.w_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'expected [%], got [%]', p_exp, p_got USING ERRCODE = 'P0001'; END IF;
END $f$;

DO $$
DECLARE
  c        record;
  v_op     uuid;
  v_dup    uuid;
  v_r      text;
  v_fails  int := 0;
  v_fmts   text[] := ARRAY['55599180', '5559 9180', '5559-9180', '+53 55599180', '+5355599180',
                           '+53 5 5599180', '53 5 5599180', '+53 5 559 9180'];
  v_bad    text[] := ARRAY['5559918', '555991801', '45599180'];
  i        int;
BEGIN
  -- ---- 4. no promo running or ahead: nothing is created. Runs first, before any promo exists. ----------------------
  BEGIN
    UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
    SELECT * INTO c FROM pg_temp.w_conv(4);
    v_r := crm_registrar_numeros_recarga(c.conv, '55599180', true);
    PERFORM pg_temp.w_eq('4 operations', pg_temp.w_ops(c.conv), '');
    PERFORM pg_temp.w_eq('4 numbers', pg_temp.w_nums(c.conv), '');
    PERFORM pg_temp.w_eq('4 says no promo', (v_r LIKE '%NO HAY PROMOCION%')::text, 'true');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 4] %', SQLERRM;
  END;

  -- A promo running whose recharge price is 6,200 (min_cup 600), for the cases below.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT 268', 'https://assert.invalid/268', 'assert', md5('assert-268-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- ---- 1. every accepted format registers one number; the rejected runs register none ---------------------------------
  FOR i IN 1..array_length(v_fmts, 1) LOOP
    BEGIN
      SELECT * INTO c FROM pg_temp.w_conv(100 + i);
      v_op := pg_temp.w_op(c.acc, c.contact, c.conv, 'collecting_information', 'recarga', 0, 20);
      v_r := crm_registrar_numeros_recarga(c.conv, v_fmts[i]);
      PERFORM pg_temp.w_eq('1 format [' || v_fmts[i] || ']', pg_temp.w_nums(c.conv), '55599180');
    EXCEPTION WHEN OTHERS THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] format [%]: %', v_fmts[i], SQLERRM;
    END;
  END LOOP;
  FOR i IN 1..array_length(v_bad, 1) LOOP
    BEGIN
      SELECT * INTO c FROM pg_temp.w_conv(200 + i);
      v_op := pg_temp.w_op(c.acc, c.contact, c.conv, 'collecting_information', 'recarga', 0, 20);
      v_r := crm_registrar_numeros_recarga(c.conv, v_bad[i]);
      PERFORM pg_temp.w_eq('1 rejected [' || v_bad[i] || ']', pg_temp.w_nums(c.conv), '');
    EXCEPTION WHEN OTHERS THEN
      v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] rejected [%]: %', v_bad[i], SQLERRM;
    END;
  END LOOP;

  -- ---- 2. Katiuska 14:32: the remesa holder (real 6,200 deposit) becomes the recharge; no second operation ----------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(2);
    v_op := pg_temp.w_op(c.acc, c.contact, c.conv, 'deposit_verification', 'remesa', 6200, 20, true);
    PERFORM pg_temp.w_ben(v_op, 'cuban_card', NULL, '55501268');
    PERFORM pg_temp.w_msg(c.conv, 'es para una recarga', 5);
    v_r := crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
    PERFORM pg_temp.w_eq('2 operations', pg_temp.w_ops(c.conv), 'recarga/deposit_verification/6200');
    PERFORM pg_temp.w_eq('2 numbers', pg_temp.w_nums(c.conv), '55501268,55599180');
    PERFORM pg_temp.w_eq('2 audit actor is the agent', (SELECT (count(*) > 0)::text FROM remittance_admin_audit
                                                         WHERE row_id = v_op AND actor = 'agent:registrar_numeros_recarga'), 'true');
    PERFORM pg_temp.w_eq('2 no automation audit actor', (SELECT count(*)::text FROM remittance_admin_audit
                                                          WHERE row_id = v_op AND actor LIKE 'automation%'), '0');
    PERFORM pg_temp.w_eq('2 agent recipient source', (SELECT count(*)::text FROM remittance_beneficiaries
                                                       WHERE operation_id = v_op AND phone = '55599180' AND source = 'agente'), '1');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] %', SQLERRM;
  END;

  -- ---- 3. no operation at all, promo live, p_abrir true: a new recharge is created ---------------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(3);
    v_r := crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
    PERFORM pg_temp.w_eq('3 operations', pg_temp.w_ops(c.conv), 'recarga/collecting_information/6200');
    PERFORM pg_temp.w_eq('3 numbers', pg_temp.w_nums(c.conv), '55599180');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 3] %', SQLERRM;
  END;

  -- ---- 5. remesa holder with a real 5,000 deposit: no second operation, the resolver's minimum and shortfall ----------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(5);
    v_op := pg_temp.w_op(c.acc, c.contact, c.conv, 'deposit_verification', 'remesa', 5000, 20, true);
    PERFORM pg_temp.w_msg(c.conv, 'es para una recarga', 5);
    v_r := crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
    PERFORM pg_temp.w_eq('5 operations', pg_temp.w_ops(c.conv), 'remesa/deposit_verification/5000');
    PERFORM pg_temp.w_eq('5 numbers', pg_temp.w_nums(c.conv), '');
    PERFORM pg_temp.w_eq('5 minimum in text', (v_r LIKE '%6,200%')::text, 'true');
    PERFORM pg_temp.w_eq('5 shortfall in text', (v_r LIKE '%1,200%')::text, 'true');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] %', SQLERRM;
  END;

  -- ---- 6. a mixed group (two linked operations): still two operations, the mixed-group message -----------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(6);
    v_op  := pg_temp.w_op(c.acc, c.contact, c.conv, 'deposit_verification', 'remesa', 6200, 20, true);
    v_dup := pg_temp.w_op(c.acc, c.contact, c.conv, 'deposit_verification', 'remesa', 5000, 20, true);
    UPDATE remittance_operations SET mixed_group_id = v_op WHERE id IN (v_op, v_dup);
    v_r := crm_registrar_numeros_recarga(c.conv, '55599180', true, 'agent:registrar_numeros_recarga');
    PERFORM pg_temp.w_eq('6 operations', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '2');
    PERFORM pg_temp.w_eq('6 no recharge', pg_temp.w_n(c.conv, 'recarga'), '0');
    PERFORM pg_temp.w_eq('6 mixed message', (v_r LIKE '%envío mixto%')::text, 'true');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 6] %', SQLERRM;
  END;

  -- ---- 7a. guardar_beneficiario_auto: the words "quiero una recarga" open nothing (no declaration, no operation) -----
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(70);
    PERFORM pg_temp.w_msg(c.conv, 'quiero una recarga', 5);
    PERFORM cerebro_guardar_beneficiario_auto(c.conv, '', '55599180', '', '', 'exec268-case7a');
    PERFORM pg_temp.w_eq('7a operations', pg_temp.w_ops(c.conv), '');
    PERFORM pg_temp.w_eq('7a numbers', pg_temp.w_nums(c.conv), '');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 7a] %', SQLERRM;
  END;

  -- ---- 7b. same words, no declaration, a remesa holding 6,200: the words open no recharge -------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(71);
    v_op := pg_temp.w_op(c.acc, c.contact, c.conv, 'deposit_verification', 'remesa', 6200, 20, true);
    PERFORM pg_temp.w_msg(c.conv, 'quiero una recarga', 5);
    PERFORM cerebro_guardar_beneficiario_auto(c.conv, '', '55599180', '', '', 'exec268-case7b');
    PERFORM pg_temp.w_eq('7b no recharge', pg_temp.w_n(c.conv, 'recarga'), '0');
    PERFORM pg_temp.w_eq('7b one operation', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '1');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 7b] %', SQLERRM;
  END;

  -- ---- 8. declared recarga + remesa holder (6,200 real) + a Cuban number: the holder becomes the recharge -----------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(8);
    PERFORM cerebro_declarar_servicio(c.conv, 'recarga', 'agent:registrar_numeros_recarga');
    v_op := pg_temp.w_op(c.acc, c.contact, c.conv, 'deposit_verification', 'remesa', 6200, 20, true);
    PERFORM pg_temp.w_msg(c.conv, 'es para una recarga', 5);
    PERFORM cerebro_guardar_beneficiario_auto(c.conv, '', '55599180', '', '', 'exec268-case8');
    PERFORM pg_temp.w_eq('8 operations', pg_temp.w_ops(c.conv), 'recarga/deposit_verification/6200');
    PERFORM pg_temp.w_eq('8 numbers', pg_temp.w_nums(c.conv), '55599180');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 8] %', SQLERRM;
  END;

  -- ---- 9. declared recarga, no operation: the number opens the recharge; no remesa is created from words -------------
  BEGIN
    SELECT * INTO c FROM pg_temp.w_conv(9);
    PERFORM cerebro_declarar_servicio(c.conv, 'recarga', 'agent:registrar_numeros_recarga');
    PERFORM pg_temp.w_msg(c.conv, 'quiero una recarga', 5);
    PERFORM cerebro_guardar_beneficiario_auto(c.conv, '', '55599180', '', '', 'exec268-case9');
    PERFORM pg_temp.w_eq('9 operations', pg_temp.w_ops(c.conv), 'recarga/collecting_information/6200');
    PERFORM pg_temp.w_eq('9 numbers', pg_temp.w_nums(c.conv), '55599180');
    PERFORM pg_temp.w_eq('9 no remesa', pg_temp.w_n(c.conv, 'remesa'), '0');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 9] %', SQLERRM;
  END;

  IF v_fails > 0 THEN
    RAISE EXCEPTION 'writers-resolver: % case(s) FAILED (see WARNING lines above)', v_fails;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
