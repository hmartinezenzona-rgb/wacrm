\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 340 (each card recipient ends on the operation of its
-- own rail). Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block
-- ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- Fixture: a Zelle operation holds the deposit; ONE reparto operation carries a
-- Clasica recipient and a Tropical recipient (what registrar_reparto_multiple
-- saves). repartir_envio('zelle 13000, clasica 13000, tropical 13000') must
-- leave the Clasica row on the Clasica operation and the Tropical row on the
-- Tropical one, each with its own destination (50 USD, not 100).
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990340' || lpad(p_n::text, 4, '0'), 'PRUEBA 340 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_c record, p_rail text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', 'remesa', p_rail, 'GYD', 0, clock_timestamp())
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
  v_z uuid;
  v_rep uuid;
  v_txt text;
  v_n int;
  v_cl uuid;
  v_tr uuid;
  v_cl_dest numeric;
  v_tr_dest numeric;
BEGIN
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_z := pg_temp.t_op(c, 'zelle');
  UPDATE remittance_operations SET quoted_source_amount = 39000 WHERE id = v_z;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('10403400000001', 39000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now(), now(), v_z);

  -- One reparto operation with two rails, as registrar_reparto_multiple saves it.
  v_rep := pg_temp.t_op(c, NULL);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, amount, currency, status, position, block_index, source)
  VALUES (v_rep, 'clasica',  '9999000000000061', '53821206', 50, 'USD', 'vigente', 1, 1, 'notes_parse'),
         (v_rep, 'tropical', '9999000000000062', '53821206', 50, 'USD', 'vigente', 2, 2, 'notes_parse');

  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = c.conv;
  v_txt := cerebro_repartir_envio(c.conv, 'zelle 13000, clasica 13000, tropical 13000', 't340');
  PERFORM pg_temp.t_eq('1 split done', (v_txt LIKE 'Reparto hecho%')::text, 'true');

  SELECT id INTO v_cl FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'clasica';
  SELECT id INTO v_tr FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'tropical';
  PERFORM pg_temp.t_eq('2 a clasica operation exists', (v_cl IS NOT NULL)::text, 'true');
  PERFORM pg_temp.t_eq('3 a tropical operation exists', (v_tr IS NOT NULL)::text, 'true');
  PERFORM pg_temp.t_eq('4 the clasica row lives on the clasica operation',
    (SELECT string_agg(beneficiary_type, ',') FROM remittance_beneficiaries WHERE operation_id = v_cl AND status = 'vigente'), 'clasica');
  PERFORM pg_temp.t_eq('5 the tropical row lives on the tropical operation',
    (SELECT string_agg(beneficiary_type, ',') FROM remittance_beneficiaries WHERE operation_id = v_tr AND status = 'vigente'), 'tropical');

  SELECT quoted_destination_amount INTO v_cl_dest FROM remittance_operations WHERE id = v_cl;
  SELECT quoted_destination_amount INTO v_tr_dest FROM remittance_operations WHERE id = v_tr;
  PERFORM pg_temp.t_eq('6 clasica destination is its own 50 USD', coalesce(v_cl_dest::text, 'null'), '50');
  PERFORM pg_temp.t_eq('7 tropical destination is its own 50 USD', coalesce(v_tr_dest::text, 'null'), '50');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
