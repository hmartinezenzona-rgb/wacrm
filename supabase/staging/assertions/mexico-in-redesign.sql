\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 273 (México in the service redesign: declarar / resolver / aplicar / registrar_deposito / mixed
-- split accept 'mexico'; cerebro_riel_op('mexico'); cerebro_servicios.requiere_humano = false for 'mexico').
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Prerequisites: 265-268 and 271 (México recipients). The 13,000 minimum of the resolver is the config key
-- minimo_gyd_mexico (default 13,000), the same one 272 reads in cerebro_minimo_gyd.
-- Synthetic fixtures only: contacts 'PRUEBA mexico2 N', phones 5990273xxxx, refs 10409990273xxx, fake CLABE.
-- odd/tasks/service-resolution.md (M4). Cases (number = label in the failure message):
--   1  cerebro_servicios.requiere_humano is false for 'mexico'; cerebro_declarar_servicio accepts 'mexico' and still
--      refuses an unknown service; cerebro_riel_op of a mexico operation is 'mexico'
--   2  resolver: declared mexico + 13,000, no operation -> nueva_operacion, servicio mexico
--   3  declared mexico + 13,000 deposit -> ONE mexico operation (destination_currency MXN, 13,000 GYD)
--   4  declared mexico + 6,000 -> deposito_bajo_minimo, minimo_gyd 13000, faltante_gyd 7000, plain-Spanish mensaje
--   5  a deposit joins an open México operation (with its recipient): same operation, no second one
--   6  cambiar remesa -> mexico when the deposit covers 13,000: the remesa becomes mexico (MXN, delivery_method NULL);
--      below the minimum nothing changes (deposito_bajo_minimo)
--   7  mixed: a 18,000 card (CUP) remesa + agregar mexico -> a group with the card part 5,000 and the mexico part 13,000
--   8  convertir keeps México recipients out of the way: a remesa with a cuban card converts to mexico (card recipient
--      retired), and a mexico operation converts back to a card rail (mexico recipient retired)
-- =====================================================================

CREATE FUNCTION pg_temp.x_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990273' || lpad(p_n::text, 4, '0'), 'PRUEBA mexico2 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.x_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

CREATE FUNCTION pg_temp.x_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(o.service_type || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY o.created_at, o.id), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.x_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

