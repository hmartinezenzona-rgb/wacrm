\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 281 (cerebro_modificar_operacion: amount, cancel, merge; the general operation tool).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Synthetic fixtures only: contacts 'PRUEBA modificar N', phones 5990281xxxx, fake Zelle accounts.
-- Cases (number = label in the failure message):
--   1  amount before a deposit: new GYD amount written, destination recalculated, audit row with the agent actor, same value = no change,
--      below the Zelle minimum refused, recipient untouched, tool log
--   2  amount after a VERIFIED deposit: above the deposit refused with the gap (nothing written); below it written and the surplus stated
--   3  a lock a person left on quoted_source_amount: refused, nothing written; an agent/automation lock does not block
--   4  several open operations and no p_op: the answer lists them; with p_op it works; a waiting split plan follows the new amount
--   5  cancel an operation without money: cancelled, audit, objective closed, a second cancel refused as closed; its part leaves the plan
--   6  cancel an operation WITH money (verified deposit): refused, a person handles it, nothing changed
--   7  merge two empty operations of the same service: recipients joined, amounts added, the other cancelled; duplicate recipient retired
--   8  merge when one holds money: it survives; money in both / different services / unknown operation refused
--   9  ACL: service_role only
-- =====================================================================
CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990281' || lpad(p_n::text, 4, '0'), 'PRUEBA modificar ' || p_n, v_acc) RETURNING id INTO v_ct;
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

-- a deposit that is verified: MMG row in the ledger + registrar + cruce (same as split-deposit-minimums)
CREATE FUNCTION pg_temp.p_verifica(p_conv uuid, p_monto numeric, p_ref text) RETURNS void
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en) VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test280', now());
  SELECT r.deal_id INTO v_id FROM pg_temp.p_registra(p_conv, p_monto, p_ref) r;
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
END $f$;


