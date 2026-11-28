\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 267 (cerebro_registrar_deposito takes the service from facts: the open operation, the agent's
-- declared intent, Q1, else remesa; no customer words are read). Self-reverting: BEGIN ... ROLLBACK is in this file.
-- Each case runs in its own sub-block and counts its failures (WARNING "FAIL [case n] ..."); the DO block ends in
-- RAISE EXCEPTION 'ALL PASS (rolled back on purpose)' when none failed.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT) or by hand as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- Prerequisites: 265 (cerebro_resolver_servicio, cerebro_declarar_servicio) and 266 (cerebro_aplicar_servicio).
-- Synthetic fixtures only: contacts 'PRUEBA deposito N', phones 5990256xxxx, fake mobiles 55501xxx, a fake card, a fake
-- Zelle account, refs 10409990xxxxxx; no customer data. Each deposit carries a receipt note ('DEPOSITO ... Ref: ...' and a
-- COMP id), as the bot sends it, so the holder's money is visible to the resolver after the attach.
-- odd/tasks/service-resolution.md (REDESIGN 2026-10-22). The promo is live, recarga price 6,200 (min_cup 600).
-- Cases (number = label in the failure message):
--   1  no declaration, the customer TYPED the number, phone-only partial recipient, 6,200 -> one recarga operation in
--      deposit_verification; the number is a vigente 'recarga' recipient of it (Katiuska 14:30 shape)
--   2  the same with 5,000 (below the recarga price, not a whole promo price) -> a remesa
--   3  declared intent recarga + 6,200, NO words in the messages -> a recarga
--   4  no declaration, "quiero recargar" typed, 6,200, a card in the partial recipient -> a remesa (words are not read)
--   5  89f6df7e shape: no declaration, a Zelle account in the partial recipient, 83,200 -> a remesa, never a recarga
--   6a declared combo + 28,600 -> a combo;  6b declared visa + 6,200 -> a visa
--   7  an empty remesa holder (open, 0 GYD) + declared recarga + 6,200 -> the deposit lands on THAT operation, which ends
--      as a recarga (no second operation), converted by cerebro_aplicar_servicio (audit actor automation:registrar_deposito)
--   8  plain card remesa, no declaration, no words, 5,000 -> a remesa
--   9  an open recarga already in the conversation (no words, no declaration), 6,200 -> the deposit lands on it
-- =====================================================================

CREATE FUNCTION pg_temp.d_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990256' || lpad(p_n::text, 4, '0'), 'PRUEBA deposito ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- A customer text written p_ago minutes ago.
CREATE FUNCTION pg_temp.d_msg(p_conv uuid, p_txt text, p_ago int) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (p_conv, 'customer', 'text', p_txt, clock_timestamp() - make_interval(mins => p_ago));
$f$;

-- The conversation's partial recipient: a card, a mobile, a Zelle account (NULL when absent).
CREATE FUNCTION pg_temp.d_parcial(p_conv uuid, p_tarjeta text, p_celular text, p_zelle text) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta, celular, zelle_cuenta, actualizado)
  VALUES (p_conv, p_tarjeta, p_celular, p_zelle, clock_timestamp())
  ON CONFLICT (conversation_id) DO UPDATE SET tarjeta = EXCLUDED.tarjeta, celular = EXCLUDED.celular,
    zelle_cuenta = EXCLUDED.zelle_cuenta, actualizado = EXCLUDED.actualizado;
$f$;

-- An open operation written p_ago minutes ago (its messages must come after it), holding p_amt GYD.
CREATE FUNCTION pg_temp.d_op(p_c record, p_status text, p_svc text, p_amt numeric, p_ago int) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, p_status, p_svc, 'GYD', p_amt,
          clock_timestamp() - make_interval(mins => p_ago)) RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

-- A deposit registered the way the bot sends it: receipt note with the Ref and a COMP id.
CREATE FUNCTION pg_temp.d_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

-- 'service/status/amount' of every operation of the conversation, oldest first; '' when there is none.
CREATE FUNCTION pg_temp.d_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';'
                             ORDER BY o.created_at, o.id), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$f$;

CREATE FUNCTION pg_temp.d_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'expected [%], got [%]', p_exp, p_got USING ERRCODE = 'P0001'; END IF;
END $f$;

DO $$
DECLARE
  v_hoy   date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_stage constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';  -- Por verificar (deposit_verification)
  c       record;
  v_op    uuid;
  v_reg   record;
  v_fails int := 0;
  c_card  constant text := '9999000000000001';
