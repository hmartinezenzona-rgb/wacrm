\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 342 (cash delivery supports several recipients, one per
-- position). Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends
-- in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
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
    VALUES (gen_random_uuid(), v_user, '5990342' || lpad(p_n::text, 4, '0'), 'PRUEBA 342 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
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
  v_r jsonb;
BEGIN
  SELECT * INTO c FROM pg_temp.t_conv(1);
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), c.acc, c.conv, c.contact, 'collecting_information', 'remesa', 'efectivo_usd', 'GYD', 0)
  RETURNING id INTO v_op;

  -- Two cash recipients, data arriving in any order.
  v_r := crm_registrar_datos_entrega_efectivo(c.conv, '53821201', 'Calle 1, Habana', 'wamid-a', 'Ana', 1, 50);
  PERFORM pg_temp.t_eq('1 first recipient inserted', (v_r ->> 'position'), '1');
  v_r := crm_registrar_datos_entrega_efectivo(c.conv, '53821202', 'Calle 2, Matanzas', 'wamid-b', 'Beto', 2, 30);
  PERFORM pg_temp.t_eq('2 second recipient inserted', (v_r ->> 'position'), '2');

  PERFORM pg_temp.t_eq('3 two current cash recipients',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'efectivo_usd'), '2');
  PERFORM pg_temp.t_eq('4 amounts per recipient',
    (SELECT string_agg(coalesce(amount::text,'-'), ',' ORDER BY position) FROM remittance_beneficiaries
      WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'efectivo_usd'), '50,30');
  PERFORM pg_temp.t_eq('5 each row complete',
    (SELECT bool_and(phone IS NOT NULL AND address IS NOT NULL AND id_photo_wamid IS NOT NULL)::text FROM remittance_beneficiaries
      WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'efectivo_usd'), 'true');

  -- Without a position the call still completes the first slot (old behaviour).
  v_r := crm_registrar_datos_entrega_efectivo(c.conv, NULL, 'Calle 1 bis, Habana', NULL, NULL, NULL, NULL);
  PERFORM pg_temp.t_eq('6 default call targets position 1', (v_r ->> 'position'), '1');
  PERFORM pg_temp.t_eq('7 still two current recipients',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'efectivo_usd'), '2');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
