\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 292 (owner rule: extend the tool that owns the domain): crm_registrar_numeros_recarga(..., 'quitar') that removes the LAST number
-- of a recarga that holds no money cancels the empty recarga in the same call (so the bot does not leave an orphan open operation); with money, or a
-- lock a person left, it stays open and says a person handles it.
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA quitar N', phones 5990292xxxx.
-- Cases:
--   1  last number of an empty recarga (next to a mexico + cash send) -> recarga cancelled in the call, message says so, audit agent_operation_cancel with the actor, others untouched
--   2  two numbers, one removed -> the recarga stays open
--   3  the recarga holds a verified deposit -> removing its last number keeps it open, message says a person handles the money, no cancel audit
--   4  numbers locked by a person -> the old refusal stands, nothing changes
--   5  another human lock on the recarga (delivery_method) -> numbers leave, recarga stays open, message says a person handles it
--   6  a number that was not in the recarga -> nothing removed, nothing cancelled
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990292' || lpad(p_n::text, 4, '0'), 'PRUEBA quitar ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_verifica(p_conv uuid, p_monto numeric, p_ref text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test292', now());
  SELECT r.deal_id INTO v_id FROM pg_temp.p_registra(p_conv, p_monto, p_ref) r;
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
END $f$;

-- the three operations the way the tools create them, in the order of the replay: mexico (declared, two recipients 50/50 USD), cash (agregar_servicio), recarga (numbers)
CREATE FUNCTION pg_temp.p_escenario(p_n int) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE c record; r jsonb;
BEGIN
  SELECT * INTO c FROM pg_temp.p_conv(p_n);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:declarar_servicio');
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '0123456789012345' || lpad(p_n::text, 2, '0'), 'Mercado Pago', 'PRUEBA Ana', NULL, NULL, p_monto => 50);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '9876543210987654' || lpad(p_n::text, 2, '0'), 'Banco Azteca', 'PRUEBA Luis', NULL, NULL, p_agregar => true, p_monto => 50);
  -- one transaction = one now(): space the creation times the way the real conversation did (minutes apart, in the order of the calls)
  UPDATE remittance_operations SET created_at = now() - interval '30 minutes' WHERE conversation_id = c.conv AND service_type = 'mexico';
  r := cerebro_aplicar_servicio(c.conv, 'efectivo_usd', 'agregar', 'agent:agregar_servicio', NULL);
  UPDATE remittance_operations SET created_at = now() - interval '20 minutes' WHERE conversation_id = c.conv AND service_type = 'remesa';
  PERFORM crm_registrar_numeros_recarga(c.conv, '5550' || lpad(p_n::text, 4, '0'), true, 'agent:registrar_numeros_recarga');
  UPDATE remittance_operations SET created_at = now() - interval '10 minutes' WHERE conversation_id = c.conv AND service_type = 'recarga';
  RETURN c.conv;
END $f$;

CREATE FUNCTION pg_temp.p_op(p_conv uuid, p_riel text) RETURNS uuid
LANGUAGE sql AS $f$
  SELECT o.id FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled') AND cerebro_riel_op(o.id) = p_riel ORDER BY o.created_at LIMIT 1;
$f$;

CREATE FUNCTION pg_temp.p_holder(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(DISTINCT cerebro_riel_op(d.operation_id), ','), '-') FROM depositos_mmg d JOIN remittance_operations o ON o.id = d.operation_id
   WHERE o.conversation_id = p_conv AND d.anulado_en IS NULL AND d.descartado_en IS NULL;
$f$;

CREATE FUNCTION pg_temp.p_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY cerebro_riel_op(o.id)), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;


CREATE FUNCTION pg_temp.p_rec(p_n int, p_nums text) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE c record; r text;
BEGIN
  SELECT * INTO c FROM pg_temp.p_conv(p_n);
  r := crm_registrar_numeros_recarga(c.conv, p_nums, true, 'agent:registrar_numeros_recarga');
  RETURN c.conv;
END $f$;

DO $$
DECLARE
  v_conv uuid; v_a text; v_rec uuid; v_n int;
