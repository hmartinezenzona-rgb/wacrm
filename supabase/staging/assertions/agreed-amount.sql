\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 293 (the AGREED amount of each part of a send lives in quoted_source_amount of its operation while it holds no money).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA acordado N', phones 5990293xxxx, fake CLABEs. Deposits are VERIFIED (MMG row + cruce).
-- Cases:
--   1  declarar_servicio / agregar_servicio / cambiar_servicio with a GYD amount record it; the recarga opened by the numbers gets the live promo price
--   2  a quote that names its service records the quoted GYD on the implicitly declared operation
--   3  never overwritten: an operation with money, or with a lock a person left on quoted_source_amount
--   4  the replay with agreed amounts (mexico 26,000 / efectivo 29,000 / recarga 6,200): deposit 55,000 goes to the anchor, repartir applies
--      mexico + efectivo, the recarga keeps its 6,200 agreed and can be cancelled
--   5  an explicit recarga declaration holds the deposit; repartir moves it and the recarga gets its agreed 6,200 back
--   6  cerebro_resolver_servicio exposes monto_acordado_gyd and dinero_gyd per operation; an agreed-only operation is still 'vacia'
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990293' || lpad(p_n::text, 4, '0'), 'PRUEBA acordado ' || p_n, v_acc) RETURNING id INTO v_ct;
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
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test293', now());
  SELECT r.deal_id INTO v_id FROM pg_temp.p_registra(p_conv, p_monto, p_ref) r;
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
END $f$;

-- the three operations the way the tools create them, in the order of the replay: mexico (declared, two recipients 50/50 USD), cash (agregar_servicio), recarga (numbers)
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

CREATE FUNCTION pg_temp.p_escenario(p_n int) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE c record; r jsonb;
BEGIN
  SELECT * INTO c FROM pg_temp.p_conv(p_n);
  PERFORM cerebro_declarar_servicio(c.conv, 'mexico', 'agent:declarar_servicio', 26000);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '0123456789012345' || lpad(p_n::text, 2, '0'), 'Mercado Pago', 'PRUEBA Ana', NULL, NULL, p_monto => 50);
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', '9876543210987654' || lpad(p_n::text, 2, '0'), 'Banco Azteca', 'PRUEBA Luis', NULL, NULL, p_agregar => true, p_monto => 50);
  UPDATE remittance_operations SET created_at = now() - interval '30 minutes' WHERE conversation_id = c.conv AND service_type = 'mexico';
  r := cerebro_aplicar_servicio(c.conv, 'efectivo_usd', 'agregar', 'agent:agregar_servicio', NULL, 29000);
  UPDATE remittance_operations SET created_at = now() - interval '20 minutes' WHERE conversation_id = c.conv AND service_type = 'remesa';
  PERFORM crm_registrar_numeros_recarga(c.conv, '5550' || lpad(p_n::text, 4, '0'), true, 'agent:registrar_numeros_recarga');
  UPDATE remittance_operations SET created_at = now() - interval '10 minutes' WHERE conversation_id = c.conv AND service_type = 'recarga';
  RETURN c.conv;
END $f$;

DO $$
DECLARE
  v_conv uuid; v_a text; v_r jsonb; v_rec uuid; v_op uuid; v_mex uuid; v_x jsonb;
