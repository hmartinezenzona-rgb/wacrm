\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 287 (cerebro_modificar_operacion p_accion 'mover_deposito').
-- Self-reverting. Synthetic fixtures: contacts 'PRUEBA mover N', phones 5990287xxxx; MMG rows inserted already verified (consumido_en) and attached.
-- Cases:
--   1  a verified 26,000 deposit moves from a Zelle operation to another Zelle operation that asks 26,000: the row now belongs to the target (ONE row, not duplicated),
--      target ready_to_transfer, source awaiting_deposit, two audit rows with the real actor, message in Spanish, tool log
--   2  a target that asks nothing yet takes the deposit as its amount
--   3  below the target's minimum (5,000 into a Zelle): refused with faltante 8,000, nothing moved
--   4  larger than what the target asks: refused, nothing moved
--   5  refusals: target in another conversation, closed target, transferring target, source without a verified deposit, same operation, no target given
--   6  a lock a person left on the target: refused; a split group member: refused
--   7  a source with two verified deposits: the reference is required; the named one moves, the other stays and the source keeps its status logic
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990287' || lpad(p_n::text, 4, '0'), 'PRUEBA mover ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS jsonb
LANGUAGE sql AS $f$ SELECT cerebro_resolver_servicio(p_conv) -> 'reparto_planeado'; $f$;

-- a deposit that is verified: MMG row in the ledger + registrar + cruce (same as split-deposit-minimums)

CREATE FUNCTION pg_temp.p_op(p_conv uuid, p_rail text, p_quoted numeric, p_status text DEFAULT 'collecting_information') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT account_id, contact_id INTO v_acc, v_ct FROM conversations WHERE id = p_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (v_acc, p_conv, v_ct, p_status, 'remesa', p_rail, 'GYD', p_quoted) RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.p_dep(p_op uuid, p_ref text, p_monto numeric) RETURNS void
LANGUAGE sql AS $f$
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, operation_id, consumido_en)
  VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test287', now(), p_op, now());
$f$;

CREATE FUNCTION pg_temp.p_st(p_op uuid) RETURNS text
LANGUAGE sql AS $f$ SELECT status || '/' || coalesce(trim_scale(quoted_source_amount)::text, '-') FROM remittance_operations WHERE id = p_op; $f$;

CREATE FUNCTION pg_temp.p_dop(p_ref text) RETURNS uuid
LANGUAGE sql AS $f$ SELECT operation_id FROM depositos_mmg WHERE trans_id = p_ref; $f$;

