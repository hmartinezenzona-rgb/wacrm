\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 369 (a split planned before the deposit gives each part its AGREED amount, which is not money).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA plan monto N', phones 5990369xxxx.
-- Shape of conversation d9e9f333 / 2ca2cf79: the Zelle operation was opened earlier in the turn (0 GYD), the recarga operation holds the
-- amount agreed through the recarga numbers (12,400, agreed-amount audit), then repartir_envio "recarga 12400, zelle 13000" plans the split.
-- Cases:
--   1  after the plan each part holds its agreed amount (recarga 12,400, zelle 13,000), no mixed_group_id, no money, both read as
--      agreed (_cerebro_op_monto_acordado), the recarga amount already agreed is not written twice (one audit row), zelle has one
--   2  the same plan again writes nothing new (no extra audit row, no extra operation)
--   3  a deposit of exactly 25,400 applies the plan: one group, 12,400 / 13,000, plan gone, two operations, group deposited 25,400 saldo 0
--   4  a different deposit (20,000): registered, nothing grouped, plan kept, repartir_envio answers the facts (25,400 vs 20,000)
--   5  a part whose amount a person locked keeps its amount; the other part still gets its agreed amount; the plan is still saved
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990369' || lpad(p_n::text, 4, '0'), 'PRUEBA plan monto ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- the operations of the real shape: zelle opened earlier (0 GYD), recarga with its agreed 12,400
CREATE FUNCTION pg_temp.p_shape(p_conv uuid) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_z uuid; v_r uuid;
BEGIN
  v_z := _cerebro_op_parte(p_conv, 'zelle', 'agent:guardar_zelle', 'test shape');
  v_r := _cerebro_op_parte(p_conv, 'recarga', 'agent:registrar_numeros_recarga', 'test shape');
  PERFORM _cerebro_fijar_monto_acordado(v_r, 12400, 'agent:registrar_numeros_recarga');
END $f$;

CREATE FUNCTION pg_temp.p_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

CREATE FUNCTION pg_temp.p_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY cerebro_riel_op(o.id)), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.p_audits(p_conv uuid, p_srv text) RETURNS int
LANGUAGE sql AS $f$
  SELECT count(*)::int FROM remittance_admin_audit a JOIN remittance_operations o ON o.id = a.row_id
   WHERE o.conversation_id = p_conv AND cerebro_riel_op(o.id) = p_srv AND a.action = 'agent_amount_change' AND a.after ->> 'agreed' = 'true';
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

DO $$
DECLARE
  c record; v_a text; v_op uuid; v_s record;
BEGIN
  -- 1 the plan gives each part its agreed amount
  SELECT * INTO c FROM pg_temp.p_conv(1);
  PERFORM pg_temp.p_shape(c.conv);
  PERFORM pg_temp.p_eq('1 before the plan', pg_temp.p_ops(c.conv), 'recarga/12400;zelle/0');
  v_a := cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'q1');
  PERFORM pg_temp.p_eq('1 planned', (v_a LIKE 'Reparto planeado%')::text, 'true');
  PERFORM pg_temp.p_eq('1 amounts', pg_temp.p_ops(c.conv), 'recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('1 not grouped', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');
  PERFORM pg_temp.p_eq('1 no money', (SELECT bool_or(_cerebro_op_tiene_dinero(id))::text FROM remittance_operations WHERE conversation_id = c.conv), 'false');
  PERFORM pg_temp.p_eq('1 both agreed', (SELECT bool_and(_cerebro_op_monto_acordado(id))::text FROM remittance_operations WHERE conversation_id = c.conv), 'true');
  PERFORM pg_temp.p_eq('1 recarga not written twice', pg_temp.p_audits(c.conv, 'recarga')::text, '1');
  PERFORM pg_temp.p_eq('1 zelle agreed once', pg_temp.p_audits(c.conv, 'zelle')::text, '1');
  PERFORM pg_temp.p_eq('1 plan row', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '25400');

  -- 2 the same plan again writes nothing new
  v_a := cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'q2');
  PERFORM pg_temp.p_eq('2 no extra audit', pg_temp.p_audits(c.conv, 'recarga')::text || '/' || pg_temp.p_audits(c.conv, 'zelle')::text, '1/1');
  PERFORM pg_temp.p_eq('2 no extra operation', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '2');

  -- 3 a deposit of exactly the total applies the plan
  PERFORM pg_temp.p_registra(c.conv, 25400, '36900001');
  PERFORM pg_temp.p_eq('3 amounts', pg_temp.p_ops(c.conv), 'recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('3 one group', (SELECT count(DISTINCT mixed_group_id)::text FROM remittance_operations WHERE conversation_id = c.conv AND status <> 'cancelled'), '1');
  PERFORM pg_temp.p_eq('3 every part grouped', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '2');
  PERFORM pg_temp.p_eq('3 plan gone', (SELECT count(*)::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '0');
  PERFORM pg_temp.p_eq('3 two operations', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '2');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = c.conv LIMIT 1;
  SELECT * INTO v_s FROM cerebro_saldo_operacion(v_op);
  PERFORM pg_temp.p_eq('3 group objetivo', v_s.objetivo::text, '25400');

  -- 4 a different deposit
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM pg_temp.p_shape(c.conv);
  PERFORM cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'q4a');
  PERFORM pg_temp.p_registra(c.conv, 20000, '36900002');
  PERFORM pg_temp.p_eq('4 nothing grouped', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');
  PERFORM pg_temp.p_eq('4 plan kept', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '25400');
  v_a := cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'q4b');
  PERFORM pg_temp.p_eq('4 facts', (v_a LIKE 'REPARTO NO APLICADO%' AND v_a LIKE '%25,400%' AND v_a LIKE '%20,000%')::text, 'true');
  PERFORM pg_temp.p_eq('4 still nothing grouped', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');

  -- 5 an amount a person locked is not overwritten
  SELECT * INTO c FROM pg_temp.p_conv(3);
  PERFORM pg_temp.p_shape(c.conv);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', c.usr, 'role', 'authenticated')::text, true);
  UPDATE remittance_operations SET quoted_source_amount = 9000 WHERE conversation_id = c.conv AND service_type = 'remesa';
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM pg_temp.p_eq('5 fixture lock', (SELECT (admin_locked_fields ? 'quoted_source_amount')::text FROM remittance_operations WHERE conversation_id = c.conv AND service_type = 'remesa'), 'true');
  v_a := cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'q5');
  PERFORM pg_temp.p_eq('5 locked part kept, other agreed', pg_temp.p_ops(c.conv), 'recarga/12400;zelle/9000');
  PERFORM pg_temp.p_eq('5 plan saved', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '25400');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
