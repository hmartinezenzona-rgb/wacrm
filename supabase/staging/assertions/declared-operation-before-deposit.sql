\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 275 (the recipient writers open the DECLARED operation before any deposit). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA declarada N', phones 5990275xxxx, fake CLABE / card / accounts.
-- odd/notes/db-tools-progress.md (275, gap 2 of the S5b measurement: M2/M3 "No hay un envio a Mexico abierto").
-- Cases (number = label in the failure message):
--   1  declared mexico + no operation: cerebro_guardar_beneficiario_mexico opens ONE mexico operation (0 GYD, collecting,
--      MXN, no lock on its service), saves the recipient, a second call opens nothing more; the later deposit is
--      attached to it ('movido') and no second operation exists
--   2  no declaration: the Mexico tool still refuses with its message and nothing is created
--   3  declared efectivo_usd + no operation: crm_registrar_datos_entrega_efectivo opens the cash operation (remesa,
--      delivery_method efectivo_usd) with its recipient; the deposit joins it; undeclared it still raises 22023
--   4  declared zelle: cerebro_guardar_zelle (tool shape, no p_op) opens a remesa typed zelle; the deposit joins it
--   5  declared clasica: cerebro_guardar_beneficiario opens a remesa typed clasica (rail clasica); a second call writes on it
--   6  declared recarga (promo running): crm_registrar_numeros_recarga opens the recarga; the 6,200 deposit joins it
--   7  declared mexico but a card arrives: no mexico operation is opened for card data (a plain remesa as before)
-- =====================================================================

CREATE FUNCTION pg_temp.d_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990275' || lpad(p_n::text, 4, '0'), 'PRUEBA declarada ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.d_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

CREATE FUNCTION pg_temp.d_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(o.service_type || ':' || coalesce(o.delivery_method, '-') || '/' || coalesce(o.quoted_source_amount::int::text, '-'),
                             ';' ORDER BY o.created_at, o.id), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.d_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

DO $$
DECLARE
  c record; v_r jsonb; v_op uuid; v_acc text; v_state text; v_hoy date := (now() AT TIME ZONE 'America/Guyana')::date;
  c_clabe constant text := '012345678901234567';
  c_card  constant text := '9999000000000005';
