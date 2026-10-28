\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 345 (a phone without a card registers nothing; a
-- saldo-sized amount routes the agent to registrar_numeros_recarga, which
-- converts the send to saldo without a CUP detour).
-- Self-reverting: BEGIN ... RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990435' || lpad(p_n::text, 4, '0'), 'PRUEBA 345 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_conv record, p_monto numeric, p_tx text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), p_conv.acc, p_conv.conv, p_conv.contact, 'ready_to_transfer', 'remesa', 'GYD', p_monto)
  RETURNING id INTO v_op;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES (p_tx, p_monto, 'GYD', 'prueba', now(), now(), v_op);
  RETURN v_op;
END $f$;

DO $$
DECLARE
  c        record;
  v_op     uuid;
  v_id     uuid;
  v_accion text;
  v_res    text;
BEGIN
  -- Deterministic: no live promo in this check.
  DELETE FROM promo_etecsa;

  -- 1-4. Phone only + a saldo-sized amount: nothing is registered and the agent is
  -- sent to registrar_numeros_recarga, which converts the send to saldo.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_op(c, 1000, 'PRUEBA34501');
  SELECT id, accion INTO v_id, v_accion
    FROM cerebro_registrar_beneficiario_auto(c.conv, '', '53981203', 'test-345-a');
  PERFORM pg_temp.t_eq('1 nothing stored', coalesce(v_id::text, '-'), '-');
  PERFORM pg_temp.t_eq('2 routed to the recharge tool', (v_accion LIKE '%registrar_numeros_recarga%')::text, 'true');
  PERFORM pg_temp.t_eq('3 no recipient created',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '0');

  v_res := crm_registrar_numeros_recarga(c.conv, '53981203', true);
  PERFORM pg_temp.t_eq('4 number saved', (v_res LIKE 'guardados 1%')::text, 'true');
  PERFORM pg_temp.t_eq('5 send is saldo',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'saldo');
  PERFORM pg_temp.t_eq('6 the number is the recipient',
    (SELECT string_agg(beneficiary_type || ':' || phone, ',' ORDER BY position)
       FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), 'recarga:53981203');

  -- 7. A CUP-sized amount keeps the card flow: the agent asks for the card.
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op := pg_temp.t_op(c, 5000, 'PRUEBA34502');
  SELECT id, accion INTO v_id, v_accion
    FROM cerebro_registrar_beneficiario_auto(c.conv, '', '53981203', 'test-345-b');
  PERFORM pg_temp.t_eq('7 nothing stored', coalesce(v_id::text, '-'), '-');
  PERFORM pg_temp.t_eq('8 asks for the card', (v_accion LIKE '%Pidele la tarjeta%')::text, 'true');

  -- 9. With a card the tool works as before.
  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_op := pg_temp.t_op(c, 5000, 'PRUEBA34503');
  SELECT id, accion INTO v_id, v_accion
    FROM cerebro_registrar_beneficiario_auto(c.conv, '9238129978944918', '53981203', 'test-345-c');
  PERFORM pg_temp.t_eq('9 card registered', (v_id IS NOT NULL)::text, 'true');
  PERFORM pg_temp.t_eq('10 stored as card',
    (SELECT string_agg(beneficiary_type || ':' || card_number, ',' ORDER BY position)
       FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), 'cuban_card:9238129978944918');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
