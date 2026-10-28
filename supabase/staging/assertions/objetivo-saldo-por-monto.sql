\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 343 (a deposit with no service chosen and exactly a
-- saldo multiple is its own objective, not the CUP-card minimum).
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
    VALUES (gen_random_uuid(), v_user, '5990433' || lpad(p_n::text, 4, '0'), 'PRUEBA 343 ' || p_n, v_acc) RETURNING id INTO v_ct;
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
  VALUES (gen_random_uuid(), p_conv.acc, p_conv.conv, p_conv.contact, 'collecting_information', 'remesa', 'GYD', p_monto)
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

DO $$
DECLARE
  c        record;
  v_op     uuid;
  v_obj    numeric;
  v_pedido text;
  v_min    numeric;
BEGIN
  -- Deterministic: no live promo in this check.
  DELETE FROM promo_etecsa;

  -- 1-2. No rail, 1,000 GYD = one saldo package: the objective is the money.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_op(c, 1000);
  v_obj := cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('1 objective amount', v_obj::text, '1000');
  SELECT pedido INTO v_pedido FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL;
  PERFORM pg_temp.t_eq('2 objective label', v_pedido, 'saldo movil');

  -- 3. 1,500 is not a saldo multiple: the CUP minimum stays.
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op := pg_temp.t_op(c, 1500);
  v_min := cerebro_minimo_gyd(v_op);
  v_obj := cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('3 not a saldo multiple keeps the minimum', v_obj::text, v_min::text);
  SELECT pedido INTO v_pedido FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL;
  PERFORM pg_temp.t_eq('4 label is the rail minimum', (v_pedido LIKE 'minimo %')::text, 'true');

  -- 5. At the CUP minimum the old behaviour stays.
  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_op := pg_temp.t_op(c, 5000);
  v_obj := cerebro_objetivo_minimo(c.conv, v_op, false);
  PERFORM pg_temp.t_eq('5 at the minimum', v_obj::text, '5000');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
