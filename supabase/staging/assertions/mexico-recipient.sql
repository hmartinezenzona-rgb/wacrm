\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 271 (México recipients: mexico_cuenta / mexico_retiro, CLABE, bank_name). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA mexico N', phones 5990271xxxx, fake CLABEs and a fake card.
-- odd/tasks/service-resolution.md (México as a real operation, M2).
-- Cases (number = label in the failure message):
--   1  a mexico_cuenta recipient (name, 18-digit CLABE, bank) and a mexico_retiro recipient (name, phone, Coppel / BBVA)
--      insert and stay vigente on a 'mexico' operation; card_number stays NULL
--   2  CLABE must be exactly 18 digits: 17 digits, 19 digits and letters are refused (check_violation)
--   3  a CLABE only exists on México recipients; card_number is never set on a México recipient (a CLABE is never a card)
--   4  mexico_retiro bank_name is Coppel or BBVA only; mexico_cuenta takes any bank (Banco Azteca, Mercado Pago)
--   5  inserting México recipients does not change the operation's service_type / delivery rail columns it was given
--   6  crm_beneficiarios_completos: a complete cuenta / retiro is true; missing CLABE, bank or name is false; a retiro
--      without phone is false; a cuenta without phone is still true
--   7  card logic ignores México: cerebro_resolver_servicio sees no card data on a conversation whose only recipient is a
--      mexico_cuenta; the unchanged Cuban-card recipients still count
--   8  _cambiar_servicio_core remesa -> recarga: a phone-only mexico_retiro is NOT kept as a recarga number (retired),
--      the phone-only cuban_card is (existing behaviour)
--   9  crm_agregar_beneficiario (panel): México recipients on a 'mexico' operation with the add validations, the
--      operation's delivery_method follows, other operations refuse México types
--  10  crm_corregir_beneficiario: name, clabe, bank_name, phone on México rows with the same validations
--  11  crm_operaciones_de_conversacion returns 'mexico' operations with beneficiary_clabe / beneficiary_bank_name
--  12  cerebro_guardar_beneficiario_mexico: no open operation, validations, dedupe by CLABE, delivery_method, source
--      'agente', actor parsed from p_exec ('agent:<tool> n8n:<exec>', default tool name), service_role only
-- =====================================================================

CREATE FUNCTION pg_temp.m_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990271' || lpad(p_n::text, 4, '0'), 'PRUEBA mexico ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.m_op(p_c record, p_svc text, p_rail text, p_amt numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, 'collecting_information', p_svc, p_rail, 'GYD', p_amt, clock_timestamp())
  RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

-- insert a recipient; returns its id. Raw columns so the test sees the constraint, not a helper's cleaning.
CREATE FUNCTION pg_temp.m_ben(p_op uuid, p_type text, p_name text, p_card text, p_phone text, p_clabe text, p_bank text, p_pos int DEFAULT 1) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  EXECUTE format($q$INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, clabe, bank_name,
                                                          position, block_index, source, status)
                    VALUES (%L, %L, %L, %L, %L, %L, %L, %s, %s, 'test271', 'vigente') RETURNING id$q$,
                 p_op, p_type, p_name, p_card, p_phone, p_clabe, p_bank, p_pos, p_pos) INTO v_id;
  RETURN v_id;
END $f$;

-- true when the insert raised check_violation (sqlstate 23514)
CREATE FUNCTION pg_temp.m_refused(p_op uuid, p_type text, p_name text, p_card text, p_phone text, p_clabe text, p_bank text) RETURNS boolean
LANGUAGE plpgsql AS $f$
BEGIN
  BEGIN
    PERFORM pg_temp.m_ben(p_op, p_type, p_name, p_card, p_phone, p_clabe, p_bank, 9);
    RETURN false;
  EXCEPTION WHEN check_violation THEN
    RETURN true;
  END;
END $f$;

