\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 353 (cerebro_guardar_beneficiario, the function behind the n8n tool
-- gestionar_beneficiario, must not open a card operation on a cash send).
-- Self-reverting: BEGIN ... RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Fictitious data only.
--   a. cash op open + call without card: no new operation, no cuban_card beneficiary, name and phone filled on the
--      cash beneficiary, message says "NO pidas tarjeta" and lists what is missing
--   b. cash beneficiary already has a name: not overwritten
--   c. no cash op (card send): behaves as before (a cuban_card beneficiary is created)
--   d. call WITH a card while a cash op is open: today's behaviour (card flow)
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
    VALUES (gen_random_uuid(), v_user, '5990353' || lpad(p_n::text, 4, '0'), 'PRUEBA 353 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.t_cash(p_conv record, p_monto numeric, p_tx text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type,
                                     delivery_method, source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), p_conv.acc, p_conv.conv, p_conv.contact, 'ready_to_transfer', 'remesa',
          'efectivo_usd', 'GYD', p_monto)
  RETURNING id INTO v_op;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES (p_tx, p_monto, 'GYD', 'prueba', now(), now(), v_op);
  RETURN v_op;
END $f$;

DO $$
DECLARE
  c        record;
  v_op     uuid;
  v_id     uuid;
  v_accion text;
  v_b      remittance_beneficiaries%ROWTYPE;
BEGIN
  -- a. cash op open, call without card.
  SELECT * INTO c FROM pg_temp.t_conv(1);
  v_op := pg_temp.t_cash(c, 5000, 'PRUEBA35301');
  SELECT g.deal_id, g.accion INTO v_id, v_accion
    FROM cerebro_guardar_beneficiario(c.conv, 'Persona Ficticia Uno', '', '53981203', 'test-353-a') g;
  PERFORM pg_temp.t_eq('a1 no new operation',
    (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '1');
  PERFORM pg_temp.t_eq('a2 no card beneficiary',
    (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
      WHERE o.conversation_id = c.conv AND b.beneficiary_type <> 'efectivo_usd'), '0');
  SELECT * INTO v_b FROM remittance_beneficiaries WHERE operation_id = v_op AND beneficiary_type = 'efectivo_usd' AND status = 'vigente';
  PERFORM pg_temp.t_eq('a3 name filled', v_b.name, 'Persona Ficticia Uno');
  PERFORM pg_temp.t_eq('a4 phone filled', coalesce(v_b.phone LIKE '%53981203%', false)::text, 'true');
  PERFORM pg_temp.t_eq('a5 says do not ask for a card', (v_accion LIKE '%NO pidas tarjeta%')::text, 'true');
  PERFORM pg_temp.t_eq('a6 lists what is missing', (v_accion LIKE '%direccion%' AND v_accion LIKE '%carnet%')::text, 'true');
  PERFORM pg_temp.t_eq('a7 audit written', (SELECT count(*)::text FROM remittance_admin_audit
      WHERE row_id = v_b.id AND action = 'automation_cash_delivery_data_registered'), '1');
  PERFORM pg_temp.t_eq('a8 returns the operation', v_id::text, v_op::text);

  -- b. an existing name is never overwritten; an existing phone neither.
  SELECT * INTO c FROM pg_temp.t_conv(2);
  v_op := pg_temp.t_cash(c, 5000, 'PRUEBA35302');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, position, status, source, block_index)
  VALUES (v_op, 'efectivo_usd', 'Nombre Previo Ficticio', '53000000', 1, 'vigente', 'reparto_auto', 1);
  SELECT g.deal_id, g.accion INTO v_id, v_accion
    FROM cerebro_guardar_beneficiario(c.conv, 'Otro Nombre Ficticio', '', '53981204', 'test-353-b') g;
  SELECT * INTO v_b FROM remittance_beneficiaries WHERE operation_id = v_op AND beneficiary_type = 'efectivo_usd' AND status = 'vigente';
  PERFORM pg_temp.t_eq('b1 name kept', v_b.name, 'Nombre Previo Ficticio');
  PERFORM pg_temp.t_eq('b2 phone kept', v_b.phone, '53000000');
  PERFORM pg_temp.t_eq('b3 still says cash', (v_accion LIKE '%NO pidas tarjeta%')::text, 'true');
  PERFORM pg_temp.t_eq('b4 one live cash beneficiary',
    (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '1');

  -- c. no cash op: a card send behaves as before (a cuban_card beneficiary is created).
  SELECT * INTO c FROM pg_temp.t_conv(3);
  SELECT g.deal_id, g.accion INTO v_id, v_accion
    FROM cerebro_guardar_beneficiario(c.conv, 'Persona Ficticia Tres', '', '53981205', 'test-353-c') g;
  PERFORM pg_temp.t_eq('c1 card beneficiary created',
    (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
      WHERE o.conversation_id = c.conv AND b.beneficiary_type = 'cuban_card'), '1');
  PERFORM pg_temp.t_eq('c2 asks for the card', (v_accion LIKE '%FALTA%tarjeta%')::text, 'true');
  PERFORM pg_temp.t_eq('c3 no cash message', (v_accion LIKE '%NO pidas tarjeta%')::text, 'false');

  -- d. a card while a cash op is open: today's card flow (the cash guard does not apply).
  SELECT * INTO c FROM pg_temp.t_conv(4);
  v_op := pg_temp.t_cash(c, 5000, 'PRUEBA35304');
  SELECT g.deal_id, g.accion INTO v_id, v_accion
    FROM cerebro_guardar_beneficiario(c.conv, 'Persona Ficticia Cuatro', '9205123412341234', '53981206', 'test-353-d') g;
  PERFORM pg_temp.t_eq('d1 no cash message', (v_accion LIKE '%NO pidas tarjeta%')::text, 'false');
  PERFORM pg_temp.t_eq('d2 card saved', (v_accion LIKE '%9205123412341234%')::text, 'true');
  PERFORM pg_temp.t_eq('d3 card beneficiary exists',
    (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
      WHERE o.conversation_id = c.conv AND b.beneficiary_type = 'cuban_card'), '1');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
