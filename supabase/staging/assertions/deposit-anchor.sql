\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 291 (pre-production finding: three open operations created BEFORE any deposit - Mexico with two recipients, cash USD, a recarga
-- opened by registrar_numeros_recarga - and the verified 55,000 GYD deposit landed on the RECARGA, the last implicit declaration; then repartir_envio
-- refused ("the operation's own service (recarga) must be one of the parts") and cancelling the recarga was refused (tiene_dinero)).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA ancla N', phones 5990291xxxx, fake CLABEs. Deposits are VERIFIED (MMG row + cruce).
-- Cases (number = label in the failure message):
--   1  the exact replay: mexico (2 recipients 50/50 USD) + efectivo_usd + recarga (recarga numbers declare 'recarga'), deposit 55,000 -> the OLDEST open
--      operation (mexico) holds it, not the recarga; repartir "mexico 26000, efectivo 29000" is applied; the recarga holds no money; the bot cancels it
--   2  an EXPLICIT declaration (agent:declarar_servicio 'recarga') decides the holder: the recarga holds the deposit; repartir with parts that do not
--      name the recarga is now applied (the deposit moves to the first part's empty operation), and the recarga can be cancelled
--   3  money rules kept: parts above the verified deposit (66,000 vs 55,000) -> facts, nothing moved, the deposit stays on the holder, no group
--   4  a lock a person left on the holder: nothing moves, the original refusal stands
--   5  an implicit declaration (quote of a service) never decides the holder: quote clasica, deposit goes to the oldest operation
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990291' || lpad(p_n::text, 4, '0'), 'PRUEBA ancla ' || p_n, v_acc) RETURNING id INTO v_ct;
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
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test291', now());
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

DO $$
DECLARE
  v_conv uuid; v_a text; v_r jsonb; v_rec uuid; v_first uuid;
BEGIN
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v291', 'assert', md5('assert-vigente-291'), 'confirmada');

  -- 1 the replay
  v_conv := pg_temp.p_escenario(1);
  PERFORM pg_temp.p_eq('1 three operations', (SELECT string_agg(cerebro_riel_op(o.id), ',' ORDER BY cerebro_riel_op(o.id)) FROM remittance_operations o
                                               WHERE o.conversation_id = v_conv AND o.status NOT IN ('completed', 'cancelled')), 'efectivo_usd,mexico,recarga');
  PERFORM pg_temp.p_eq('1 declaration is the recarga numbers one', (SELECT servicio || '/' || actor FROM cerebro_servicio_declarado WHERE conversation_id = v_conv),
                       'recarga/agent:registrar_numeros_recarga');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990291001');
  PERFORM pg_temp.p_eq('1 the oldest operation (mexico) holds the deposit', pg_temp.p_holder(v_conv), 'mexico');
  v_a := cerebro_repartir_envio(v_conv, 'mexico 26000, efectivo 29000', 'q1');
  PERFORM pg_temp.p_eq('1 repartir applied: ' || v_a, (v_a LIKE 'Reparto hecho%')::text, 'true');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM pg_temp.p_eq('1 amounts', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/0');
  PERFORM pg_temp.p_eq('1 the recarga holds no money', _cerebro_op_tiene_dinero(v_rec)::text, 'false');
  v_r := cerebro_modificar_operacion(v_conv, v_rec, 'cancelar', NULL, 'agent:modificar_operacion q1');
  PERFORM pg_temp.p_eq('1 cancel the recarga: ' || coalesce(v_r ->> 'mensaje', ''), v_r ->> 'ok', 'true');
  PERFORM pg_temp.p_eq('1 recarga cancelled', (SELECT status FROM remittance_operations WHERE id = v_rec), 'cancelled');

  -- 2 an explicit declaration decides; the holder need not be a part
  v_conv := pg_temp.p_escenario(2);
  PERFORM cerebro_declarar_servicio(v_conv, 'recarga', 'agent:declarar_servicio');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990291002');
  PERFORM pg_temp.p_eq('2 the explicit declaration holds the deposit', pg_temp.p_holder(v_conv), 'recarga');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  -- 3 money rules first: parts above the deposit change nothing
  v_a := cerebro_repartir_envio(v_conv, 'mexico 26000, efectivo 40000', 'q3');
  PERFORM pg_temp.p_eq('3 facts: ' || v_a, (v_a LIKE 'REPARTO NO APLICADO%' AND v_a LIKE '%66,000%' AND v_a LIKE '%55,000%')::text, 'true');
  PERFORM pg_temp.p_eq('3 deposit stays on the holder', pg_temp.p_holder(v_conv), 'recarga');
  PERFORM pg_temp.p_eq('3 no group', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = v_conv AND mixed_group_id IS NOT NULL), '0');
  PERFORM pg_temp.p_eq('3 amounts untouched', pg_temp.p_ops(v_conv), 'efectivo_usd/0;mexico/0;recarga/55000');
  -- 2 (cont.)
  v_a := cerebro_repartir_envio(v_conv, 'mexico 26000, efectivo 29000', 'q2');
  PERFORM pg_temp.p_eq('2 repartir applied without the holder: ' || v_a, (v_a LIKE 'Reparto hecho%')::text, 'true');
  PERFORM pg_temp.p_eq('2 deposit lives on the parts', pg_temp.p_holder(v_conv), 'mexico');
  PERFORM pg_temp.p_eq('2 amounts', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/0');
  PERFORM pg_temp.p_eq('2 the recarga is empty', _cerebro_op_tiene_dinero(v_rec)::text, 'false');
  v_r := cerebro_modificar_operacion(v_conv, v_rec, 'cancelar', NULL, 'agent:modificar_operacion q2');
  PERFORM pg_temp.p_eq('2 cancel the recarga: ' || coalesce(v_r ->> 'mensaje', ''), v_r ->> 'ok', 'true');
  PERFORM pg_temp.p_eq('2 audit of the move', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_rec AND action = 'agent_deposit_move'), '1');

  -- 4 a human lock on the holder: nothing moves
  v_conv := pg_temp.p_escenario(3);
  PERFORM cerebro_declarar_servicio(v_conv, 'recarga', 'agent:declarar_servicio');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990291003');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('delivery_method', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_rec;
  PERFORM set_config('wacrm.origin', '', true);
  v_a := cerebro_repartir_envio(v_conv, 'mexico 26000, efectivo 29000', 'q4');
  PERFORM pg_temp.p_eq('4 refused: ' || v_a, (v_a LIKE 'No se pudo repartir%')::text, 'true');
  PERFORM pg_temp.p_eq('4 deposit stays', pg_temp.p_holder(v_conv), 'recarga');

  -- 5 an implicit declaration never decides
  v_conv := pg_temp.p_escenario(4);
  DELETE FROM cerebro_servicio_declarado WHERE conversation_id = v_conv;
  SELECT o.id INTO v_first FROM remittance_operations o WHERE o.conversation_id = v_conv ORDER BY o.created_at LIMIT 1;
  PERFORM cerebro_cotizar(v_conv, 100, 'hacia_destino', 'usd', 'clasica', 'q5');
  PERFORM pg_temp.p_eq('5 implicit declaration present', (SELECT actor FROM cerebro_servicio_declarado WHERE conversation_id = v_conv), 'implicit:cotizar');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990291004');
  PERFORM pg_temp.p_eq('5 the oldest operation (the one created first) holds it',
                       (SELECT d.operation_id = v_first FROM depositos_mmg d WHERE d.trans_id = '90409990291004' AND d.anulado_en IS NULL)::text, 'true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
