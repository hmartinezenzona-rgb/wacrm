\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 290 (México recipients carry the USD amount that goes to each one). Self-reverting.
-- Load after 271, 275, 288. Synthetic fixtures only: contacts 'PRUEBA mexico amt N', phones 5990290xxxx, fake CLABEs.
-- Operation of 13,000 GYD = 50 USD at the staging rate of 260 (the case checks the rate it relies on).
-- Cases:
--   1  old 7-argument call shape still works: two different CLABEs append, no amount stored, answer unchanged
--   2  p_monto stores amount + currency 'USD' + amount_origin 'manual'; the answer names it ("30 USD")
--   3  the same CLABE again without monto keeps the amount; with a new monto changes it, no duplicate
--   4  the sum of amounts may not exceed the operation's USD: refused in plain Spanish, nothing written
--   5  monto <= 0 refused
--   6  p_posicion=k with a NEW CLABE corrects slot k (no new row, amount kept); k = N+1 appends; k > N+1 refused
--   7  p_posicion with only p_monto (no clabe / name) changes the amount of that slot
--   8  p_agregar with an existing CLABE patches it (no duplicate); with a new one appends
--   9  crm_agregar_beneficiario accepts amount for a mexico row (stored in USD), refuses a sum over the operation
--  10  crm_corregir_beneficiario accepts amount for a mexico row, refuses a sum over the operation, null clears it
--  11  grants: 10-argument signature service_role only; the 7-argument signature is gone
-- =====================================================================

CREATE FUNCTION pg_temp.a_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990290' || lpad(p_n::text, 4, '0'), 'PRUEBA mexico amt ' || p_n, v_acc) RETURNING id INTO v_ct;
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