CREATE FUNCTION pg_temp.m_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.m_vig(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(t || ':' || n, ',' ORDER BY t), 'none')
    FROM (SELECT beneficiary_type t, count(*) n FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente' GROUP BY 1) q;
$f$;

-- panel call as the account owner: returns the sqlstate text ('ok' when it worked)
CREATE FUNCTION pg_temp.m_add(p_op uuid, p_datos jsonb, p_uid uuid) RETURNS text
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

CREATE FUNCTION pg_temp.m_fix(p_ben uuid, p_cambios jsonb, p_uid uuid) RETURNS text
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
  c record; v_op uuid; v_cu uuid; v_re uuid; v_card uuid; v_rt uuid; v_r jsonb; v_o remittance_operations%ROWTYPE;
  c_clabe constant text := '012345678901234567';
  c_clabe2 constant text := '646180110400000009';
  c_card constant text := '9999000000000003';
BEGIN
  -- 1
  SELECT * INTO c FROM pg_temp.m_conv(1);
  v_op := pg_temp.m_op(c, 'mexico', NULL, 13000);
  v_cu := pg_temp.m_ben(v_op, 'mexico_cuenta', 'PRUEBA Maria Mex', NULL, NULL, c_clabe, 'Banco Azteca', 1);
  v_re := pg_temp.m_ben(v_op, 'mexico_retiro', 'PRUEBA Juan Mex', NULL, '5215512345678', NULL, 'Coppel', 2);
  PERFORM pg_temp.m_ben(v_op, 'mexico_retiro', 'PRUEBA Ana Mex', NULL, '5215512345679', NULL, 'BBVA', 3);
  PERFORM pg_temp.m_eq('1 vigentes', pg_temp.m_vig(v_op), 'mexico_cuenta:1,mexico_retiro:2');
  PERFORM pg_temp.m_eq('1 card null', (SELECT count(*) FILTER (WHERE card_number IS NOT NULL)::text FROM remittance_beneficiaries WHERE operation_id = v_op), '0');
  PERFORM pg_temp.m_eq('1 clabe kept', (SELECT clabe FROM remittance_beneficiaries WHERE id = v_cu), c_clabe);
  PERFORM pg_temp.m_eq('1 bank kept', (SELECT bank_name FROM remittance_beneficiaries WHERE id = v_cu), 'Banco Azteca');

  -- 2
  PERFORM pg_temp.m_eq('2 17 digits', pg_temp.m_refused(v_op, 'mexico_cuenta', 'X', NULL, NULL, '01234567890123456', 'Banco Azteca')::text, 'true');
  PERFORM pg_temp.m_eq('2 19 digits', pg_temp.m_refused(v_op, 'mexico_cuenta', 'X', NULL, NULL, '0123456789012345678', 'Banco Azteca')::text, 'true');
  PERFORM pg_temp.m_eq('2 letters', pg_temp.m_refused(v_op, 'mexico_cuenta', 'X', NULL, NULL, '01234567890123456A', 'Banco Azteca')::text, 'true');
  PERFORM pg_temp.m_eq('2 spaces', pg_temp.m_refused(v_op, 'mexico_cuenta', 'X', NULL, NULL, '0123 4567 8901 2345 67', 'Banco Azteca')::text, 'true');

  -- 3
  PERFORM pg_temp.m_eq('3 clabe on a Cuban card', pg_temp.m_refused(v_op, 'cuban_card', 'X', c_card, '53555555', c_clabe, NULL)::text, 'true');
  PERFORM pg_temp.m_eq('3 clabe on zelle', pg_temp.m_refused(v_op, 'zelle', 'X', NULL, NULL, c_clabe, NULL)::text, 'true');
  PERFORM pg_temp.m_eq('3 card on mexico_cuenta', pg_temp.m_refused(v_op, 'mexico_cuenta', 'X', c_card, NULL, c_clabe2, 'Mercado Pago')::text, 'true');
  PERFORM pg_temp.m_eq('3 card on mexico_retiro', pg_temp.m_refused(v_op, 'mexico_retiro', 'X', c_card, '5215512345670', NULL, 'Coppel')::text, 'true');
  PERFORM pg_temp.m_eq('3 bank on a Cuban card', pg_temp.m_refused(v_op, 'cuban_card', 'X', c_card, '53555555', NULL, 'Coppel')::text, 'true');

  -- 4
  PERFORM pg_temp.m_eq('4 retiro bank Banorte', pg_temp.m_refused(v_op, 'mexico_retiro', 'X', NULL, '5215512345670', NULL, 'Banorte')::text, 'true');
  PERFORM pg_temp.m_ben(v_op, 'mexico_cuenta', 'PRUEBA Mercado', NULL, NULL, c_clabe2, 'Mercado Pago', 4);
  PERFORM pg_temp.m_eq('4 cuenta Mercado Pago ok', pg_temp.m_vig(v_op), 'mexico_cuenta:2,mexico_retiro:2');

  -- 5
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  PERFORM pg_temp.m_eq('5 service', v_o.service_type, 'mexico');
  PERFORM pg_temp.m_eq('5 quoted source', v_o.quoted_source_amount::text, '13000');

  -- 6 completeness
  SELECT * INTO c FROM pg_temp.m_conv(2);
  v_op := pg_temp.m_op(c, 'mexico', NULL, 13000);
  PERFORM pg_temp.m_eq('6 empty', crm_beneficiarios_completos(v_op)::text, 'false');
  v_cu := pg_temp.m_ben(v_op, 'mexico_cuenta', 'PRUEBA Maria Mex', NULL, NULL, c_clabe, 'Banco Azteca', 1);
  PERFORM pg_temp.m_eq('6 cuenta complete without phone', crm_beneficiarios_completos(v_op)::text, 'true');
  UPDATE remittance_beneficiaries SET name = NULL WHERE id = v_cu;
  PERFORM pg_temp.m_eq('6 cuenta without name', crm_beneficiarios_completos(v_op)::text, 'false');
  UPDATE remittance_beneficiaries SET name = 'PRUEBA Maria Mex', bank_name = NULL WHERE id = v_cu;
  PERFORM pg_temp.m_eq('6 cuenta without bank', crm_beneficiarios_completos(v_op)::text, 'false');
  UPDATE remittance_beneficiaries SET bank_name = 'Banco Azteca', clabe = NULL WHERE id = v_cu;
  PERFORM pg_temp.m_eq('6 cuenta without clabe', crm_beneficiarios_completos(v_op)::text, 'false');
  UPDATE remittance_beneficiaries SET clabe = c_clabe WHERE id = v_cu;
  v_re := pg_temp.m_ben(v_op, 'mexico_retiro', 'PRUEBA Juan Mex', NULL, NULL, NULL, 'Coppel', 2);
  PERFORM pg_temp.m_eq('6 retiro without phone', crm_beneficiarios_completos(v_op)::text, 'false');
  UPDATE remittance_beneficiaries SET phone = '5215512345678' WHERE id = v_re;
  PERFORM pg_temp.m_eq('6 cuenta + retiro complete', crm_beneficiarios_completos(v_op)::text, 'true');

  -- 7 card logic ignores México
  SELECT * INTO c FROM pg_temp.m_conv(3);
  v_op := pg_temp.m_op(c, 'remesa', NULL, 13000);
  PERFORM pg_temp.m_ben(v_op, 'mexico_cuenta', 'PRUEBA Maria Mex', NULL, NULL, c_clabe, 'Banco Azteca', 1);
  v_r := cerebro_resolver_servicio(c.conv, 'cuban_card', 'cambiar', 13000, now());
  PERFORM pg_temp.m_eq('7 resolver result present', (v_r IS NOT NULL)::text, 'true');
  PERFORM pg_temp.m_eq('7 no card counted',
    (SELECT count(*)::text FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND nullif(b.card_number, '') IS NOT NULL), '0');

  -- 8 conversion keeps phone-only Cuban recipients as recarga numbers but never a México withdrawal
  SELECT * INTO c FROM pg_temp.m_conv(4);
  v_op := pg_temp.m_op(c, 'remesa', 'cuban_card', 13000);
  v_card := pg_temp.m_ben(v_op, 'cuban_card', 'X', NULL, '53555551', NULL, NULL, 1);
  v_rt := pg_temp.m_ben(v_op, 'mexico_retiro', 'PRUEBA Juan Mex', NULL, '5215512345678', NULL, 'Coppel', 2);
  PERFORM _cambiar_servicio_core(v_op, 'recarga', 'automation_service_change', 'automation:test271', 'mexico assertion');
  PERFORM pg_temp.m_eq('8 cuban phone kept as recarga', (SELECT beneficiary_type FROM remittance_beneficiaries WHERE id = v_card), 'recarga');
  PERFORM pg_temp.m_eq('8 mexico retiro retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_rt), 'reemplazado');
  PERFORM pg_temp.m_eq('8 mexico retiro type intact', (SELECT beneficiary_type FROM remittance_beneficiaries WHERE id = v_rt), 'mexico_retiro');

  -- 9 panel add
  SELECT * INTO c FROM pg_temp.m_conv(5);
  v_op := pg_temp.m_op(c, 'mexico', NULL, 13000);
  PERFORM pg_temp.m_eq('9 cuenta with spaces', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'PRUEBA Maria Mex', 'clabe', '0123 4567 8901 2345 67', 'bank_name', 'Banco Azteca'), c.usr), 'ok');
  PERFORM pg_temp.m_eq('9 clabe normalized', (SELECT clabe FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), c_clabe);
  PERFORM pg_temp.m_eq('9 rail follows', (SELECT delivery_method FROM remittance_operations WHERE id = v_op), 'mexico_cuenta');
  PERFORM pg_temp.m_eq('9 duplicate clabe', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'X', 'clabe', c_clabe, 'bank_name', 'Banco Azteca'), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 short clabe', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'X', 'clabe', '1234', 'bank_name', 'Banco Azteca'), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 cuenta without bank', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'X', 'clabe', c_clabe2), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 retiro Banorte', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_retiro', 'name', 'X', 'bank_name', 'Banorte', 'phone', '5215512345678'), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 retiro without phone', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_retiro', 'name', 'X', 'bank_name', 'Coppel'), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 retiro with amount', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_retiro', 'name', 'X', 'bank_name', 'Coppel', 'phone', '5215512345678', 'amount', 100), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 cuenta with card', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'X', 'clabe', c_clabe2, 'bank_name', 'BBVA', 'card_number', c_card), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 retiro bbva lower', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_retiro', 'name', 'PRUEBA Juan Mex', 'bank_name', 'bbva', 'phone', '+52 1 55 1234 5678'), c.usr), 'ok');
  PERFORM pg_temp.m_eq('9 retiro stored', (SELECT bank_name || ':' || phone FROM remittance_beneficiaries WHERE operation_id = v_op AND beneficiary_type = 'mexico_retiro'), 'BBVA:5215512345678');
  PERFORM pg_temp.m_eq('9 cuban card on mexico op', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'cuban_card', 'name', 'X', 'card_number', c_card, 'amount', 1, 'currency', 'CUP'), c.usr), '22023');
  SELECT * INTO c FROM pg_temp.m_conv(6);
  v_op := pg_temp.m_op(c, 'remesa', NULL, 13000);
  PERFORM pg_temp.m_eq('9 mexico type on remesa', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'mexico_cuenta', 'name', 'X', 'clabe', c_clabe, 'bank_name', 'BBVA'), c.usr), '22023');
  PERFORM pg_temp.m_eq('9 clabe on a card row', pg_temp.m_add(v_op, jsonb_build_object('beneficiary_type', 'cuban_card', 'name', 'X', 'card_number', c_card, 'amount', 10, 'currency', 'CUP', 'clabe', c_clabe), c.usr), '22023');

  -- 10 panel correction
  SELECT * INTO c FROM pg_temp.m_conv(7);
  v_op := pg_temp.m_op(c, 'mexico', NULL, 13000);
  v_cu := pg_temp.m_ben(v_op, 'mexico_cuenta', 'PRUEBA Maria Mex', NULL, NULL, c_clabe, 'Banco Azteca', 1);
  v_re := pg_temp.m_ben(v_op, 'mexico_retiro', 'PRUEBA Juan Mex', NULL, '5215512345678', NULL, 'Coppel', 2);
  PERFORM pg_temp.m_eq('10 bad clabe', pg_temp.m_fix(v_cu, '{"clabe":"123"}'::jsonb, c.usr), '22023');
  PERFORM pg_temp.m_eq('10 card on cuenta', pg_temp.m_fix(v_cu, jsonb_build_object('card_number', c_card), c.usr), '22023');
  PERFORM pg_temp.m_eq('10 amount on cuenta', pg_temp.m_fix(v_cu, '{"amount":10}'::jsonb, c.usr), '22023');
  PERFORM pg_temp.m_eq('10 blank bank', pg_temp.m_fix(v_cu, '{"bank_name":" "}'::jsonb, c.usr), '22023');
  PERFORM pg_temp.m_eq('10 blank name', pg_temp.m_fix(v_cu, '{"name":""}'::jsonb, c.usr), '22023');
  PERFORM pg_temp.m_eq('10 clabe on retiro', pg_temp.m_fix(v_re, jsonb_build_object('clabe', c_clabe2), c.usr), '22023');
  PERFORM pg_temp.m_eq('10 retiro Banorte', pg_temp.m_fix(v_re, '{"bank_name":"Banorte"}'::jsonb, c.usr), '22023');
  PERFORM pg_temp.m_eq('10 retiro phone cleared', pg_temp.m_fix(v_re, '{"phone":null}'::jsonb, c.usr), '22023');
  PERFORM pg_temp.m_eq('10 cuenta fixed', pg_temp.m_fix(v_cu, jsonb_build_object('clabe', c_clabe2, 'bank_name', 'Mercado Pago', 'name', 'PRUEBA Maria Lopez', 'phone', '5215500000001'), c.usr), 'ok');
  PERFORM pg_temp.m_eq('10 old replaced', (SELECT status FROM remittance_beneficiaries WHERE id = v_cu), 'reemplazado');
  PERFORM pg_temp.m_eq('10 new row', (SELECT clabe || ':' || bank_name || ':' || name || ':' || phone FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'mexico_cuenta'),
                       c_clabe2 || ':Mercado Pago:PRUEBA Maria Lopez:5215500000001');
  PERFORM pg_temp.m_eq('10 retiro bank fixed', pg_temp.m_fix(v_re, '{"bank_name":"bbva"}'::jsonb, c.usr), 'ok');
  PERFORM pg_temp.m_eq('10 retiro bank stored', (SELECT bank_name FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'mexico_retiro'), 'BBVA');
  PERFORM pg_temp.m_eq('10 card row clabe refused', pg_temp.m_fix(pg_temp.m_ben(pg_temp.m_op(c, 'remesa', 'cuban_card', 100), 'cuban_card', 'X', c_card, '53555551', NULL, NULL, 1), jsonb_build_object('clabe', c_clabe), c.usr), '22023');

  -- 11 conversation operations list (read as the account owner)
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  PERFORM pg_temp.m_eq('11 mexico listed', (SELECT string_agg(DISTINCT operation_service_type, ',') FROM crm_operaciones_de_conversacion(c.conv) WHERE operation_id IS NOT NULL AND operation_id = v_op), 'mexico');
  PERFORM pg_temp.m_eq('11 clabe and bank returned',
    (SELECT string_agg(coalesce(beneficiary_clabe, '-') || '/' || coalesce(beneficiary_bank_name, '-'), ',' ORDER BY beneficiary_position)
       FROM crm_operaciones_de_conversacion(c.conv) WHERE operation_id = v_op),
    c_clabe2 || '/Mercado Pago,-/BBVA');
  PERFORM set_config('request.jwt.claims', '', true);

  -- 12 agent tool
  SELECT * INTO c FROM pg_temp.m_conv(8);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Banco Azteca', 'PRUEBA Maria Mex', NULL, 'agent:registrar_destinatario_mexico n8n:77');
  PERFORM pg_temp.m_eq('12 no operation', (v_r->>'ok') || ':' || (v_r->>'mensaje' LIKE '%No hay un envio a Mexico abierto%')::text, 'false:true');
  v_op := pg_temp.m_op(c, 'mexico', NULL, 13000);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '1234', 'Banco Azteca', 'PRUEBA Maria Mex', NULL, NULL);
  PERFORM pg_temp.m_eq('12 bad clabe', v_r->>'ok', 'false');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'Banorte', 'PRUEBA Juan Mex', '5215512345678', NULL);
  PERFORM pg_temp.m_eq('12 bad store', v_r->>'ok', 'false');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Banco Azteca', 'PRUEBA Maria Mex', NULL, 'agent:registrar_destinatario_mexico n8n:77');
  PERFORM pg_temp.m_eq('12 saved', v_r->>'ok', 'true');
  v_cu := (v_r->>'beneficiary_id')::uuid;
  PERFORM pg_temp.m_eq('12 source', (SELECT source FROM remittance_beneficiaries WHERE id = v_cu), 'agente');
  PERFORM pg_temp.m_eq('12 rail', (SELECT delivery_method FROM remittance_operations WHERE id = v_op), 'mexico_cuenta');
  PERFORM pg_temp.m_eq('12 actor from p_exec', (SELECT actor FROM remittance_admin_audit WHERE row_id = v_cu AND action = 'agent_mexico_recipient_registered'), 'agent:registrar_destinatario_mexico');
  PERFORM pg_temp.m_eq('12 exec kept', (SELECT reason FROM remittance_admin_audit WHERE row_id = v_cu AND action = 'agent_mexico_recipient_registered'), 'agent:registrar_destinatario_mexico n8n:77');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '0123-4567-8901-234567', 'Banco Azteca', 'PRUEBA Maria Mex Lopez', '5215500000002', 'agent:otra_herramienta n8n:78');
  PERFORM pg_temp.m_eq('12 dedupe same row', (v_r->>'beneficiary_id')::uuid::text, v_cu::text);
  PERFORM pg_temp.m_eq('12 dedupe one row', pg_temp.m_vig(v_op), 'mexico_cuenta:1');
  PERFORM pg_temp.m_eq('12 dedupe updated', (SELECT name || ':' || phone FROM remittance_beneficiaries WHERE id = v_cu), 'PRUEBA Maria Mex Lopez:5215500000002');
  PERFORM pg_temp.m_eq('12 custom actor', (SELECT actor FROM remittance_admin_audit WHERE row_id = v_cu AND reason LIKE '%n8n:78'), 'agent:otra_herramienta');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_retiro', NULL, 'coppel', 'PRUEBA Juan Mex', '+52 1 55 1234 5678', 'sin prefijo');
  PERFORM pg_temp.m_eq('12 retiro saved', v_r->>'ok', 'true');
  PERFORM pg_temp.m_eq('12 retiro rail', (SELECT delivery_method FROM remittance_operations WHERE id = v_op), 'mexico_retiro');
  PERFORM pg_temp.m_eq('12 default actor', (SELECT actor FROM remittance_admin_audit WHERE row_id = (v_r->>'beneficiary_id')::uuid), 'agent:registrar_destinatario_mexico');
  PERFORM pg_temp.m_eq('12 complete text', (v_r->>'mensaje' LIKE '%completos%')::text, 'true');
  PERFORM pg_temp.m_eq('12 service_role only',
    has_function_privilege('authenticated', 'cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text)', 'EXECUTE')::text || ':' ||
    has_function_privilege('anon', 'cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text)', 'EXECUTE')::text || ':' ||
    has_function_privilege('service_role', 'cerebro_guardar_beneficiario_mexico(uuid,text,text,text,text,text,text)', 'EXECUTE')::text, 'false:false:true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