BEGIN
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v293', 'assert', md5('assert-vigente-293'), 'confirmada');

  -- 1 the three tools record the amount; the recarga gets the live promo price
  v_conv := pg_temp.p_escenario(1);
  PERFORM pg_temp.p_eq('1 amounts', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/6200');
  v_r := cerebro_aplicar_servicio(v_conv, 'tropical', 'agregar', 'agent:agregar_servicio', NULL, 15000);
  PERFORM pg_temp.p_eq('1 agregar amount', (SELECT quoted_source_amount::int::text FROM remittance_operations o WHERE o.conversation_id = v_conv AND cerebro_riel_op(o.id) = 'tropical'), '15000');
  v_conv := (SELECT conv FROM pg_temp.p_conv(9));
  PERFORM cerebro_declarar_servicio(v_conv, 'tropical', 'agent:declarar_servicio', 15000);
  v_r := cerebro_aplicar_servicio(v_conv, 'clasica', 'cambiar', 'agent:cambiar_servicio', NULL, 17000);
  PERFORM pg_temp.p_eq('1 cambiar converts the empty tropical and records: ' || v_r::text, pg_temp.p_ops(v_conv), 'clasica/17000');
  PERFORM pg_temp.p_eq('1 audit of the amount', (SELECT (count(*) >= 2)::text FROM remittance_admin_audit WHERE action = 'agent_amount_change' AND reason LIKE 'agreed amount%'
                                                  AND row_id IN (SELECT id FROM remittance_operations WHERE conversation_id = v_conv)), 'true');
  -- the 5-argument call (registrar_deposito, recarga numbers) keeps working
  v_r := cerebro_aplicar_servicio(v_conv, NULL, NULL, 'automation:registrar_deposito', NULL);
  PERFORM pg_temp.p_eq('1 five-argument call', (v_r ? 'aplicado')::text, 'true');

  -- 2 a quote naming its service records the quoted GYD on the implicitly declared operation
  v_conv := (SELECT conv FROM pg_temp.p_conv(3));
  v_r := cerebro_cotizar(v_conv, 100, 'hacia_destino', 'usd', 'clasica', 'q2');
  PERFORM pg_temp.p_eq('2 implicit declaration', (SELECT servicio || '/' || actor FROM cerebro_servicio_declarado WHERE conversation_id = v_conv), 'clasica/implicit:cotizar');
  PERFORM pg_temp.p_eq('2 quoted GYD on the operation', (SELECT quoted_source_amount::text FROM remittance_operations o WHERE o.conversation_id = v_conv AND cerebro_riel_op(o.id) = 'clasica'),
                       (v_r ->> 'deposita_gyd'));
  -- the next quote of another service replaces the implicit one and records its own amount
  v_r := cerebro_cotizar(v_conv, 100, 'hacia_destino', 'usd', 'mexico', 'q2b');
  PERFORM pg_temp.p_eq('2 second quote', (SELECT quoted_source_amount::text FROM remittance_operations o WHERE o.conversation_id = v_conv AND o.service_type = 'mexico'), (v_r ->> 'deposita_gyd'));

  -- 3 never overwritten: money, or a lock a person left
  v_conv := (SELECT conv FROM pg_temp.p_conv(4));
  PERFORM cerebro_declarar_servicio(v_conv, 'clasica', 'agent:declarar_servicio', 18200);
  PERFORM pg_temp.p_verifica(v_conv, 18200, '90409990293001');
  v_a := (cerebro_declarar_servicio(v_conv, 'clasica', 'agent:declarar_servicio', 30000))::text;
  PERFORM pg_temp.p_eq('3 money keeps its amount: ' || v_a, pg_temp.p_ops(v_conv), 'clasica/18200');
  v_conv := (SELECT conv FROM pg_temp.p_conv(5));
  PERFORM cerebro_declarar_servicio(v_conv, 'zelle', 'agent:declarar_servicio', 20000);
  v_op := pg_temp.p_op(v_conv, 'zelle');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('quoted_source_amount', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_a := (cerebro_declarar_servicio(v_conv, 'zelle', 'agent:declarar_servicio', 30000))::text;
  PERFORM pg_temp.p_eq('3 human lock keeps its amount: ' || v_a, pg_temp.p_ops(v_conv), 'zelle/20000');

  -- 4 the replay with agreed amounts
  v_conv := pg_temp.p_escenario(6);
  PERFORM pg_temp.p_eq('4 three operations with agreed amounts', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/6200');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990293002');
  PERFORM pg_temp.p_eq('4 the oldest operation (mexico) holds the deposit', pg_temp.p_holder(v_conv), 'mexico');
  v_a := cerebro_repartir_envio(v_conv, 'mexico 26000, efectivo 29000', 'q4');
  PERFORM pg_temp.p_eq('4 repartir applied: ' || v_a, (v_a LIKE 'Reparto hecho%')::text, 'true');
  v_rec := pg_temp.p_op(v_conv, 'recarga');
  PERFORM pg_temp.p_eq('4 amounts', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/6200');
  PERFORM pg_temp.p_eq('4 the recarga holds no money', _cerebro_op_tiene_dinero(v_rec)::text, 'false');
  v_r := cerebro_modificar_operacion(v_conv, v_rec, 'cancelar', NULL, 'agent:modificar_operacion q4');
  PERFORM pg_temp.p_eq('4 cancel the recarga: ' || coalesce(v_r ->> 'mensaje', ''), v_r ->> 'ok', 'true');

  -- 5 an explicit declaration decides the holder; the amount of the dropped recarga comes back
  v_conv := pg_temp.p_escenario(7);
  PERFORM cerebro_declarar_servicio(v_conv, 'recarga', 'agent:declarar_servicio');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990293003');
  PERFORM pg_temp.p_eq('5 the recarga holds the deposit', pg_temp.p_holder(v_conv), 'recarga');
  PERFORM pg_temp.p_eq('5 amounts while it holds money', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/55000');
  v_a := cerebro_repartir_envio(v_conv, 'mexico 26000, efectivo 29000', 'q5');
  PERFORM pg_temp.p_eq('5 repartir applied: ' || v_a, (v_a LIKE 'Reparto hecho%')::text, 'true');
  PERFORM pg_temp.p_eq('5 amounts', pg_temp.p_ops(v_conv), 'efectivo_usd/29000;mexico/26000;recarga/6200');
  PERFORM pg_temp.p_eq('5 the recarga is empty', _cerebro_op_tiene_dinero(pg_temp.p_op(v_conv, 'recarga'))::text, 'false');

  -- 6 the resolver exposes the agreed amount and the money of each operation
  v_conv := pg_temp.p_escenario(8);
  v_r := cerebro_resolver_servicio(v_conv, NULL, NULL);
  PERFORM pg_temp.p_eq('6 agreed amounts exposed: ' || (v_r -> 'operaciones')::text,
                       (SELECT string_agg(e ->> 'servicio' || '=' || (e ->> 'monto_acordado_gyd') || '/' || (e ->> 'dinero_gyd') || '/' || (e ->> 'vacia'), ';' ORDER BY e ->> 'servicio')
                          FROM jsonb_array_elements(v_r -> 'operaciones') e),
                       'efectivo_usd=29000/0/true;mexico=26000/0/true;recarga=6200/0/true');
  PERFORM pg_temp.p_verifica(v_conv, 55000, '90409990293004');
  v_r := cerebro_resolver_servicio(v_conv, NULL, NULL);
  PERFORM pg_temp.p_eq('6 money exposed', (SELECT string_agg(e ->> 'servicio' || '=' || coalesce(e ->> 'monto_acordado_gyd', 'null') || '/' || (e ->> 'dinero_gyd'), ';' ORDER BY e ->> 'servicio')
                          FROM jsonb_array_elements(v_r -> 'operaciones') e),
                       'efectivo_usd=29000/0;mexico=26000/55000;recarga=6200/0');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
