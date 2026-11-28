\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 341 (the amount separates a recarga from a saldo movil;
-- the word decides nothing). Self-reverting: BEGIN ... ROLLBACK is in this file; the
-- DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- Case 1: a funded 1,000 GYD send asked as 'recarga' resolves to saldo.
-- Case 2: the recarga number tool on that same amount opens a saldo operation and
--         stores the phone as its ONE number.
-- Case 3: a funded 6,200 GYD send asked as 'recarga' stays a recarga.
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990341' || lpad(p_n::text, 4, '0'), 'PRUEBA 341 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_c record, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid; v_ref text := '1040341' || lpad(floor(random()*1000000)::text, 8, '0');
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', 'remesa', 'GYD', p_monto, clock_timestamp())
  RETURNING id INTO v_op;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES (v_ref, p_monto, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now(), now(), v_op);
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
  v_op3 uuid;
  v_txt text;
  v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
BEGIN
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 1, 'ASSERT 341', 'https://assert.invalid/341', 'assert', md5('assert-341'), 'confirmada');

  -- 1. 1,000 GYD asked as recarga -> saldo
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_op(c, 1000);
  PERFORM cerebro_cambiar_servicio(c.conv, 'recarga', 't341-1');
  PERFORM pg_temp.t_eq('1 a 1,000 GYD recarga is resolved as saldo',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'saldo');

  -- 2. The recarga number tool on 1,000 -> saldo operation with ONE number
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op2 := pg_temp.t_op(c, 1000);
  v_txt := crm_registrar_numeros_recarga(c.conv, '53821206', true, 't341-2');
  PERFORM pg_temp.t_eq('2 the send is a saldo',
    (SELECT service_type FROM remittance_operations WHERE id = v_op2), 'saldo');
  PERFORM pg_temp.t_eq('2 one number stored',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op2 AND status = 'vigente' AND phone = '53821206'), '1');

  -- 3. 6,200 GYD asked as recarga -> recarga
  SELECT * INTO c FROM pg_temp.t_conv(3);
  v_op3 := pg_temp.t_op(c, 6200);
  PERFORM cerebro_cambiar_servicio(c.conv, 'recarga', 't341-3');
  PERFORM pg_temp.t_eq('3 a 6,200 GYD recarga stays a recarga',
    (SELECT service_type FROM remittance_operations WHERE id = v_op3), 'recarga');

  -- 4. 5,000 GYD = 5 paquetes repartidos en 5 telefonos distintos
  SELECT * INTO c FROM pg_temp.t_conv(4);
  v_op := pg_temp.t_op(c, 5000);
  v_txt := crm_registrar_numeros_recarga(c.conv, '53821201 53821202 53821203 53821204 53821205', true, 't341-4');
  PERFORM pg_temp.t_eq('4 a 5,000 GYD recarga is a saldo with 5 packages',
    (SELECT service_type FROM remittance_operations WHERE id = v_op), 'saldo');
  PERFORM pg_temp.t_eq('4 the five phones are stored',
    (SELECT count(*)::text FROM remittance_beneficiaries
      WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'recarga'
        AND phone IN ('53821201','53821202','53821203','53821204','53821205')), '5');

  -- 5. A 5,000 GYD CUP remesa (card recipient) is never read as saldo
  SELECT * INTO c FROM pg_temp.t_conv(5);
  v_op := pg_temp.t_op(c, 5000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status, position, block_index, source)
  VALUES (v_op, 'multiple_distribution', '9999000000000091', '53821206', 'vigente', 1, 1, 'notes_parse');
  PERFORM pg_temp.t_eq('5 a card send keeps the word (never saldo)',
    cerebro_servicio_por_monto(c.conv, 'recarga'), 'recarga');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