-- "pos:clabe-last4:amount:currency" of the vigente recipients, in position order
CREATE FUNCTION pg_temp.a_vig(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(position || ':' || right(coalesce(clabe, ''), 4) || ':' || coalesce(trim_scale(amount)::text, '-') || ':' || coalesce(currency, '-'),
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
  c record; v_op uuid; v_r jsonb; v_id uuid;
  k1 constant text := '012345678901234567';
  k2 constant text := '646180110400000009';
  k3 constant text := '722969069917903430';
  k4 constant text := '722969016121615376';
BEGIN
  -- 0 the rate the fixture relies on
  PERFORM pg_temp.a_eq('0 usd of 13000', _cerebro_usd_parte('mexico', 13000)::text, '50');

  -- 1 the old 7-argument call shape
  SELECT * INTO c FROM pg_temp.a_conv(1);
  v_op := pg_temp.a_op(c, 13000);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana', NULL, 'agent:registrar_destinatario_mexico n8n:1');
  PERFORM pg_temp.a_eq('1a ok', v_r->>'ok', 'true');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k2, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL);
  PERFORM pg_temp.a_eq('1b ok', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('1c rows', pg_temp.a_vig(v_op), '1:4567:-:-,2:0009:-:-');

  -- 2 p_monto stored in USD
  SELECT * INTO c FROM pg_temp.a_conv(2);
  v_op := pg_temp.a_op(c, 13000);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana', NULL, NULL, p_monto => 30);
  PERFORM pg_temp.a_eq('2a ok', v_r->>'ok', 'true');
  PERFORM pg_temp.a_has('2b mensaje', v_r->>'mensaje', '30 USD');
  PERFORM pg_temp.a_eq('2c rows', pg_temp.a_vig(v_op), '1:4567:30:USD');
  PERFORM pg_temp.a_eq('2d origin', (SELECT amount_origin FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), 'manual');

  -- 3 same CLABE: amount kept, then changed, never duplicated
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana Lopez', NULL, NULL);
  PERFORM pg_temp.a_eq('3a rows', pg_temp.a_vig(v_op), '1:4567:30:USD');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana Lopez', NULL, NULL, p_monto => 20);
  PERFORM pg_temp.a_eq('3b rows', pg_temp.a_vig(v_op), '1:4567:20:USD');

  -- 4 the sum may not exceed the operation's USD (50)
  SELECT * INTO c FROM pg_temp.a_conv(4);
  v_op := pg_temp.a_op(c, 13000);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana', NULL, NULL, p_monto => 30);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k2, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL, p_agregar => true, p_monto => 30);
  PERFORM pg_temp.a_eq('4a refused', v_r->>'ok', 'false');
  PERFORM pg_temp.a_has('4b mensaje', v_r->>'mensaje', 'mas de los 50 USD');
  PERFORM pg_temp.a_has('4c mensaje', v_r->>'mensaje', 'No se guardo nada');
  PERFORM pg_temp.a_eq('4d nothing written', pg_temp.a_vig(v_op), '1:4567:30:USD');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k2, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL, p_agregar => true, p_monto => 20);
  PERFORM pg_temp.a_eq('4e exactly 50 fits', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('4f rows', pg_temp.a_vig(v_op), '1:4567:30:USD,2:0009:20:USD');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k2, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL, p_monto => 21);
  PERFORM pg_temp.a_eq('4g raising a slot over the cap', v_r->>'ok', 'false');
  PERFORM pg_temp.a_eq('4h rows unchanged', pg_temp.a_vig(v_op), '1:4567:30:USD,2:0009:20:USD');

  -- 5 monto <= 0
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k3, 'Mercado Pago', 'PRUEBA Cata', NULL, NULL, p_monto => 0);
  PERFORM pg_temp.a_eq('5a zero', v_r->>'ok', 'false');
  PERFORM pg_temp.a_has('5b zero mensaje', v_r->>'mensaje', 'mayor que 0');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k3, 'Mercado Pago', 'PRUEBA Cata', NULL, NULL, p_monto => -5);
  PERFORM pg_temp.a_eq('5c negative', v_r->>'ok', 'false');

  -- 6 posicion: correction of slot k, append at N+1, invalid
  SELECT * INTO c FROM pg_temp.a_conv(6);
  v_op := pg_temp.a_op(c, 13000);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana', NULL, NULL, p_monto => 30);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k3, NULL, NULL, NULL, NULL, p_posicion => 1);
  PERFORM pg_temp.a_eq('6a corrected', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('6b corrected in place, amount kept', pg_temp.a_vig(v_op), '1:3430:30:USD');
  PERFORM pg_temp.a_eq('6c holder kept', (SELECT name || '|' || bank_name FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), 'PRUEBA Ana|Banco Azteca');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k2, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL, p_posicion => 2);
  PERFORM pg_temp.a_eq('6d append at N+1', pg_temp.a_vig(v_op), '1:3430:30:USD,2:0009:-:-');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k4, 'Mercado Pago', 'PRUEBA Dani', NULL, NULL, p_posicion => 4);
  PERFORM pg_temp.a_eq('6e invalid position', v_r->>'ok', 'false');
  PERFORM pg_temp.a_has('6f invalid position mensaje', v_r->>'mensaje', 'no existe');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k3, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL, p_posicion => 2);
  PERFORM pg_temp.a_eq('6g account of another slot', v_r->>'ok', 'false');
  PERFORM pg_temp.a_has('6h mensaje', v_r->>'mensaje', 'ya es la del destinatario 1');
  PERFORM pg_temp.a_eq('6i rows unchanged', pg_temp.a_vig(v_op), '1:3430:30:USD,2:0009:-:-');

  -- 7 posicion with only the amount
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', NULL, NULL, NULL, NULL, NULL, p_posicion => 2, p_monto => 20);
  PERFORM pg_temp.a_eq('7a ok', v_r->>'ok', 'true');
  PERFORM pg_temp.a_eq('7b rows', pg_temp.a_vig(v_op), '1:3430:30:USD,2:0009:20:USD');
  PERFORM pg_temp.a_has('7c lists the recipients', v_r->>'mensaje', '2) PRUEBA Beto / Mercado Pago / 20 USD');

  -- 8 agregar
  SELECT * INTO c FROM pg_temp.a_conv(8);
  v_op := pg_temp.a_op(c, 13000);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana', NULL, NULL, p_monto => 10);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k1, 'Banco Azteca', 'PRUEBA Ana', NULL, NULL, p_agregar => true, p_monto => 15);
  PERFORM pg_temp.a_eq('8a same CLABE patches', pg_temp.a_vig(v_op), '1:4567:15:USD');
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', k2, 'Mercado Pago', 'PRUEBA Beto', NULL, NULL, p_agregar => true);
  PERFORM pg_temp.a_eq('8b new CLABE appends', pg_temp.a_vig(v_op), '1:4567:15:USD,2:0009:-:-');

  -- 9 panel add
  SELECT * INTO c FROM pg_temp.a_conv(9);
  v_op := pg_temp.a_op(c, 13000);
  PERFORM pg_temp.a_eq('9a add with amount', pg_temp.a_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'PRUEBA Ana', 'clabe', k1, 'bank_name', 'Banco Azteca', 'amount', 30), c.usr), 'ok');
  PERFORM pg_temp.a_eq('9b stored', pg_temp.a_vig(v_op), '1:4567:30:USD');
  PERFORM pg_temp.a_eq('9c over the cap', pg_temp.a_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'PRUEBA Beto', 'clabe', k2, 'bank_name', 'Mercado Pago', 'amount', 30), c.usr), '22023');
  PERFORM pg_temp.a_eq('9d currency must be USD', pg_temp.a_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'PRUEBA Beto', 'clabe', k2, 'bank_name', 'Mercado Pago', 'amount', 20, 'currency', 'GYD'), c.usr), '22023');
  PERFORM pg_temp.a_eq('9e zero amount', pg_temp.a_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'PRUEBA Beto', 'clabe', k2, 'bank_name', 'Mercado Pago', 'amount', 0), c.usr), '22023');
  PERFORM pg_temp.a_eq('9f nothing written by the refusals', pg_temp.a_vig(v_op), '1:4567:30:USD');
  PERFORM pg_temp.a_eq('9g add without amount still works', pg_temp.a_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'PRUEBA Beto', 'clabe', k2, 'bank_name', 'Mercado Pago'), c.usr), 'ok');
  PERFORM pg_temp.a_eq('9h rows', pg_temp.a_vig(v_op), '1:4567:30:USD,2:0009:-:-');

  -- 10 panel correction
  SELECT id INTO v_id FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND position = 2;
  PERFORM pg_temp.a_eq('10a over the cap', pg_temp.a_fix(v_id, jsonb_build_object('amount', 25), c.usr), '22023');
  PERFORM pg_temp.a_eq('10b fits', pg_temp.a_fix(v_id, jsonb_build_object('amount', 20), c.usr), 'ok');
  PERFORM pg_temp.a_eq('10c rows', pg_temp.a_vig(v_op), '1:4567:30:USD,2:0009:20:USD');
  SELECT id INTO v_id FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND position = 1;
  PERFORM pg_temp.a_eq('10d clear', pg_temp.a_fix(v_id, jsonb_build_object('amount', NULL), c.usr), 'ok');
  PERFORM pg_temp.a_eq('10e rows after clear', pg_temp.a_vig(v_op), '1:4567:-:-,2:0009:20:USD');
  PERFORM pg_temp.a_eq('10f currency must be USD', pg_temp.a_fix((SELECT id FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND position = 1),
                                                              jsonb_build_object('amount', 5, 'currency', 'GYD'), c.usr), '22023');
  PERFORM pg_temp.a_eq('10g name-only correction keeps the amount', pg_temp.a_fix((SELECT id FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND position = 2),
                                                              jsonb_build_object('name', 'PRUEBA Beto Ruiz'), c.usr), 'ok');
  PERFORM pg_temp.a_eq('10h rows', pg_temp.a_vig(v_op), '1:4567:-:-,2:0009:20:USD');

  -- 11 grants
  PERFORM pg_temp.a_eq('11a grants', has_function_privilege('authenticated', 'cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text,integer,boolean,numeric)', 'EXECUTE')::text || ':' ||
    has_function_privilege('anon', 'cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text,integer,boolean,numeric)', 'EXECUTE')::text || ':' ||
    has_function_privilege('service_role', 'cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text,integer,boolean,numeric)', 'EXECUTE')::text, 'false:false:true');
  PERFORM pg_temp.a_eq('11b old signature gone', to_regprocedure('cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text)')::text, NULL);
  PERFORM pg_temp.a_eq('11c helper postgres only', has_function_privilege('service_role', '_cerebro_mexico_tope_usd(uuid,uuid,numeric)', 'EXECUTE')::text || ':' ||
    has_function_privilege('authenticated', '_cerebro_mexico_tope_usd(uuid,uuid,numeric)', 'EXECUTE')::text, 'false:false');
  PERFORM pg_temp.a_eq('11d panel RPCs authenticated only', has_function_privilege('authenticated', 'crm_agregar_beneficiario(uuid,jsonb)', 'EXECUTE')::text || ':' ||
    has_function_privilege('service_role', 'crm_agregar_beneficiario(uuid,jsonb)', 'EXECUTE')::text || ':' ||
    has_function_privilege('authenticated', 'crm_corregir_beneficiario(uuid,jsonb)', 'EXECUTE')::text || ':' ||
    has_function_privilege('service_role', 'crm_corregir_beneficiario(uuid,jsonb)', 'EXECUTE')::text, 'true:false:true:false');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