-- raw fixture insert (admin origin so the 096 guard does not lock the fixture's own columns)
CREATE FUNCTION pg_temp.x_rail(p_op uuid, p_rail text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('wacrm.origin', 'admin', true);
  PERFORM set_config('wacrm.actor', 'automation:test273', true);
  UPDATE remittance_operations SET delivery_method = p_rail WHERE id = p_op;
  PERFORM set_config('wacrm.origin', '', true);
  PERFORM set_config('wacrm.actor', '', true);
END $f$;

DO $$
DECLARE
  c record; v_op uuid; v_r jsonb; v_reg record; v_o remittance_operations%ROWTYPE; v_card uuid; v_mx uuid;
  c_clabe constant text := '012345678901234567';
  c_cardno constant text := '9999000000000007';
BEGIN
  -- 1
  PERFORM pg_temp.x_eq('1 requiere_humano', (SELECT requiere_humano::text FROM cerebro_servicios WHERE clave = 'mexico'), 'false');
  SELECT * INTO c FROM pg_temp.x_conv(1);
  PERFORM pg_temp.x_eq('1 declarar mexico', (cerebro_declarar_servicio(c.conv, 'mexico', 'agent:test') ->> 'ok'), 'true');
  PERFORM pg_temp.x_eq('1 declarar unknown', (cerebro_declarar_servicio(c.conv, 'marte', 'agent:test') ->> 'motivo'), 'servicio_invalido');
  PERFORM pg_temp.x_eq('1 declared stored', (SELECT servicio FROM cerebro_servicio_declarado WHERE conversation_id = c.conv), 'mexico');
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
    VALUES (c.acc, c.conv, c.contact, 'collecting_information', 'mexico', 'mexico_cuenta', 'GYD', 0) RETURNING id INTO v_op;
  PERFORM pg_temp.x_eq('1 riel', cerebro_riel_op(v_op), 'mexico');

  -- 2
  SELECT * INTO c FROM pg_temp.x_conv(2);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:test');
  v_r := cerebro_resolver_servicio(c.conv, 'mexico', 'cambiar', 13000);
  PERFORM pg_temp.x_eq('2 motivo', v_r ->> 'motivo', 'nueva_operacion');
  PERFORM pg_temp.x_eq('2 servicio', v_r ->> 'servicio', 'mexico');
  v_r := cerebro_resolver_servicio(c.conv, 'mexico', 'cambiar', 12999);
  PERFORM pg_temp.x_eq('2 just below', v_r ->> 'motivo', 'deposito_bajo_minimo');

  -- 3
  SELECT * INTO c FROM pg_temp.x_conv(3);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:test');
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 13000, '10409990273001');
  PERFORM pg_temp.x_eq('3 accion', v_reg.accion, 'creado');
  PERFORM pg_temp.x_eq('3 one mexico op', pg_temp.x_ops(c.conv), 'mexico/13000');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_reg.deal_id;
  PERFORM pg_temp.x_eq('3 MXN', v_o.destination_currency, 'MXN');
  PERFORM pg_temp.x_eq('3 no amount stored', v_o.quoted_destination_amount::text, NULL);
  PERFORM pg_temp.x_eq('3 rail not known yet', v_o.delivery_method, NULL);

  -- 4
  SELECT * INTO c FROM pg_temp.x_conv(4);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:test');
  v_r := cerebro_resolver_servicio(c.conv, 'mexico', 'cambiar', 6000);
  PERFORM pg_temp.x_eq('4 motivo', v_r ->> 'motivo', 'deposito_bajo_minimo');
  PERFORM pg_temp.x_eq('4 minimo', v_r ->> 'minimo_gyd', '13000');
  PERFORM pg_temp.x_eq('4 faltante', v_r ->> 'faltante_gyd', '7000');
  PERFORM pg_temp.x_eq('4 mensaje', (v_r ->> 'mensaje' LIKE '%el envío a México%13,000 GYD%7,000 GYD%')::text, 'true');
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 6000, '10409990273002');
  PERFORM pg_temp.x_eq('4 op is mexico', pg_temp.x_ops(c.conv), 'mexico/6000');

  -- 5 the deposit joins the open México operation (recipient already saved)
  SELECT * INTO c FROM pg_temp.x_conv(5);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:test');
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, destination_currency, quoted_source_amount)
    VALUES (c.acc, c.conv, c.contact, 'collecting_information', 'mexico', 'GYD', 'MXN', 0) RETURNING id INTO v_op;
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Banco Azteca', 'PRUEBA Maria Mex', NULL, 'agent:test n8n:1');
  PERFORM pg_temp.x_eq('5 recipient', v_r ->> 'ok', 'true');
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 13000, '10409990273003');
  PERFORM pg_temp.x_eq('5 same op', v_reg.deal_id::text, v_op::text);
  PERFORM pg_temp.x_eq('5 accion', v_reg.accion, 'movido');
  PERFORM pg_temp.x_eq('5 one op', pg_temp.x_ops(c.conv), 'mexico/13000');
  PERFORM pg_temp.x_eq('5 recipient kept', (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '1');

  -- 6 cambiar remesa -> mexico
  SELECT * INTO c FROM pg_temp.x_conv(6);
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 13000, '10409990273004');
  v_op := v_reg.deal_id;
  PERFORM pg_temp.x_eq('6 starts remesa', pg_temp.x_ops(c.conv), 'remesa/13000');
  v_r := cerebro_aplicar_servicio(c.conv, 'mexico', 'cambiar', 'agent:test', 'n8n:2');
  PERFORM pg_temp.x_eq('6 aplicado', v_r ->> 'aplicado', 'true');
  PERFORM pg_temp.x_eq('6 now mexico', pg_temp.x_ops(c.conv), 'mexico/13000');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  PERFORM pg_temp.x_eq('6 MXN', v_o.destination_currency, 'MXN');
  PERFORM pg_temp.x_eq('6 rail null', v_o.delivery_method, NULL);
  SELECT * INTO c FROM pg_temp.x_conv(7);
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 6000, '10409990273005');
  v_r := cerebro_aplicar_servicio(c.conv, 'mexico', 'cambiar', 'agent:test', NULL);
  PERFORM pg_temp.x_eq('6 low aplicado', v_r ->> 'aplicado', 'false');
  PERFORM pg_temp.x_eq('6 low motivo', v_r ->> 'motivo', 'deposito_bajo_minimo');
  PERFORM pg_temp.x_eq('6 low unchanged', pg_temp.x_ops(c.conv), 'remesa/6000');

  -- 7 mixed card + México
  SELECT * INTO c FROM pg_temp.x_conv(8);
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 18000, '10409990273006');
  v_op := v_reg.deal_id;
  PERFORM pg_temp.x_rail(v_op, 'cuban_card');
  v_r := cerebro_aplicar_servicio(c.conv, 'mexico', 'agregar', 'agent:test', 'n8n:3');
  PERFORM pg_temp.x_eq('7 motivo', v_r ->> 'motivo', 'deposito_cubre_ambos');
  PERFORM pg_temp.x_eq('7 aplicado', v_r ->> 'aplicado', 'true');
  PERFORM pg_temp.x_eq('7 parts', (SELECT string_agg(o.service_type || '/' || coalesce(o.delivery_method, '-') || '/' || o.quoted_source_amount::int, ';' ORDER BY o.service_type)
                                      FROM remittance_operations o WHERE o.conversation_id = c.conv AND o.status NOT IN ('cancelled')),
                       'mexico/-/13000;remesa/cuban_card/5000');
  PERFORM pg_temp.x_eq('7 one group', (SELECT count(DISTINCT mixed_group_id)::text FROM remittance_operations WHERE conversation_id = c.conv AND status <> 'cancelled'), '1');
  PERFORM pg_temp.x_eq('7 mexico MXN', (SELECT destination_currency FROM remittance_operations WHERE conversation_id = c.conv AND service_type = 'mexico'), 'MXN');

  -- 8 conversions retire the recipients of the other rail
  SELECT * INTO c FROM pg_temp.x_conv(9);
  SELECT * INTO v_reg FROM pg_temp.x_registra(c.conv, 13000, '10409990273007');
  v_op := v_reg.deal_id;
  PERFORM pg_temp.x_rail(v_op, 'cuban_card');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, block_index, source, status)
    VALUES (v_op, 'cuban_card', 'PRUEBA Cuba', c_cardno, '53555552', 1, 1, 'test273', 'vigente') RETURNING id INTO v_card;
  v_r := cerebro_aplicar_servicio(c.conv, 'mexico', 'cambiar', 'agent:test', NULL);
  PERFORM pg_temp.x_eq('8 to mexico', pg_temp.x_ops(c.conv), 'mexico/13000');
  PERFORM pg_temp.x_eq('8 card retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_card), 'reemplazado');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Banco Azteca', 'PRUEBA Maria Mex', NULL, 'agent:test n8n:4');
  PERFORM pg_temp.x_eq('8 mexico recipient', v_r ->> 'ok', 'true');
  v_mx := (v_r ->> 'beneficiary_id')::uuid;
  v_r := cerebro_aplicar_servicio(c.conv, 'cuban_card', 'cambiar', 'agent:test', NULL);
  PERFORM pg_temp.x_eq('8 back to card', (SELECT service_type || '/' || delivery_method FROM remittance_operations WHERE id = v_op), 'remesa/cuban_card');
  PERFORM pg_temp.x_eq('8 mexico recipient retired', (SELECT status FROM remittance_beneficiaries WHERE id = v_mx), 'reemplazado');
  PERFORM pg_temp.x_eq('8 not MXN any more', (SELECT (destination_currency IS DISTINCT FROM 'MXN')::text FROM remittance_operations WHERE id = v_op), 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
