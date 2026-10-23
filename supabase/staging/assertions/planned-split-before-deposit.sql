\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 277 (a split planned BEFORE the deposit, and facts instead of a refusal when the deposit differs).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA reparto N', phones 5990277xxxx, fake CLABE / card.
-- odd/notes/db-tools-progress.md (277, gap 3 of the S5b measurement: M3b "No hay un deposito registrado para repartir todavia",
-- and the Marlene shape: parts 150 + 100 USD + 15,000 but a 71,200 deposit).
-- Cases (number = label in the failure message):
--   1  cerebro_repartir_envio with no deposit PLANS the split: the plan is persisted (parts, total), one empty operation per part
--      is opened (mexico, efectivo_usd, cuban_card), the answer lists parts with USD and says nothing is applied yet;
--      cerebro_resolver_servicio shows reparto_planeado (parts with usd, total, deposito 0, diferencia, coincide false)
--   2  data lands on its part: card -> the CUP part, cash data -> the cash part, the Mexico recipient -> the mexico part
--   3  a deposit EQUAL to the planned total is split automatically: one mixed group, amounts 39000 / 29000 / 15000, the plan is gone,
--      no extra operation, each part keeps its data
--   4  a deposit DIFFERENT from the plan (71,200): the deposit is registered, nothing is split, reparto_planeado shows
--      deposito 71200 / diferencia -11800 / coincide false; repartir_envio with the old parts answers the FACTS (plan kept, nothing
--      changed); with parts that add up to 71,200 it splits and the plan is gone
--   5  a deposit already there and parts that do not add up (no plan before): the plan is saved and the facts are returned
--   6  fewer than two parts before a deposit: refused, no plan, no operation
--   7  the plan goes when the conversation's last operation closes
--   8  ACL: the plan table and the helpers are service_role only
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990277' || lpad(p_n::text, 4, '0'), 'PRUEBA reparto ' || p_n, v_acc) RETURNING id INTO v_ct;
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

-- "rail/amount" of every open operation, sorted
CREATE FUNCTION pg_temp.p_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY cerebro_riel_op(o.id)), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT cerebro_resolver_servicio(p_conv) -> 'reparto_planeado'; $f$;

DO $$
DECLARE
  c record; v_a text; v_p jsonb; v_op uuid; v_n int;
  c_clabe constant text := '012345678901234567';
  c_card  constant text := '9999000000000008';
