\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 339 (opening a recarga never retires another service's
-- recipient). Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block
-- ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- Case 1: a funded operation already carries a CUP card; registering recarga
-- numbers must NOT convert it (the card would be retired) and the card stays.
-- Case 2: a funded operation with no recipients still becomes the recarga.
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990339' || lpad(p_n::text, 4, '0'), 'PRUEBA 339 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_c record) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', 'remesa', 'GYD', 26000, clock_timestamp())
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

DO $$
DECLARE
  c record;
  v_op uuid;
  v_op2 uuid;
  v_svc text;
  v_svc2 text;
  v_n int;
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
BEGIN
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 1, 'ASSERT 339', 'https://assert.invalid/339', 'assert', md5('assert-339'), 'confirmada');

  -- 1. Funded operation that already has a CUP card: no conversion, card kept.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_op(c);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status, position, block_index, source)
  VALUES (v_op, 'cuban_card', '9999000000000031', '53456789', 'vigente', 1, 1, 'notes_parse');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('10403390000001', 26000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now(), now(), v_op);

  PERFORM crm_registrar_numeros_recarga(c.conv, '53821203', true);
  SELECT service_type INTO v_svc FROM remittance_operations WHERE id = v_op;
  PERFORM pg_temp.t_eq('1 the funded CUP operation is not converted', v_svc, 'remesa');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries
   WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'cuban_card';
  PERFORM pg_temp.t_eq('1 the CUP card stays vigente', v_n::text, '1');

  -- 2. Funded operation with no recipients: still becomes the recarga.
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op2 := pg_temp.t_op(c);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('10403390000002', 26000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now(), now(), v_op2);

  PERFORM crm_registrar_numeros_recarga(c.conv, '53821203', true);
  SELECT service_type INTO v_svc2 FROM remittance_operations WHERE id = v_op2;
  PERFORM pg_temp.t_eq('2 a plain funded operation still becomes the recarga', v_svc2, 'recarga');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