BEGIN
  -- A promo running whose recarga price is 6,200 (min_cup 600); every other promo is out of the way.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 267', 'https://assert.invalid/267', 'assert', md5('assert-267-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- ---- 1. Katiuska shape: no declaration, the number typed, a phone-only recipient, 6,200 -------------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(1);
    -- As in production: the customer typed the number (the partial recipient was parsed from that message).
    PERFORM pg_temp.d_msg(c.conv, '55501001', 5);  -- the WhatsApp format '+53 5 5501001' is covered in 268 (number regex)
    PERFORM pg_temp.d_parcial(c.conv, NULL, '55501001', NULL);
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 6200, '10409990000101');
    PERFORM pg_temp.d_eq('1', pg_temp.d_ops(c.conv), 'recarga/deposit_verification/6200');
    -- Parent review: the operator needs the number; it must be a vigente recarga recipient of that operation.
    PERFORM pg_temp.d_eq('1 number kept', (SELECT string_agg(b.beneficiary_type || ':' || b.phone, ',')
                                              FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
                                             WHERE o.conversation_id = c.conv AND b.status = 'vigente'), 'recarga:55501001');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 1] %', SQLERRM;
  END;

  -- ---- 2. the same with 5,000 (below the recarga price, not a whole promo price): a remesa ---------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(2);
    PERFORM pg_temp.d_msg(c.conv, '55501002', 5);
    PERFORM pg_temp.d_parcial(c.conv, NULL, '55501002', NULL);
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 5000, '10409990000201');
    PERFORM pg_temp.d_eq('2', pg_temp.d_ops(c.conv), 'remesa/deposit_verification/5000');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 2] %', SQLERRM;
  END;

  -- ---- 3. declared intent recarga, 6,200, no words in any message: a recarga -----------------------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(3);
    PERFORM cerebro_declarar_servicio(c.conv, 'recarga', 'agent:test');
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 6200, '10409990000301');
    PERFORM pg_temp.d_eq('3', pg_temp.d_ops(c.conv), 'recarga/deposit_verification/6200');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 3] %', SQLERRM;
  END;

  -- ---- 4. "quiero recargar" typed, no declaration, 6,200, a card recipient: a remesa (words are not read) -------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(4);
    PERFORM pg_temp.d_msg(c.conv, 'hola, quiero recargar', 10);
    PERFORM pg_temp.d_parcial(c.conv, c_card, NULL, NULL);
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 6200, '10409990000401');
    PERFORM pg_temp.d_eq('4', pg_temp.d_ops(c.conv), 'remesa/deposit_verification/6200');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 4] %', SQLERRM;
  END;

  -- ---- 5. 89f6df7e shape: no declaration, a Zelle account, 83,200: a remesa, never a recarga -----------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(5);
    PERFORM pg_temp.d_msg(c.conv, 'tienen promo de recarga?', 30);
    PERFORM pg_temp.d_parcial(c.conv, NULL, NULL, 'prueba.zelle.256@example.invalid');
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 83200, '10409990000501');
    PERFORM pg_temp.d_eq('5', pg_temp.d_ops(c.conv), 'remesa/deposit_verification/83200');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 5] %', SQLERRM;
  END;

  -- ---- 6a. declared combo, 28,600: a combo -------------------------------------------------------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(6);
    PERFORM cerebro_declarar_servicio(c.conv, 'combo', 'agent:test');
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 28600, '10409990000601');
    PERFORM pg_temp.d_eq('6a', pg_temp.d_ops(c.conv), 'combo/deposit_verification/28600');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 6a] %', SQLERRM;
  END;

  -- ---- 6b. declared visa, 6,200: a visa ----------------------------------------------------------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(7);
    PERFORM cerebro_declarar_servicio(c.conv, 'visa', 'agent:test');
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 6200, '10409990000701');
    PERFORM pg_temp.d_eq('6b', pg_temp.d_ops(c.conv), 'visa/deposit_verification/6200');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 6b] %', SQLERRM;
  END;

  -- ---- 7. empty remesa holder + declared recarga + 6,200: the deposit lands on it and it ends as a recarga ----------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(8);
    v_op := pg_temp.d_op(c, 'collecting_information', 'remesa', 0, 20);
    PERFORM cerebro_declarar_servicio(c.conv, 'recarga', 'agent:test');
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 6200, '10409990000801');
    PERFORM pg_temp.d_eq('7 operations', pg_temp.d_ops(c.conv), 'recarga/deposit_verification/6200');
    PERFORM pg_temp.d_eq('7 holder', v_reg.deal_id::text, v_op::text);
    PERFORM pg_temp.d_eq('7 audit', (SELECT count(*)::text FROM remittance_admin_audit
                                      WHERE row_id = v_op AND field_name = 'service' AND action = 'automation_service_change'
                                        AND actor = 'automation:registrar_deposito'), '1');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 7] %', SQLERRM;
  END;

  -- ---- 8. plain card remesa (card data, no words, no declaration, 5,000): a remesa ------------------------------------
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(9);
    PERFORM pg_temp.d_parcial(c.conv, c_card, NULL, NULL);
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 5000, '10409990000901');
    PERFORM pg_temp.d_eq('8', pg_temp.d_ops(c.conv), 'remesa/deposit_verification/5000');
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 8] %', SQLERRM;
  END;

  -- ---- 9. an open recarga already in the conversation, no words, no declaration, 6,200: the deposit lands on it -----
  BEGIN
    SELECT * INTO c FROM pg_temp.d_conv(10);
    v_op := pg_temp.d_op(c, 'collecting_information', 'recarga', 0, 20);
    SELECT * INTO v_reg FROM pg_temp.d_registra(c.conv, 6200, '10409990001001');
    PERFORM pg_temp.d_eq('9 operations', pg_temp.d_ops(c.conv), 'recarga/deposit_verification/6200');
    PERFORM pg_temp.d_eq('9 holder', v_reg.deal_id::text, v_op::text);
  EXCEPTION WHEN OTHERS THEN
    v_fails := v_fails + 1; RAISE WARNING 'FAIL [case 9] %', SQLERRM;
  END;

  IF v_fails > 0 THEN
    RAISE EXCEPTION 'deposito-resolver: % case(s) FAILED (see WARNING lines above)', v_fails;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