BEGIN
  -- 1 plan before the deposit
  SELECT * INTO c FROM pg_temp.p_conv(1);
  v_a := cerebro_repartir_envio(c.conv, 'mexico 39000, efectivo 29000, cup 15000', 'p1');
  PERFORM pg_temp.p_eq('1 planned text', (v_a LIKE 'Reparto planeado%' AND v_a LIKE '%150 USD%' AND v_a LIKE '%100 USD%')::text, 'true');
  PERFORM pg_temp.p_eq('1 one empty operation per part', pg_temp.p_ops(c.conv), 'cuban_card/0;efectivo_usd/0;mexico/0');
  PERFORM pg_temp.p_eq('1 plan row', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '83000');
  v_p := pg_temp.p_plan(c.conv);
  PERFORM pg_temp.p_eq('1 resolver total', v_p ->> 'total_gyd', '83000');
  PERFORM pg_temp.p_eq('1 resolver deposito', v_p ->> 'deposito_gyd', '0');
  PERFORM pg_temp.p_eq('1 resolver coincide', v_p ->> 'coincide', 'false');
  PERFORM pg_temp.p_eq('1 resolver parts', (SELECT string_agg((e ->> 'servicio') || '=' || (e ->> 'monto_gyd') || '/' || coalesce(e ->> 'usd', '-'), ';' ORDER BY ord)
                                             FROM jsonb_array_elements(v_p -> 'partes') WITH ORDINALITY t(e, ord)),
                       'mexico=39000/150;efectivo_usd=29000/100;cuban_card=15000/-');
  v_a := cerebro_repartir_envio(c.conv, 'mexico 39000, efectivo 29000, cup 15000', 'p1b');
  PERFORM pg_temp.p_eq('1 same plan again opens nothing new', pg_temp.p_ops(c.conv), 'cuban_card/0;efectivo_usd/0;mexico/0');

  -- 2 data lands on its part
  PERFORM cerebro_guardar_beneficiario(c.conv, '', c_card, '53821203', 'p2a');
  PERFORM crm_registrar_datos_entrega_efectivo(c.conv, '53821204', 'Calle 10 numero 5, Bayamo', NULL, 'Rosa Gomez');
  PERFORM cerebro_guardar_beneficiario_mexico(c.conv, 'mexico_cuenta', c_clabe, 'Mercado Pago', 'Ana Perez', NULL, 'agent:registrar_destinatario_mexico n8n:p2');
  PERFORM pg_temp.p_eq('2 each part has its recipient', (SELECT string_agg(cerebro_riel_op(o.id) || ':' || (SELECT count(*) FROM remittance_beneficiaries b WHERE b.operation_id = o.id AND b.status = 'vigente'),
                                                                ';' ORDER BY cerebro_riel_op(o.id)) FROM remittance_operations o WHERE o.conversation_id = c.conv),
                       'cuban_card:1;efectivo_usd:1;mexico:1');
  PERFORM pg_temp.p_eq('2 no extra operation', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '3');

  -- 3 equal deposit splits by itself
  PERFORM pg_temp.p_registra(c.conv, 83000, '27700001');
  PERFORM pg_temp.p_eq('3 amounts', pg_temp.p_ops(c.conv), 'cuban_card/15000;efectivo_usd/29000;mexico/39000');
  PERFORM pg_temp.p_eq('3 one group', (SELECT count(DISTINCT mixed_group_id)::text FROM remittance_operations WHERE conversation_id = c.conv AND status <> 'cancelled'), '1');
  PERFORM pg_temp.p_eq('3 plan gone', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0');
  PERFORM pg_temp.p_eq('3 three operations', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND status <> 'cancelled'), '3');
  PERFORM pg_temp.p_eq('3 recipients kept', (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
                         WHERE o.conversation_id = c.conv AND b.status = 'vigente'), '3');

  -- 4 a different deposit (Marlene)
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM cerebro_repartir_envio(c.conv, 'mexico 39000, efectivo 29000, cup 15000', 'p4a');
  PERFORM pg_temp.p_registra(c.conv, 71200, '27700002');
  PERFORM pg_temp.p_eq('4 deposit registered, nothing split', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');
  PERFORM pg_temp.p_eq('4 plan kept', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '83000');
  v_p := pg_temp.p_plan(c.conv);
  PERFORM pg_temp.p_eq('4 deposito', v_p ->> 'deposito_gyd', '71200');
  PERFORM pg_temp.p_eq('4 diferencia', v_p ->> 'diferencia_gyd', '-11800');
  PERFORM pg_temp.p_eq('4 coincide', v_p ->> 'coincide', 'false');
  v_a := cerebro_repartir_envio(c.conv, 'mexico 39000, efectivo 29000, cup 15000', 'p4b');
  PERFORM pg_temp.p_eq('4 facts, not a refusal', (v_a LIKE 'REPARTO NO APLICADO%' AND v_a LIKE '%83,000%' AND v_a LIKE '%71,200%' AND v_a LIKE '%11,800%'
                                                   AND v_a LIKE '%150 USD%' AND v_a LIKE '%100 USD%')::text, 'true');
  PERFORM pg_temp.p_eq('4 nothing changed', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');
  PERFORM pg_temp.p_eq('4 plan still kept', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '83000');
  v_a := cerebro_repartir_envio(c.conv, 'mexico 27200, efectivo 29000, cup 15000', 'p4c');
  PERFORM pg_temp.p_eq('4 corrected parts split', (v_a LIKE 'Reparto hecho%')::text, 'true');
  PERFORM pg_temp.p_eq('4 amounts', pg_temp.p_ops(c.conv), 'cuban_card/15000;efectivo_usd/29000;mexico/27200');
  PERFORM pg_temp.p_eq('4 plan gone after the split', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0');

  -- 5 deposit there, no plan before, parts that do not add up
  SELECT * INTO c FROM pg_temp.p_conv(3);
  PERFORM pg_temp.p_registra(c.conv, 71200, '27700003');
  v_a := cerebro_repartir_envio(c.conv, 'mexico 39000, efectivo usd 29000', 'p5');
  PERFORM pg_temp.p_eq('5 facts', (v_a LIKE 'REPARTO NO APLICADO%' AND v_a LIKE '%68,000%' AND v_a LIKE '%71,200%' AND v_a LIKE '%3,200%')::text, 'true');
  PERFORM pg_temp.p_eq('5 plan saved', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '68000');
  PERFORM pg_temp.p_eq('5 nothing changed', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '1');

  -- 6 a single part before a deposit
  SELECT * INTO c FROM pg_temp.p_conv(4);
  v_a := cerebro_repartir_envio(c.conv, 'clasica 5000', 'p6');
  PERFORM pg_temp.p_eq('6 refused', (v_a LIKE 'No se pudo repartir%')::text, 'true');
  PERFORM pg_temp.p_eq('6 no plan, no operation', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv)
                                                  || '/' || (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '0/0');

  -- 7 plan goes with the last operation
  SELECT * INTO c FROM pg_temp.p_conv(5);
  PERFORM cerebro_repartir_envio(c.conv, 'clasica 18200, recarga 6200', 'p7');
  PERFORM pg_temp.p_eq('7 plan exists', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '1');
  UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE conversation_id = c.conv;
  PERFORM pg_temp.p_eq('7 plan cleared', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0');

  -- 8 ACL
  PERFORM pg_temp.p_eq('8 table', has_table_privilege('authenticated', 'cerebro_reparto_planeado', 'SELECT')::text || ':' ||
                                  has_table_privilege('anon', 'cerebro_reparto_planeado', 'SELECT')::text || ':' ||
                                  has_table_privilege('service_role', 'cerebro_reparto_planeado', 'SELECT')::text, 'false:false:true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