BEGIN
  -- a promo running whose recarga price is 6,200 (same fixture as 267)
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, v_hoy - 1, v_hoy + 2, 'ASSERT 275', 'https://assert.invalid/275', 'assert', md5('assert-275-vigente'), 'confirmada');
  IF (SELECT precio_gyd FROM cerebro_promo_vigente()) IS DISTINCT FROM 6200 THEN RAISE EXCEPTION 'fixture: promo price is not 6200'; END IF;

  -- 1 Mexico
  SELECT * INTO c FROM pg_temp.d_conv(1);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:declarar_servicio');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Mercado Pago', 'Ana Perez', NULL, 'agent:registrar_destinatario_mexico n8n:1');
  PERFORM pg_temp.d_eq('1 saved', v_r->>'ok', 'true');
  PERFORM pg_temp.d_eq('1 one mexico operation, 0 GYD', pg_temp.d_ops(c.conv), 'mexico:mexico_cuenta/0');
  SELECT o.status || '|' || coalesce(o.destination_currency, '-') || '|' || (coalesce(o.admin_locked_fields, '{}'::jsonb) ? 'service_type')::text
    INTO v_state FROM remittance_operations o WHERE o.conversation_id = c.conv;
  PERFORM pg_temp.d_eq('1 state', v_state, 'collecting_information|MXN|false');
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Mercado Pago', 'Ana Perez Lopez', NULL, 'agent:registrar_destinatario_mexico n8n:2');
  PERFORM pg_temp.d_eq('1 second call, no second operation', pg_temp.d_ops(c.conv), 'mexico:mexico_cuenta/0');
  PERFORM pg_temp.d_eq('1 deposit joins', (SELECT accion FROM pg_temp.d_registra(c.conv, 13000, '27500001')), 'movido');
  PERFORM pg_temp.d_eq('1 deposit on the mexico operation', pg_temp.d_ops(c.conv), 'mexico:mexico_cuenta/13000');
  PERFORM pg_temp.d_eq('1 recipient kept', (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
                         WHERE o.conversation_id = c.conv AND b.status = 'vigente' AND b.beneficiary_type = 'mexico_cuenta'), '1');

  -- 2 undeclared Mexico
  SELECT * INTO c FROM pg_temp.d_conv(2);
  v_r := cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Mercado Pago', 'Ana Perez', NULL, NULL);
  PERFORM pg_temp.d_eq('2 refused', v_r->>'ok', 'false');
  PERFORM pg_temp.d_eq('2 mensaje', (v_r->>'mensaje' LIKE 'No hay un envio a Mexico abierto%')::text, 'true');
  PERFORM pg_temp.d_eq('2 nothing created', pg_temp.d_ops(c.conv), '');

  -- 3 cash
  SELECT * INTO c FROM pg_temp.d_conv(3);
  BEGIN
    PERFORM crm_registrar_datos_entrega_efectivo(c.conv, '53821203', 'Calle 10 numero 5, Bayamo', NULL, 'Rosa Gomez');
    RAISE EXCEPTION 'case 3 undeclared: expected 22023';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  PERFORM pg_temp.d_eq('3 undeclared creates nothing', pg_temp.d_ops(c.conv), '');
  PERFORM cerebro_declarar_servicio(c.conv, 'efectivo_usd', 'agent:declarar_servicio');
  v_r := crm_registrar_datos_entrega_efectivo(c.conv, '53821203', 'Calle 10 numero 5, Bayamo', NULL, 'Rosa Gomez');
  PERFORM pg_temp.d_eq('3 cash operation', pg_temp.d_ops(c.conv), 'remesa:efectivo_usd/0');
  PERFORM pg_temp.d_eq('3 recipient', v_r->>'name' || '|' || (v_r->>'phone'), 'Rosa Gomez|53821203');
  PERFORM pg_temp.d_eq('3 deposit joins', (SELECT accion FROM pg_temp.d_registra(c.conv, 29000, '27500003')), 'movido');
  PERFORM pg_temp.d_eq('3 deposit on it', pg_temp.d_ops(c.conv), 'remesa:efectivo_usd/29000');

  -- 4 zelle
  SELECT * INTO c FROM pg_temp.d_conv(4);
  PERFORM cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio');
  PERFORM cerebro_guardar_zelle(c.conv, 'Maria Lopez', 'maria@example.com', 'e4');
  PERFORM pg_temp.d_eq('4 zelle operation', pg_temp.d_ops(c.conv), 'remesa:zelle/0');
  PERFORM pg_temp.d_eq('4 deposit joins', (SELECT accion FROM pg_temp.d_registra(c.conv, 26000, '27500004')), 'movido');
  PERFORM pg_temp.d_eq('4 deposit on it', pg_temp.d_ops(c.conv), 'remesa:zelle/26000');

  -- 5 clasica
  SELECT * INTO c FROM pg_temp.d_conv(5);
  PERFORM cerebro_declarar_servicio(c.conv, 'clasica', 'agent:declarar_servicio');
  PERFORM cerebro_guardar_beneficiario(c.conv, '', c_card, '53821203', 'e5');
  PERFORM pg_temp.d_eq('5 clasica operation', pg_temp.d_ops(c.conv), 'remesa:clasica/0');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = c.conv;
  PERFORM pg_temp.d_eq('5 rail', cerebro_riel_op(v_op), 'clasica');
  PERFORM cerebro_guardar_beneficiario(c.conv, 'Pedro', NULL, NULL, 'e5b');
  PERFORM pg_temp.d_eq('5 second call same operation', pg_temp.d_ops(c.conv), 'remesa:clasica/0');
  PERFORM pg_temp.d_eq('5 deposit joins', (SELECT accion FROM pg_temp.d_registra(c.conv, 26000, '27500005')), 'movido');

  -- 6 recarga
  SELECT * INTO c FROM pg_temp.d_conv(6);
  PERFORM cerebro_declarar_servicio(c.conv, 'recarga', 'agent:declarar_servicio');
  PERFORM crm_registrar_numeros_recarga(c.conv, '55599180', false, 'agent:registrar_numeros_recarga');
  PERFORM pg_temp.d_eq('6 recarga operation', pg_temp.d_ops(c.conv), 'recarga:-/6200');
  PERFORM pg_temp.d_eq('6 deposit joins', (SELECT accion FROM pg_temp.d_registra(c.conv, 6200, '27500006')), 'movido');
  PERFORM pg_temp.d_eq('6 deposit on it', pg_temp.d_ops(c.conv), 'recarga:-/6200');

  -- 7 declared mexico, card data: no mexico operation
  SELECT * INTO c FROM pg_temp.d_conv(7);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:declarar_servicio');
  PERFORM cerebro_guardar_beneficiario(c.conv, '', c_card, '53821203', 'e7');
  PERFORM pg_temp.d_eq('7 no mexico operation for card data', (SELECT count(*)::text FROM remittance_operations o
                         WHERE o.conversation_id = c.conv AND o.service_type = 'mexico'), '0');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