BEGIN
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v292', 'assert', md5('assert-vigente-292'), 'confirmada');

  -- 1 last number of an empty recarga, next to the other operations of the send
  v_conv := pg_temp.p_escenario(1);
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM pg_temp.p_eq('1 recarga has its number', (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_rec AND status = 'vigente'), '1');
  v_a := crm_registrar_numeros_recarga(v_conv, '55500001', false, 'agent:registrar_numeros_recarga q1', 'quitar');
  PERFORM pg_temp.p_eq('1 recarga cancelled in the call: ' || v_a, (SELECT status FROM remittance_operations WHERE id = v_rec), 'cancelled');
  PERFORM pg_temp.p_eq('1 message tells the bot: ' || v_a, (v_a ILIKE '%cancel%' AND v_a ILIKE '%recarga%')::text, 'true');
  PERFORM pg_temp.p_eq('1 the other operations are untouched', pg_temp.p_ops(v_conv), 'efectivo_usd/0;mexico/0');
  PERFORM pg_temp.p_eq('1 audit actor', (SELECT actor FROM remittance_admin_audit WHERE row_id = v_rec AND action = 'agent_operation_cancel'),
                       'agent:registrar_numeros_recarga q1');
  PERFORM pg_temp.p_eq('1 number audit still written', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_rec AND action = 'agent_recharge_number_removed'), '1');

  -- 2 two numbers, one removed
  v_conv := pg_temp.p_rec(2, '55500002 55500003');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  v_a := crm_registrar_numeros_recarga(v_conv, '55500002', false, 'agent:registrar_numeros_recarga q2', 'quitar');
  PERFORM pg_temp.p_eq('2 stays open: ' || v_a, ((SELECT status FROM remittance_operations WHERE id = v_rec) NOT IN ('cancelled', 'completed'))::text, 'true');
  PERFORM pg_temp.p_eq('2 no cancel audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_rec AND action = 'agent_operation_cancel'), '0');

  -- 3 the recarga holds a verified deposit
  v_conv := pg_temp.p_rec(3, '55500004');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM pg_temp.p_verifica(v_conv, 6200, '90409990292003');
  PERFORM pg_temp.p_eq('3 the recarga holds the money', _cerebro_op_tiene_dinero(v_rec)::text, 'true');
  v_a := crm_registrar_numeros_recarga(v_conv, '55500004', false, 'agent:registrar_numeros_recarga q3', 'quitar');
  PERFORM pg_temp.p_eq('3 stays open: ' || v_a, ((SELECT status FROM remittance_operations WHERE id = v_rec) <> 'cancelled')::text, 'true');
  PERFORM pg_temp.p_eq('3 a person handles the money: ' || v_a, (v_a ILIKE '%una persona%' AND v_a ILIKE '%dinero%')::text, 'true');
  PERFORM pg_temp.p_eq('3 no cancel audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_rec AND action = 'agent_operation_cancel'), '0');
  PERFORM pg_temp.p_eq('3 the deposit is still there', _cerebro_op_tiene_dinero(v_rec)::text, 'true');

  -- 4 numbers locked by a person: the old refusal
  v_conv := pg_temp.p_rec(4, '55500005');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('beneficiaries', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_rec;
  PERFORM set_config('wacrm.origin', '', true);
  v_a := crm_registrar_numeros_recarga(v_conv, '55500005', false, 'agent:registrar_numeros_recarga q4', 'quitar');
  PERFORM pg_temp.p_eq('4 refused: ' || v_a, (v_a LIKE 'los numeros de esta recarga los gestiona una persona%')::text, 'true');
  PERFORM pg_temp.p_eq('4 still open with its number', (SELECT status <> 'cancelled' FROM remittance_operations WHERE id = v_rec)::text || (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_rec AND status = 'vigente')::text, 'true1');

  -- 5 another human lock
  v_conv := pg_temp.p_rec(5, '55500006');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('delivery_method', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_rec;
  PERFORM set_config('wacrm.origin', '', true);
  v_a := crm_registrar_numeros_recarga(v_conv, '55500006', false, 'agent:registrar_numeros_recarga q5', 'quitar');
  PERFORM pg_temp.p_eq('5 stays open: ' || v_a, (SELECT status <> 'cancelled' FROM remittance_operations WHERE id = v_rec)::text, 'true');
  PERFORM pg_temp.p_eq('5 a person handles it: ' || v_a, (v_a ILIKE '%una persona%')::text, 'true');

  -- 6 a number that was not there
  v_conv := pg_temp.p_rec(6, '55500007');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  v_a := crm_registrar_numeros_recarga(v_conv, '55509999', false, 'agent:registrar_numeros_recarga q6', 'quitar');
  PERFORM pg_temp.p_eq('6 nothing cancelled: ' || v_a, (SELECT status <> 'cancelled' FROM remittance_operations WHERE id = v_rec)::text, 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