DO $$
DECLARE c record; c2 record; a uuid; b uuid; r jsonb;
BEGIN
  -- 1
  SELECT * INTO c FROM pg_temp.p_conv(1);
  a := pg_temp.p_op(c.conv, 'zelle', 26000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003100', 26000);
  b := pg_temp.p_op(c.conv, 'zelle', 26000);
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm1');
  PERFORM pg_temp.p_eq('1 ok', r ->> 'ok', 'true');
  PERFORM pg_temp.p_eq('1 deposit belongs to the target', (pg_temp.p_dop('9040999003100') = b)::text, 'true');
  PERFORM pg_temp.p_eq('1 not duplicated', (SELECT count(*)::text FROM depositos_mmg WHERE trans_id = '9040999003100'), '1');
  PERFORM pg_temp.p_eq('1 target', pg_temp.p_st(b), 'ready_to_transfer/26000');
  PERFORM pg_temp.p_eq('1 source', pg_temp.p_st(a), 'awaiting_deposit/26000');
  PERFORM pg_temp.p_eq('1 audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE action = 'agent_deposit_move' AND row_id IN (a, b) AND actor = 'agent:modificar_operacion n8n:m1'), '2');
  PERFORM pg_temp.p_eq('1 message', (r ->> 'mensaje' LIKE 'Listo: movi el deposito de 26,000 GYD%operacion de origen queda esperando su deposito.')::text, 'true');
  PERFORM pg_temp.p_eq('1 log', (SELECT outcome FROM tool_execution_log WHERE tool_name = 'modificar_operacion' AND execution_id = 'm1'), 'deposito_movido');

  -- 2 empty target
  SELECT * INTO c FROM pg_temp.p_conv(2);
  a := pg_temp.p_op(c.conv, 'zelle', 26000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003101', 26000);
  b := pg_temp.p_op(c.conv, 'zelle', 0);
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm2');
  PERFORM pg_temp.p_eq('2 target takes the deposit', (r ->> 'ok') || '/' || pg_temp.p_st(b), 'true/ready_to_transfer/26000');

  -- 3 below the minimum
  SELECT * INTO c FROM pg_temp.p_conv(3);
  a := pg_temp.p_op(c.conv, 'cuban_card', 5000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003102', 5000);
  b := pg_temp.p_op(c.conv, 'zelle', 13000);
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm3');
  PERFORM pg_temp.p_eq('3 refused with the gap', (r ->> 'motivo') || '/' || trim_scale((r ->> 'faltante_gyd')::numeric)::text, 'por_debajo_del_minimo/8000');
  PERFORM pg_temp.p_eq('3 nothing moved', (pg_temp.p_dop('9040999003102') = a)::text || '/' || pg_temp.p_st(a) || '/' || pg_temp.p_st(b), 'true/ready_to_transfer/5000/collecting_information/13000');

  -- 4 larger than the request
  SELECT * INTO c FROM pg_temp.p_conv(4);
  a := pg_temp.p_op(c.conv, 'zelle', 26000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003103', 26000);
  b := pg_temp.p_op(c.conv, 'zelle', 13000);
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm4');
  PERFORM pg_temp.p_eq('4 refused', r ->> 'motivo', 'deposito_mayor_que_el_envio');
  PERFORM pg_temp.p_eq('4 nothing moved', (pg_temp.p_dop('9040999003103') = a)::text, 'true');

  -- 5 refusals
  SELECT * INTO c2 FROM pg_temp.p_conv(5);
  a := pg_temp.p_op(c2.conv, 'zelle', 26000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003104', 26000);
  b := pg_temp.p_op(c.conv, 'zelle', 0);
  r := cerebro_modificar_operacion(c2.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm5a');
  PERFORM pg_temp.p_eq('5 other conversation', r ->> 'motivo', 'operacion_no_encontrada');
  b := pg_temp.p_op(c2.conv, 'zelle', 0, 'transferring');
  r := cerebro_modificar_operacion(c2.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm5b');
  PERFORM pg_temp.p_eq('5 transferring target', r ->> 'motivo', 'estado_no_permite');
  b := pg_temp.p_op(c2.conv, 'zelle', 0, 'cancelled');
  r := cerebro_modificar_operacion(c2.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm5c');
  PERFORM pg_temp.p_eq('5 closed target', r ->> 'motivo', 'estado_no_permite');
  r := cerebro_modificar_operacion(c2.conv, a, 'mover_deposito', jsonb_build_object('a', a), 'm5d');
  PERFORM pg_temp.p_eq('5 same operation', r ->> 'motivo', 'falta_destino');
  r := cerebro_modificar_operacion(c2.conv, a, 'mover_deposito', NULL, 'm5e');
  PERFORM pg_temp.p_eq('5 no target', r ->> 'motivo', 'falta_destino');
  b := pg_temp.p_op(c2.conv, 'zelle', 0);
  r := cerebro_modificar_operacion(c2.conv, b, 'mover_deposito', jsonb_build_object('a', a), 'm5f');
  PERFORM pg_temp.p_eq('5 source without a verified deposit', r ->> 'motivo', 'sin_deposito_verificado');
  PERFORM pg_temp.p_eq('5 deposit stayed', (pg_temp.p_dop('9040999003104') = a)::text, 'true');

  -- 6 locks / group
  SELECT * INTO c FROM pg_temp.p_conv(6);
  a := pg_temp.p_op(c.conv, 'zelle', 26000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003105', 26000);
  b := pg_temp.p_op(c.conv, 'zelle', 0);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('delivery_method', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = b;
  PERFORM set_config('wacrm.origin', '', true);
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm6a');
  PERFORM pg_temp.p_eq('6 human lock', r ->> 'motivo', 'bloqueado_por_humano');
  SELECT * INTO c FROM pg_temp.p_conv(7);
  a := pg_temp.p_op(c.conv, 'zelle', 26000, 'ready_to_transfer'); PERFORM pg_temp.p_dep(a, '9040999003106', 26000);
  b := pg_temp.p_op(c.conv, 'zelle', 0);
  UPDATE remittance_operations SET mixed_group_id = b WHERE id = b;
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm6b');
  PERFORM pg_temp.p_eq('6 group', r ->> 'motivo', 'en_grupo');

  -- 7 two deposits
  SELECT * INTO c FROM pg_temp.p_conv(8);
  a := pg_temp.p_op(c.conv, 'zelle', 26000, 'ready_to_transfer');
  PERFORM pg_temp.p_dep(a, '9040999003107', 13000); PERFORM pg_temp.p_dep(a, '9040999003108', 13000);
  b := pg_temp.p_op(c.conv, 'zelle', 13000);
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b), 'm7a');
  PERFORM pg_temp.p_eq('7 asks which', r ->> 'motivo', 'varios_depositos');
  r := cerebro_modificar_operacion(c.conv, a, 'mover_deposito', jsonb_build_object('a', b, 'deposito', '9040999003107'), 'm7b');
  PERFORM pg_temp.p_eq('7 moved one', (r ->> 'ok') || '/' || (pg_temp.p_dop('9040999003107') = b)::text || '/' || (pg_temp.p_dop('9040999003108') = a)::text, 'true/true/true');
  PERFORM pg_temp.p_eq('7 states', pg_temp.p_st(a) || '|' || pg_temp.p_st(b), 'deposit_verification/26000|ready_to_transfer/13000');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
