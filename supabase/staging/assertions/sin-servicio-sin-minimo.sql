\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 346 (a rail-less operation takes the deposited money
-- as its objective, with no service name and no minimum; a card without a card
-- number does not make a card rail).
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
    VALUES (gen_random_uuid(), v_user, '5990436' || lpad(p_n::text, 4, '0'), 'PRUEBA 346 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_conv record, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), p_conv.acc, p_conv.conv, p_conv.contact, 'deposit_verification', 'remesa', 'GYD', p_monto)
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t_obj(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT monto::text || '|' || coalesce(pedido, '-')
    FROM cerebro_objetivo_envio WHERE conversation_id = p_conv AND cerrado_en IS NULL;
$f$;

DO $$
DECLARE
  c     record;
  v_op  uuid;
BEGIN
  -- Deterministic: no live promo in this check.
  DELETE FROM promo_etecsa;

  -- 1-6. No service chosen: the objective is the money, under every amount.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_op(c, 1200);
  PERFORM cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('1 1200 is the objective', pg_temp.t_obj(c.conv), '1200|deposito');

  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op := pg_temp.t_op(c, 1000);
  PERFORM cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('2 1000 is the objective', pg_temp.t_obj(c.conv), '1000|deposito');

  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_op := pg_temp.t_op(c, 3000);
  PERFORM cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('3 3000 is the objective', pg_temp.t_obj(c.conv), '3000|deposito');
  PERFORM pg_temp.t_eq('4 no rail yet', coalesce(cerebro_riel_op(v_op), '-'), '-');

  -- 5-7. A phone-only card row is not a card rail.
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position,
                                        block_index, source, status)
  VALUES (v_op, 'cuban_card', NULL, '53981203', 1, 1, 'notes_parse', 'vigente');
  PERFORM pg_temp.t_eq('5 phone only is not a rail', coalesce(cerebro_riel_op(v_op), '-'), '-');

  -- 8-9. With a real card the rail and the minimum come back.
  UPDATE remittance_beneficiaries SET card_number = '9238129978944918'
   WHERE operation_id = v_op AND status = 'vigente';
  PERFORM pg_temp.t_eq('6 card number is a rail', cerebro_riel_op(v_op), 'cuban_card');
  PERFORM pg_temp.t_eq('7 card minimum', cerebro_minimo_gyd(v_op)::text, '5000');

  SELECT * INTO c FROM pg_temp.t_conv(4);
  v_op := pg_temp.t_op(c, 1200);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position,
                                        block_index, source, status)
  VALUES (v_op, 'cuban_card', '9238129978944918', '53981203', 1, 1, 'notes_parse', 'vigente');
  PERFORM cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('8 declared card still gets its minimum', pg_temp.t_obj(c.conv), '5000|minimo tarjeta CUP');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
