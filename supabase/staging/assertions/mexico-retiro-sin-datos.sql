\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 299: a mexico_retiro needs Bancoppel or BBVA, and no name or phone.
-- Self-reverting. Synthetic fixtures only (PRUEBA contacts, phones 5990291xxxx).
-- =====================================================================

CREATE FUNCTION pg_temp.a_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990291' || lpad(p_n::text, 4, '0'), 'PRUEBA retiro ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.a_op(p_c record, p_amt numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, source_currency,
                                     quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', 'mexico', 'GYD', p_amt, clock_timestamp())
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.a_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.a_has(p_label text, p_got text, p_part text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS NULL OR position(p_part IN p_got) = 0 THEN RAISE EXCEPTION 'case %: expected to contain [%], got [%]', p_label, p_part, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.a_retiros(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(position || ':' || coalesce(bank_name, '-') || ':' || coalesce(name, '-') || ':' || coalesce(phone, '-'),
                             ',' ORDER BY position), 'none')
    FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$f$;

CREATE FUNCTION pg_temp.a_add(p_op uuid, p_datos jsonb, p_uid uuid) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM crm_agregar_beneficiario(p_op, p_datos);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.a_fix(p_ben uuid, p_cambios jsonb, p_uid uuid) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM crm_corregir_beneficiario(p_ben, p_cambios);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE;
END $f$;

DO $$
DECLARE
  c record; v_op uuid; v_r jsonb; v_id uuid; v_sqlstate text := '';
BEGIN
  -- 1 the agent tool saves a cardless withdrawal with no name, no phone and Bancoppel
  SELECT * INTO c FROM pg_temp.a_conv(1);
  v_op := pg_temp.a_op(c, 13000);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'Bancoppel', NULL, NULL, 'agent:registrar_destinatario_mexico n8n:1');
  PERFORM pg_temp.a_eq('1a ok', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('1b rows', pg_temp.a_retiros(v_op), '1:Bancoppel:-:-');

  -- 2 legacy Coppel is stored as Bancoppel
  SELECT * INTO c FROM pg_temp.a_conv(2);
  v_op := pg_temp.a_op(c, 13000);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'Coppel', NULL, NULL, NULL);
  PERFORM pg_temp.a_eq('2a ok', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('2b rows', pg_temp.a_retiros(v_op), '1:Bancoppel:-:-');

  -- 3 BBVA accepted
  SELECT * INTO c FROM pg_temp.a_conv(3);
  v_op := pg_temp.a_op(c, 13000);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'BBVA', NULL, NULL, NULL);
  PERFORM pg_temp.a_eq('3a ok', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('3b rows', pg_temp.a_retiros(v_op), '1:BBVA:-:-');

  -- 4 any other bank refused with the new wording
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'Santander', NULL, NULL, NULL);
  PERFORM pg_temp.a_eq('4a refused', v_r->>'ok', 'false');
  PERFORM pg_temp.a_has('4b mensaje', v_r->>'mensaje', 'Bancoppel');

  -- 5 a bank account still needs its holder
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '012345678901234567', 'Banco Azteca', NULL, NULL, NULL);
  PERFORM pg_temp.a_eq('5a refused', v_r->>'ok', 'false');
  PERFORM pg_temp.a_has('5b mensaje', v_r->>'mensaje', 'Falta el nombre');

  -- 6 the manual add accepts a retiro without name/phone and still refuses a cuenta without holder
  PERFORM pg_temp.a_eq('6a add retiro', pg_temp.a_add(v_op, '{"beneficiary_type":"mexico_retiro","bank_name":"BBVA"}'::jsonb, c.usr), 'ok');
  PERFORM pg_temp.a_eq('6b add cuenta sin nombre', pg_temp.a_add(v_op, '{"beneficiary_type":"mexico_cuenta","clabe":"012345678901234567","bank_name":"Banco Azteca"}'::jsonb, c.usr), '22023');

  -- 7 correcting a retiro can clear a name; correcting a cuenta cannot
  SELECT id INTO v_id FROM remittance_beneficiaries WHERE operation_id = v_op AND beneficiary_type = 'mexico_retiro' AND status = 'vigente' LIMIT 1;
  PERFORM pg_temp.a_eq('7a retiro name null', pg_temp.a_fix(v_id, '{"name":null}'::jsonb, c.usr), 'ok');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, bank_name, clabe, status, position)
  VALUES (v_op, 'mexico_cuenta', 'PRUEBA Cuenta', 'Banco Azteca', '646180110400000009', 'vigente', 9) RETURNING id INTO v_id;
  PERFORM pg_temp.a_eq('7b cuenta name null', pg_temp.a_fix(v_id, '{"name":null}'::jsonb, c.usr), '22023');

  -- 8 the table CHECK accepts Bancoppel and refuses another bank
  BEGIN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, bank_name, status, position)
    VALUES (v_op, 'mexico_retiro', 'Bancoppel', 'vigente', 10);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'case 8a: Bancoppel rejected by the CHECK (%)', SQLERRM;
  END;
  BEGIN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, bank_name, status, position)
    VALUES (v_op, 'mexico_retiro', 'Santander', 'vigente', 11);
  EXCEPTION WHEN check_violation THEN
    v_sqlstate := '23514';
  END;
  PERFORM pg_temp.a_eq('8b other bank blocked', v_sqlstate, '23514');

  -- 9 a cardless withdrawal completes the operation with its bank only
  SELECT * INTO c FROM pg_temp.a_conv(9);
  v_op := pg_temp.a_op(c, 13000);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'BBVA', NULL, NULL, NULL);
  PERFORM pg_temp.a_eq('9 completo con solo el banco', crm_beneficiarios_completos(v_op)::text, 'true');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, bank_name, status, position)
  VALUES (v_op, 'mexico_retiro', NULL, 'vigente', 2);
  PERFORM pg_temp.a_eq('9 sin banco no completo', crm_beneficiarios_completos(v_op)::text, 'false');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
