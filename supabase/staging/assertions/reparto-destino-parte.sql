\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 338 (the split writes each part's destination when its
-- recipients already carry the amounts). Self-reverting: BEGIN ... ROLLBACK is in
-- this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- Fixture: Zelle operation holds the verified deposit; a CUP reparto operation
-- (delivery_method NULL, two multiple_distribution recipients of 19,500 CUP)
-- already holds the cards. The split reuses it (337) and must now fill its
-- destination: 39,000 CUP. The Zelle part keeps 50 USD.
-- =====================================================================

CREATE FUNCTION pg_temp.t_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990338' || lpad(p_n::text, 4, '0'), 'PRUEBA 338 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_op(p_c record, p_svc text, p_rail text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', p_svc, p_rail, 'GYD', 0, clock_timestamp())
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
  v_cup uuid;
  v_txt text;
  v_dest numeric;
  v_cur text;
  v_zdest numeric;
  v_zcur text;
BEGIN
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_z := pg_temp.t_op(c, 'remesa', 'zelle');
  UPDATE remittance_operations SET quoted_source_amount = 26000 WHERE id = v_z;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('10403380000001', 26000, 'GYD', 'CASH_IN_TO_AGENT_OK_RECEIVER', now(), now(), v_z);

  v_cup := pg_temp.t_op(c, 'remesa', NULL);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, amount, currency, status, position, block_index, source)
  VALUES (v_cup, 'multiple_distribution', '9999000000000021', '53892312', 19500, 'CUP', 'vigente', 1, 1, 'notes_parse'),
         (v_cup, 'multiple_distribution', '9999000000000022', '53892312', 19500, 'CUP', 'vigente', 2, 2, 'notes_parse');

  v_txt := cerebro_repartir_envio(c.conv, 'zelle 13000, cup 13000', 't338');
  PERFORM pg_temp.t_eq('1 split done', (v_txt LIKE 'Reparto hecho%')::text, 'true');

  SELECT quoted_destination_amount, destination_currency INTO v_dest, v_cur FROM remittance_operations WHERE id = v_cup;
  PERFORM pg_temp.t_eq('2 the CUP part shows its destination total', coalesce(v_dest::text, 'null'), '39000');
  PERFORM pg_temp.t_eq('3 the CUP part currency', coalesce(v_cur, 'null'), 'CUP');

  SELECT quoted_destination_amount, destination_currency INTO v_zdest, v_zcur FROM remittance_operations WHERE id = v_z;
  PERFORM pg_temp.t_eq('4 the Zelle part keeps its own amount', coalesce(v_zdest::text, 'null'), '50');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