-- an extra open Zelle operation with one recipient and an amount
CREATE FUNCTION pg_temp.p_zelle_op(p_conv uuid, p_cuenta text, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid; v_acc uuid; v_ct uuid;
BEGIN
  SELECT account_id, contact_id INTO v_acc, v_ct FROM conversations WHERE id = p_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (v_acc, p_conv, v_ct, 'collecting_information', 'remesa', 'zelle', 'GYD', p_monto) RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Titular ' || p_cuenta, p_cuenta, 1, 1, 'notes_parse', 'vigente');
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.p_op1(p_conv uuid) RETURNS uuid
LANGUAGE sql AS $f$ SELECT id FROM remittance_operations WHERE conversation_id = p_conv AND status NOT IN ('completed', 'cancelled') ORDER BY created_at, id LIMIT 1; $f$;

DO $$
DECLARE
  c record; v_r jsonb; v_op uuid; v_op2 uuid; v_n int;
BEGIN
  -- 1 amount before a deposit
  SELECT * INTO c FROM pg_temp.p_conv(1);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.ortiz@example.com', 'q1a');
  v_op := pg_temp.p_op1(c.conv);
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'monto', '19500'::jsonb, 'q1b');
  PERFORM pg_temp.p_eq('1 ok', (v_r ->> 'ok') || '/' || (v_r ->> 'monto_gyd'), 'true/19500');
  PERFORM pg_temp.p_eq('1 amount stored', (SELECT trim_scale(quoted_source_amount)::text FROM remittance_operations WHERE id = v_op), '19500');
  PERFORM pg_temp.p_eq('1 message', (v_r ->> 'mensaje' LIKE 'Listo:%19,500 GYD%' AND v_r ->> 'mensaje' LIKE '%Todavia no hay deposito verificado%')::text, 'true');
  PERFORM pg_temp.p_eq('1 destination recalculated', (SELECT (quoted_destination_amount IS NOT NULL)::text FROM remittance_operations WHERE id = v_op), 'true');
  PERFORM pg_temp.p_eq('1 audit actor', (SELECT actor FROM remittance_admin_audit WHERE row_id = v_op AND action = 'agent_amount_change'), 'agent:modificar_operacion n8n:q1b');
  PERFORM pg_temp.p_eq('1 recipient untouched', (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '1');
  PERFORM pg_temp.p_eq('1 log', (SELECT outcome FROM tool_execution_log WHERE tool_name = 'modificar_operacion' AND execution_id = 'q1b'), 'monto');
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'monto', '{"monto_gyd": 19500}'::jsonb, 'q1c');
  PERFORM pg_temp.p_eq('1 same value', (v_r ->> 'ok') || '/' || (v_r ->> 'cambio'), 'true/false');
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'monto', '5000'::jsonb, 'q1d');
  PERFORM pg_temp.p_eq('1 below minimum', (v_r ->> 'motivo') || '/' || (v_r ->> 'mensaje' LIKE '%13,000 GYD%')::text, 'por_debajo_del_minimo/true');
  PERFORM pg_temp.p_eq('1 nothing written', (SELECT trim_scale(quoted_source_amount)::text FROM remittance_operations WHERE id = v_op), '19500');
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'monto', '"abc"'::jsonb, 'q1e');
  PERFORM pg_temp.p_eq('1 invalid', v_r ->> 'motivo', 'monto_invalido');

  -- 2 amount after a verified deposit
  SELECT * INTO c FROM pg_temp.p_conv(2);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.ortiz2@example.com', 'q2a');
  PERFORM pg_temp.p_verifica(c.conv, 26000, '90409990029001');
  v_op := pg_temp.p_op1(c.conv);
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'monto', '30000'::jsonb, 'q2b');
  PERFORM pg_temp.p_eq('2 above the deposit', (v_r ->> 'motivo') || '/' || trim_scale((v_r ->> 'faltante_gyd')::numeric)::text || '/' || (v_r ->> 'mensaje' LIKE '%4,000 GYD%')::text, 'supera_el_deposito/4000/true');
  PERFORM pg_temp.p_eq('2 not written', (SELECT trim_scale(quoted_source_amount)::text FROM remittance_operations WHERE id = v_op), '26000');
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'monto', '20000'::jsonb, 'q2c');
  PERFORM pg_temp.p_eq('2 below the deposit', (v_r ->> 'ok') || '/' || (v_r ->> 'mensaje' LIKE '%sobran 6,000 GYD%')::text, 'true/true');

  -- 3 locks
  SELECT * INTO c FROM pg_temp.p_conv(3);
  v_op := pg_temp.p_zelle_op(c.conv, 'lock3@example.com', 15000);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('quoted_source_amount', jsonb_build_object('by', '11111111-1111-1111-1111-111111111111', 'at', now())) WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'monto', '16000'::jsonb, 'q3a');
  PERFORM pg_temp.p_eq('3 human lock', (v_r ->> 'motivo') || '/' || (SELECT trim_scale(quoted_source_amount)::text FROM remittance_operations WHERE id = v_op), 'bloqueado_por_humano/15000');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('quoted_source_amount', jsonb_build_object('by', 'automation:test', 'at', now())) WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'monto', '16000'::jsonb, 'q3b');
  PERFORM pg_temp.p_eq('3 automation lock does not block', v_r ->> 'ok', 'true');

  -- 4 several operations
  SELECT * INTO c FROM pg_temp.p_conv(4);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 20000, cup 6000', 'q4a');
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'monto', '22000'::jsonb, 'q4b');
  PERFORM pg_temp.p_eq('4 asks which', (v_r ->> 'motivo') || '/' || jsonb_array_length(v_r -> 'operaciones')::text, 'varias_operaciones/2');
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'zelle';
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'monto', '22000'::jsonb, 'q4c');
  PERFORM pg_temp.p_eq('4 with p_op', v_r ->> 'ok', 'true');
  PERFORM pg_temp.p_eq('4 plan follows', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '28000');

  -- 5 cancel without money (the cup part, still in the plan)
  SELECT id INTO v_op2 FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'cuban_card';
  v_r := cerebro_modificar_operacion(c.conv, v_op2, 'cancelar', NULL, 'q5a');
  PERFORM pg_temp.p_eq('5 cancelled', (v_r ->> 'ok') || '/' || (SELECT status FROM remittance_operations WHERE id = v_op2), 'true/cancelled');
  PERFORM pg_temp.p_eq('5 cancelled_at', (SELECT (cancelled_at IS NOT NULL)::text FROM remittance_operations WHERE id = v_op2), 'true');
  PERFORM pg_temp.p_eq('5 audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE row_id = v_op2 AND action = 'agent_operation_cancel'), '1');
  PERFORM pg_temp.p_eq('5 plan lost the part', (SELECT total_gyd::text FROM cerebro_reparto_planeado WHERE conversation_id = c.conv), '22000');
  PERFORM pg_temp.p_eq('5 other operation untouched', (SELECT status FROM remittance_operations WHERE id = v_op), 'collecting_information');
  v_r := cerebro_modificar_operacion(c.conv, v_op2, 'cancelar', NULL, 'q5b');
  PERFORM pg_temp.p_eq('5 second cancel', v_r ->> 'motivo', 'estado_no_permite');
  -- a lone operation with an open objective: the objective closes
  SELECT * INTO c FROM pg_temp.p_conv(5);
  v_op := pg_temp.p_zelle_op(c.conv, 'obj5@example.com', 15000);
  PERFORM cerebro_fijar_objetivo(c.conv, 15000, 'GYD');
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'cancelar', NULL, 'q5c');
  PERFORM pg_temp.p_eq('5 objective closed', v_r ->> 'ok' || '/' || (SELECT count(*)::text FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL), 'true/0');
  PERFORM pg_temp.p_eq('5 nothing left', (v_r ->> 'mensaje' LIKE '%No queda ninguna operacion abierta%')::text, 'true');

  -- 6 cancel with money
  SELECT * INTO c FROM pg_temp.p_conv(6);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.ortiz6@example.com', 'q6a');
  PERFORM pg_temp.p_verifica(c.conv, 26000, '90409990029002');
  v_op := pg_temp.p_op1(c.conv);
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'cancelar', NULL, 'q6b');
  PERFORM pg_temp.p_eq('6 a person handles it', (v_r ->> 'mensaje' LIKE '%una persona%' AND (SELECT status FROM remittance_operations WHERE id = v_op) <> 'cancelled')::text, 'true');
  PERFORM pg_temp.p_eq('6 reason', v_r ->> 'motivo', 'tiene_dinero');
  PERFORM pg_temp.p_eq('6 deposit kept', (SELECT count(*)::text FROM depositos_mmg WHERE trans_id = '90409990029002' AND operation_id = v_op AND anulado_en IS NULL), '1');

  -- 7 merge two empty operations
  SELECT * INTO c FROM pg_temp.p_conv(7);
  v_op := pg_temp.p_zelle_op(c.conv, 'uno7@example.com', 13000);
  v_op2 := pg_temp.p_zelle_op(c.conv, 'dos7@example.com', 14000);
  v_r := cerebro_modificar_operacion(c.conv, NULL, 'unir', NULL, 'q7a');
  PERFORM pg_temp.p_eq('7 merged', (v_r ->> 'ok') || '/' || (v_r ->> 'monto_gyd'), 'true/27000');
  -- (both rows are created in one transaction, so their created_at ties: the survivor is whichever the tool names, the other is absorbed)
  PERFORM pg_temp.p_eq('7 one survivor and one absorbed', (ARRAY[(v_r ->> 'operation_id')::uuid, (v_r ->> 'absorbida')::uuid] @> ARRAY[v_op, v_op2])::text, 'true');
  v_op := (v_r ->> 'operation_id')::uuid; v_op2 := (v_r ->> 'absorbida')::uuid;
  PERFORM pg_temp.p_eq('7 two recipients', (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '2');
  PERFORM pg_temp.p_eq('7 other cancelled', (SELECT status FROM remittance_operations WHERE id = v_op2), 'cancelled');
  PERFORM pg_temp.p_eq('7 amount', (SELECT trim_scale(quoted_source_amount)::text FROM remittance_operations WHERE id = v_op), '27000');
  PERFORM pg_temp.p_eq('7 audit', (SELECT count(*)::text FROM remittance_admin_audit WHERE action = 'agent_operation_merge' AND row_id IN (v_op, v_op2)), '2');
  -- duplicate recipient retired
  SELECT * INTO c FROM pg_temp.p_conv(8);
  v_op := pg_temp.p_zelle_op(c.conv, 'igual8@example.com', 13000);
  v_op2 := pg_temp.p_zelle_op(c.conv, 'igual8@example.com', 13000);
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'unir', jsonb_build_object('con', v_op2), 'q8a');
  PERFORM pg_temp.p_eq('8 duplicate retired', (v_r ->> 'duplicados_retirados') || '/' || (SELECT count(*)::text FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'), '1/1');

  -- 8b one holds money: it survives
  SELECT * INTO c FROM pg_temp.p_conv(9);
  PERFORM cerebro_guardar_zelle(c.conv, 'Ruben Ortiz', 'ruben.ortiz9@example.com', 'q9a');
  PERFORM pg_temp.p_verifica(c.conv, 13000, '90409990029003');
  v_op := pg_temp.p_op1(c.conv);
  v_op2 := pg_temp.p_zelle_op(c.conv, 'otro9@example.com', 0);
  v_r := cerebro_modificar_operacion(c.conv, v_op2, 'unir', jsonb_build_object('con', v_op), 'q9b');
  PERFORM pg_temp.p_eq('8b the one with money survives', (v_r ->> 'ok') || '/' || (v_r ->> 'operation_id')::uuid::text, 'true/' || v_op::text);
  PERFORM pg_temp.p_eq('8b deposit stayed', (SELECT count(*)::text FROM depositos_mmg WHERE trans_id = '90409990029003' AND operation_id = v_op), '1');
  -- different services
  SELECT * INTO c FROM pg_temp.p_conv(10);
  PERFORM cerebro_repartir_envio(c.conv, 'zelle 20000, cup 6000', 'q10a');
  SELECT id INTO v_op FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'zelle';
  SELECT id INTO v_op2 FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'cuban_card';
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'unir', jsonb_build_object('con', v_op2), 'q10b');
  PERFORM pg_temp.p_eq('8c different services', v_r ->> 'motivo', 'servicios_distintos');
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'unir', jsonb_build_object('con', gen_random_uuid()), 'q10c');
  PERFORM pg_temp.p_eq('8c unknown operation', v_r ->> 'motivo', 'operacion_no_encontrada');
  -- money on both
  SELECT * INTO c FROM pg_temp.p_conv(11);
  v_op := pg_temp.p_zelle_op(c.conv, 'm1@example.com', 13000);
  v_op2 := pg_temp.p_zelle_op(c.conv, 'm2@example.com', 13000);
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, receipt_status, source)
  SELECT x, c.conv, 'COMP-' || substr(md5(x::text), 1, 20), 13000, 'GYD', 'verified', 'bot' FROM unnest(ARRAY[v_op, v_op2]) x;
  v_r := cerebro_modificar_operacion(c.conv, v_op, 'unir', jsonb_build_object('con', v_op2), 'q11a');
  PERFORM pg_temp.p_eq('8d money on both', v_r ->> 'motivo', 'dinero_en_ambas');

  -- 9 ACL
  PERFORM pg_temp.p_eq('9 acl', has_function_privilege('authenticated', 'cerebro_modificar_operacion(uuid,uuid,text,jsonb,text)', 'EXECUTE')::text || ':' ||
                               has_function_privilege('anon', 'cerebro_modificar_operacion(uuid,uuid,text,jsonb,text)', 'EXECUTE')::text || ':' ||
                               has_function_privilege('service_role', 'cerebro_modificar_operacion(uuid,uuid,text,jsonb,text)', 'EXECUTE')::text, 'false:false:true');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
