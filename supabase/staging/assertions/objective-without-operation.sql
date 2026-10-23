\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 278 (the send objective is kept without an operation once the agent declared a service). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA objetivo N', phones 5990278xxxx.
-- odd/notes/db-tools-progress.md (278, gap 4 of the S5b measurement: "NO se fijo nada: sin beneficiario ni comprobante").
-- Cases (number = label in the failure message):
--   1  no declaration, no operation, no recipient: a bare quote still fixes nothing (148 unchanged)
--   2  the agent declared a service (no operation, no recipient): the objective is persisted, with no operation, and the
--      deposit that comes later consumes it (operation_id set, saldo 0 for the exact amount)
--   3  a smaller deposit does not change the objective (the rest stays owed once crossed)
--   4  quote first, declaration later (the order the agent uses): declaring promotes the standing quote to the objective;
--      with no quote nothing is created; an objective already there is not overwritten
--   5  an open (empty) operation is a commitment too
--   6  an invalid declaration changes nothing
-- =====================================================================

CREATE FUNCTION pg_temp.o_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990278' || lpad(p_n::text, 4, '0'), 'PRUEBA objetivo ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.o_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

CREATE FUNCTION pg_temp.o_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

-- the objective row as "monto/operacion?/cerrado?"
CREATE FUNCTION pg_temp.o_obj(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce((SELECT o.monto::int::text || '/' || (o.operation_id IS NOT NULL)::text || '/' || (o.cerrado_en IS NOT NULL)::text
                     FROM cerebro_objetivo_envio o WHERE o.conversation_id = p_conv), 'none');
$f$;

DO $$
DECLARE
  c record; r record; v_op uuid;
BEGIN
  -- 1 bare quote
  SELECT * INTO c FROM pg_temp.o_conv(1);
  SELECT * INTO r FROM cerebro_fijar_objetivo(c.conv, 100, 'USD');
  PERFORM pg_temp.o_eq('1 refused', (r.accion LIKE 'NO se fijo nada: sin beneficiario ni comprobante%')::text, 'true');
  PERFORM pg_temp.o_eq('1 nothing stored', pg_temp.o_obj(c.conv), 'none');

  -- 2 declared service, no operation, no recipient
  SELECT * INTO c FROM pg_temp.o_conv(2);
  PERFORM cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio');
  SELECT * INTO r FROM cerebro_fijar_objetivo(c.conv, 100, 'USD');
  PERFORM pg_temp.o_eq('2 fixed', r.accion, 'objetivo fijado');
  PERFORM pg_temp.o_eq('2 stored without operation', pg_temp.o_obj(c.conv), '26000/false/false');
  PERFORM pg_temp.o_eq('2 no operation was created', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '0');
  SELECT deal_id INTO v_op FROM pg_temp.o_registra(c.conv, 26000, '27800001');
  PERFORM pg_temp.o_eq('2 consumed by the deposit', pg_temp.o_obj(c.conv), '26000/true/false');
  PERFORM pg_temp.o_eq('2 the operation owes the objective', (SELECT s.objetivo::int::text FROM cerebro_saldo_operacion(v_op) s), '26000');

  -- 3 smaller deposit
  SELECT * INTO c FROM pg_temp.o_conv(3);
  PERFORM cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio');
  PERFORM cerebro_fijar_objetivo(c.conv, 100, 'USD');
  SELECT deal_id INTO v_op FROM pg_temp.o_registra(c.conv, 13000, '27800002');
  PERFORM pg_temp.o_eq('3 objective 26000 on a 13000 deposit', (SELECT s.objetivo::int::text FROM cerebro_saldo_operacion(v_op) s), '26000');

  -- 4 quote first, declaration later
  SELECT * INTO c FROM pg_temp.o_conv(4);
  PERFORM cerebro_registrar_cotizacion(c.conv, 26000, 100, 'USD', 'calcular_usd');
  SELECT * INTO r FROM cerebro_fijar_objetivo(c.conv, 100, 'USD');
  PERFORM pg_temp.o_eq('4 quote alone fixes nothing', pg_temp.o_obj(c.conv), 'none');
  PERFORM pg_temp.o_eq('4 declare ok', cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio') ->> 'ok', 'true');
  PERFORM pg_temp.o_eq('4 declaring promoted the quote', pg_temp.o_obj(c.conv), '26000/false/false');
  PERFORM cerebro_registrar_cotizacion(c.conv, 52000, 200, 'USD', 'calcular_usd');
  PERFORM cerebro_declarar_servicio(c.conv, 'zelle', 'agent:declarar_servicio');
  PERFORM pg_temp.o_eq('4 an existing objective is not overwritten by declaring', pg_temp.o_obj(c.conv), '26000/false/false');
  SELECT * INTO c FROM pg_temp.o_conv(5);
  PERFORM cerebro_declarar_servicio(c.conv, 'clasica', 'agent:declarar_servicio');
  PERFORM pg_temp.o_eq('4 no quote, no objective', pg_temp.o_obj(c.conv), 'none');

  -- 5 an open empty operation is a commitment
  SELECT * INTO c FROM pg_temp.o_conv(6);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (c.acc, c.conv, c.contact, 'collecting_information', 'remesa', 'GYD', 0);
  SELECT * INTO r FROM cerebro_fijar_objetivo(c.conv, 15000, 'GYD');
  PERFORM pg_temp.o_eq('5 stored', pg_temp.o_obj(c.conv), '15000/false/false');

  -- 6 invalid declaration
  SELECT * INTO c FROM pg_temp.o_conv(7);
  PERFORM cerebro_registrar_cotizacion(c.conv, 26000, 100, 'USD', 'calcular_usd');
  PERFORM pg_temp.o_eq('6 invalid service', cerebro_declarar_servicio(c.conv, 'paypal', 'agent:declarar_servicio') ->> 'ok', 'false');
  PERFORM pg_temp.o_eq('6 nothing stored', pg_temp.o_obj(c.conv), 'none');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
