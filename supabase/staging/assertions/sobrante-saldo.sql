\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 347 (with no promo, the tool tells what the money
-- buys: whole saldo packages and the remainder; it stores nothing).
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
    VALUES (gen_random_uuid(), v_user, '5990437' || lpad(p_n::text, 4, '0'), 'PRUEBA 347 ' || p_n, v_acc) RETURNING id INTO v_ct;
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
  c     record;
  v_op  uuid;
  v_res text;
BEGIN
  DELETE FROM promo_etecsa;

  -- 1-3. 1,500 with no promo: one package, 500 left over, nothing stored.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_op(c, 1500, 'PRUEBA34701');
  v_res := crm_registrar_numeros_recarga(c.conv, '53821203', true);
  PERFORM pg_temp.t_eq('1 says one package', (v_res LIKE '%1 paquete(s)%')::text, 'true');
  PERFORM pg_temp.t_eq('2 says 500 left', (v_res LIKE '%le sobran 500 GYD%')::text, 'true');
  PERFORM pg_temp.t_eq('3 nothing stored',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op), '0');
  PERFORM pg_temp.t_eq('4 service unchanged',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'remesa');

  -- 5. 500 with no promo: it does not even reach one package.
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op := pg_temp.t_op(c, 500, 'PRUEBA34702');
  v_res := crm_registrar_numeros_recarga(c.conv, '53821203', true);
  PERFORM pg_temp.t_eq('5 says it is short', (v_res LIKE '%no alcanza ni para uno%')::text, 'true');
  PERFORM pg_temp.t_eq('6 nothing stored',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op), '0');

  -- 7-8. A live promo brings the recarga back.
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, estado, huella, confirmada_at)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date, (now() AT TIME ZONE 'America/Guyana')::date,
          'PRUEBA 347', 'confirmada', 'prueba347', now());
  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_op := pg_temp.t_op(c, 6200, 'PRUEBA34703');
  v_res := crm_registrar_numeros_recarga(c.conv, '53821203', true);
  PERFORM pg_temp.t_eq('7 number saved', (v_res LIKE 'guardados 1%')::text, 'true');
  PERFORM pg_temp.t_eq('8 it is a recarga',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'recarga');

  -- 9-10. 1,000 keeps becoming saldo (341 unchanged).
  DELETE FROM promo_etecsa;
  SELECT * INTO c FROM pg_temp.t_conv(4);
  v_op := pg_temp.t_op(c, 1000, 'PRUEBA34704');
  v_res := crm_registrar_numeros_recarga(c.conv, '53821203', true);
  PERFORM pg_temp.t_eq('9 saldo saved', (v_res LIKE 'guardados 1%')::text, 'true');
  PERFORM pg_temp.t_eq('10 it is saldo',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'saldo');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
