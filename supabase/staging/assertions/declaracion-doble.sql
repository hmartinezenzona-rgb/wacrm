\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 371 (two services declared in one turn become a planned split; when in doubt the bot is told to ask).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; the DO block ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh (which strips \set/BEGIN/ROLLBACK/COMMIT).
-- Synthetic fixtures only: contacts 'PRUEBA declaracion N', phones 5990371xxxx.
-- Shape of exec 727547 (owner test, conv 2ca2cf79): one message "2 recargas a <numbers> y tambien un zelle de 50 USD", the recarga operation holds its
-- agreed 12,400 (written this turn), calcular_usd(50, zelle) left its via row (13,000) in the execution; no Zelle account, no plan.
-- The hook runs through its real entry point, cerebro_verificar_coherencia_servicio(conv, exec).
-- Cases:
--   1  727547 shape -> plan recarga 12,400 + zelle 13,000 (25,400), two agreed-amount operations, no group, no money, objective 25,400 (calcular_usd had left
--      13,000), one log row 'declaracion_doble' = planeado, no pending fact, the coherence answer is the usual one
--   2  the same execution again -> nothing new (one plan, two operations, one log row)
--   3  price question ("¿cuanto sale un zelle de 50?") -> no plan, no new operation, pending fact (zelle 13,000, motivo pregunta) readable; same with the words
--      cuanto/sale and no question mark
--   4  the customer never named Zelle -> no plan, pending fact y_sin_nombrar;   5  no customer text at all -> pending fact sin_texto
--   6  two different services quoted in the turn (comparison) -> no plan, no pending fact
--   7  the quote belongs to another execution -> nothing;   8  a plan already exists -> untouched
--   9  recarga amount not agreed (a request) -> nothing;   10 recarga agreed BEFORE the last bot message (an earlier turn) -> nothing
--   11 quote below the Zelle minimum -> nothing;   12 a funded recarga -> nothing;   13 a Zelle operation with money -> nothing
--   14 an empty Zelle operation opened earlier in the turn (recipient writer) is reused: still two operations
--   15 after the plan: Zelle data arriving later is saved on the planned Zelle operation (two operations)
--   16 after the plan the customer drops the Zelle part (cancelar): the remaining recarga takes a deposit of 12,400 like a recarga that never had a plan
--   17 deposit of exactly 25,400 applies the plan (one group, 12,400 / 13,000, no incident);  18 deposit of 12,400 only lands on the recarga, Zelle stays
--      pending, nothing grouped, plan kept
--   19 the pending fact disappears once a plan exists or a Zelle operation exists, and when it is older than the quote window
--   20 a failing hook never changes the coherence answer
-- =====================================================================

CREATE FUNCTION pg_temp.p_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990371' || lpad(p_n::text, 4, '0'), 'PRUEBA declaracion ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- the turn: the execution started 2 minutes ago, the customer wrote 3 minutes ago (p_text NULL = no customer text), the bot's last reply was 10 minutes ago
CREATE FUNCTION pg_temp.p_turno(p_conv uuid, p_exec text, p_text text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO cerebro_ejecuciones (execution_id, conversation_id, status, started_at, created_at)
  VALUES (p_exec, p_conv, 'running', now() - interval '2 minutes', now() - interval '2 minutes')
  ON CONFLICT (execution_id) DO NOTHING;
  IF NOT EXISTS (SELECT 1 FROM messages WHERE conversation_id = p_conv AND sender_type = 'agent') THEN
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (p_conv, 'agent', 'text', 'PRUEBA bot anterior', now() - interval '10 minutes');
  END IF;
  IF p_text IS NOT NULL THEN
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (p_conv, 'customer', 'text', p_text, now() - interval '3 minutes');
  END IF;
END $f$;

-- the recarga the numbers wrote this turn: its agreed amount (audit now) with the numbers 6,200 each
CREATE FUNCTION pg_temp.p_recarga(p_conv uuid, p_monto numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_r uuid;
BEGIN
  v_r := _cerebro_op_parte(p_conv, 'recarga', 'agent:registrar_numeros_recarga', 'test shape');
  PERFORM _cerebro_fijar_monto_acordado(v_r, p_monto, 'automation:registrar_numeros_recarga');
  RETURN v_r;
END $f$;

-- what calcular_usd leaves: the via row of the execution, the last quote and the objective (a recarga is open, so it sets one)
CREATE FUNCTION pg_temp.p_cotiza(p_conv uuid, p_exec text, p_via text, p_gyd numeric) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM cerebro_registrar_cotizacion(p_conv, p_gyd, floor(p_gyd / 260), 'USD', 'calcular_usd');
  PERFORM cerebro_registrar_via_cotizada(p_conv, 'calcular_usd', p_via, p_exec, p_gyd);
  PERFORM cerebro_fijar_objetivo(p_conv, floor(p_gyd / 260), 'USD');
END $f$;

CREATE FUNCTION pg_temp.p_turno_completo(p_conv uuid, p_exec text, p_text text, p_via text, p_gyd numeric, p_recarga numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_r uuid;
BEGIN
  PERFORM pg_temp.p_turno(p_conv, p_exec, p_text);
  v_r := pg_temp.p_recarga(p_conv, p_recarga);
  IF p_via IS NOT NULL THEN PERFORM pg_temp.p_cotiza(p_conv, p_exec, p_via, p_gyd); END IF;
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.p_ops(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(cerebro_riel_op(o.id) || '/' || coalesce(o.quoted_source_amount::int::text, '-'), ';' ORDER BY cerebro_riel_op(o.id)), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv AND o.status NOT IN ('completed', 'cancelled');
$f$;

CREATE FUNCTION pg_temp.p_plan(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce((SELECT total_gyd::int::text || ':' || (SELECT string_agg(e ->> 'servicio' || '/' || trim_scale((e ->> 'monto_gyd')::numeric)::text, ';' ORDER BY ord)
                                                           FROM jsonb_array_elements(pl.partes) WITH ORDINALITY t(e, ord))
                     FROM cerebro_reparto_planeado pl WHERE pl.conversation_id = p_conv), '-');
$f$;

CREATE FUNCTION pg_temp.p_pend(p_conv uuid) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE r jsonb;
BEGIN
  r := cerebro_declaracion_pendiente(p_conv);
  IF r IS NULL THEN RETURN '-'; END IF;
  RETURN (r ->> 'servicio') || '/' || trim_scale((r ->> 'monto_gyd')::numeric)::text || '/' || (r ->> 'motivo');
END $f$;

CREATE FUNCTION pg_temp.p_logs(p_conv uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(outcome, ',' ORDER BY created_at), '-') FROM tool_execution_log WHERE conversation_id = p_conv AND tool_name = 'declaracion_doble';
$f$;

CREATE FUNCTION pg_temp.p_eq(p_label text, p_got text, p_exp text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_got IS DISTINCT FROM p_exp THEN RAISE EXCEPTION 'case %: expected [%], got [%]', p_label, p_exp, p_got; END IF;
END $f$;

CREATE FUNCTION pg_temp.p_registra(p_conv uuid, p_monto numeric, p_ref text)
RETURNS TABLE(deal_id uuid, accion text, es_revendedor boolean, sumado boolean)
LANGUAGE sql AS $f$
  SELECT * FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751',
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           'COMP-' || substr(md5(p_ref), 1, 20));
$f$;

DO $$
DECLARE
  c record; v_r uuid; v_out jsonb; v_n int; v_z uuid; v_o record; v_st text;
  c_txt constant text := '2 recargas a 55599180 y 55599181 y tambien un zelle de 50 usd';
BEGIN
  -- 1 the 727547 shape
  SELECT * INTO c FROM pg_temp.p_conv(1);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-1', c_txt, 'zelle', 13000, 12400);
  PERFORM pg_temp.p_eq('1 objective left by calcular_usd', (SELECT monto::text FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL), '13000');
  PERFORM pg_temp.p_eq('1 before', pg_temp.p_ops(c.conv) || '|' || pg_temp.p_plan(c.conv), 'recarga/12400|-');
  v_out := cerebro_verificar_coherencia_servicio(c.conv, 'dd-1');
  PERFORM pg_temp.p_eq('1 plan', pg_temp.p_plan(c.conv), '25400:recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('1 operations', pg_temp.p_ops(c.conv), 'recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('1 not grouped', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');
  PERFORM pg_temp.p_eq('1 no money', (SELECT bool_or(_cerebro_op_tiene_dinero(id))::text FROM remittance_operations WHERE conversation_id = c.conv), 'false');
  PERFORM pg_temp.p_eq('1 both agreed', (SELECT bool_and(_cerebro_op_monto_acordado(id))::text FROM remittance_operations WHERE conversation_id = c.conv), 'true');
  PERFORM pg_temp.p_eq('1 objective is the plan total', (SELECT monto::text FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL), '25400');
  PERFORM pg_temp.p_eq('1 log', pg_temp.p_logs(c.conv), 'planeado');
  PERFORM pg_temp.p_eq('1 no pending fact', pg_temp.p_pend(c.conv), '-');
  PERFORM pg_temp.p_eq('1 coherence answer', v_out ->> 'motivo', 'operacion_ambigua');

  -- 2 the same execution again
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-1');
  PERFORM pg_temp.p_eq('2 plan', pg_temp.p_plan(c.conv), '25400:recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('2 operations', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv), '2');
  PERFORM pg_temp.p_eq('2 one log row', pg_temp.p_logs(c.conv), 'planeado');

  -- 14/15/16/17/18 are run on copies of the planned state below; 15 first (Zelle data arriving later) on conversation 1
  PERFORM cerebro_guardar_zelle(c.conv, 'PRUEBA Juan Perez', 'prueba.declaracion@example.com', 'dd-1b', NULL, 'registrar_beneficiario_zelle', NULL, false, NULL);
  PERFORM pg_temp.p_eq('15 still two operations', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND status NOT IN ('completed', 'cancelled')), '2');
  PERFORM pg_temp.p_eq('15 data on the planned zelle operation', (SELECT count(*)::text FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
                                                                   WHERE o.conversation_id = c.conv AND cerebro_riel_op(o.id) = 'zelle' AND b.status = 'vigente' AND b.zelle_account IS NOT NULL), '1');
  PERFORM pg_temp.p_eq('15 plan kept', pg_temp.p_plan(c.conv), '25400:recarga/12400;zelle/13000');

  -- 3 price question
  SELECT * INTO c FROM pg_temp.p_conv(3);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-3', '2 recargas a 55599180 y 55599181. ¿cuanto sale un zelle de 50 usd?', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-3');
  PERFORM pg_temp.p_eq('3 no plan', pg_temp.p_plan(c.conv), '-');
  PERFORM pg_temp.p_eq('3 no new operation', pg_temp.p_ops(c.conv), 'recarga/12400');
  PERFORM pg_temp.p_eq('3 pending fact', pg_temp.p_pend(c.conv), 'zelle/13000/pregunta');
  PERFORM pg_temp.p_eq('3 log', pg_temp.p_logs(c.conv), 'duda:pregunta');
  PERFORM pg_temp.p_eq('3 objective untouched', (SELECT monto::text FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL), '13000');
  -- the same words without a question mark
  SELECT * INTO c FROM pg_temp.p_conv(31);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-31', '2 recargas a 55599180 y 55599181 y cuanto sale el zelle de 50 usd', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-31');
  PERFORM pg_temp.p_eq('3b no plan', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|zelle/13000/pregunta');

  -- 4 Zelle never named by the customer
  SELECT * INTO c FROM pg_temp.p_conv(4);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-4', '2 recargas a 55599180 y 55599181', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-4');
  PERFORM pg_temp.p_eq('4', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|recarga/12400|zelle/13000/y_sin_nombrar');

  -- 5 no customer text
  SELECT * INTO c FROM pg_temp.p_conv(5);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-5', NULL, 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-5');
  PERFORM pg_temp.p_eq('5', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|recarga/12400|zelle/13000/sin_texto');

  -- 6 two different services quoted (comparison)
  SELECT * INTO c FROM pg_temp.p_conv(6);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-6', c_txt || ' o clasica', 'zelle', 13000, 12400);
  PERFORM pg_temp.p_cotiza(c.conv, 'dd-6', 'clasica', 14000);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-6');
  PERFORM pg_temp.p_eq('6', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv) || '|' || pg_temp.p_pend(c.conv) || '|' || pg_temp.p_logs(c.conv), '-|recarga/12400|-|-');

  -- 7 the quote belongs to another execution
  SELECT * INTO c FROM pg_temp.p_conv(7);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-7', c_txt, NULL, NULL, 12400);
  PERFORM pg_temp.p_cotiza(c.conv, 'dd-7-old', 'zelle', 13000);
  UPDATE cerebro_ultima_cotizacion SET cotizado_en = now() - interval '1 hour' WHERE conversation_id = c.conv;
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-7');
  PERFORM pg_temp.p_eq('7', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|recarga/12400|-');

  -- 8 a plan already exists
  SELECT * INTO c FROM pg_temp.p_conv(8);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-8', c_txt, 'zelle', 13000, 12400);
  PERFORM _cerebro_reparto_planear(c.conv, '[{"servicio":"recarga","monto_gyd":12400},{"servicio":"clasica","monto_gyd":14000}]'::jsonb, false, 'agent:repartir_envio');
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-8');
  PERFORM pg_temp.p_eq('8', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv) || '|' || pg_temp.p_logs(c.conv), '26400:recarga/12400;clasica/14000|recarga/12400|-');

  -- 9 recarga amount not agreed (a request: plain update, no agreed audit)
  SELECT * INTO c FROM pg_temp.p_conv(9);
  PERFORM pg_temp.p_turno(c.conv, 'dd-9', c_txt);
  v_r := _cerebro_op_parte(c.conv, 'recarga', 'agent:registrar_numeros_recarga', 'test shape');
  UPDATE remittance_operations SET quoted_source_amount = 12400 WHERE id = v_r;
  PERFORM pg_temp.p_cotiza(c.conv, 'dd-9', 'zelle', 13000);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-9');
  PERFORM pg_temp.p_eq('9', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|-');

  -- 10 recarga agreed before the bot's last message (an earlier turn)
  SELECT * INTO c FROM pg_temp.p_conv(10);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-10', c_txt, 'zelle', 13000, 12400);
  UPDATE remittance_admin_audit SET created_at = now() - interval '2 hours' WHERE row_id = v_r AND action = 'agent_amount_change';
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-10');
  PERFORM pg_temp.p_eq('10', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|-');

  -- 11 below the Zelle minimum
  SELECT * INTO c FROM pg_temp.p_conv(11);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-11', c_txt, 'zelle', 5000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-11');
  PERFORM pg_temp.p_eq('11', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|-');

  -- 12 a funded recarga
  SELECT * INTO c FROM pg_temp.p_conv(12);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-12', c_txt, 'zelle', 13000, 12400);
  PERFORM pg_temp.p_registra(c.conv, 12400, '37100012');
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-12');
  PERFORM pg_temp.p_eq('12', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|-');

  -- 13 a Zelle operation that holds money
  SELECT * INTO c FROM pg_temp.p_conv(13);
  PERFORM pg_temp.p_turno(c.conv, 'dd-13', c_txt);
  v_z := _cerebro_op_parte(c.conv, 'zelle', 'agent:guardar_zelle', 'test shape');
  PERFORM _cerebro_fijar_monto_acordado(v_z, 13000, 'agent:guardar_zelle');
  PERFORM pg_temp.p_registra(c.conv, 13000, '37100013');
  v_r := pg_temp.p_recarga(c.conv, 12400);
  PERFORM pg_temp.p_cotiza(c.conv, 'dd-13', 'zelle', 13000);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-13');
  PERFORM pg_temp.p_eq('13', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_pend(c.conv), '-|-');

  -- 14 an empty Zelle operation opened earlier in the turn is reused
  SELECT * INTO c FROM pg_temp.p_conv(14);
  PERFORM pg_temp.p_turno(c.conv, 'dd-14', c_txt);
  v_z := _cerebro_op_parte(c.conv, 'zelle', 'agent:guardar_zelle', 'test shape');
  v_r := pg_temp.p_recarga(c.conv, 12400);
  PERFORM pg_temp.p_cotiza(c.conv, 'dd-14', 'zelle', 13000);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-14');
  PERFORM pg_temp.p_eq('14', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv) || '|' || (SELECT (id = v_z)::text FROM remittance_operations WHERE conversation_id = c.conv AND cerebro_riel_op(id) = 'zelle'),
                       '25400:recarga/12400;zelle/13000|recarga/12400;zelle/13000|true');

  -- 16 the customer drops the Zelle part; the recarga takes its deposit normally
  SELECT * INTO c FROM pg_temp.p_conv(16);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-16', c_txt, 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-16');
  SELECT o.id INTO v_z FROM remittance_operations o WHERE o.conversation_id = c.conv AND cerebro_riel_op(o.id) = 'zelle';
  v_out := cerebro_modificar_operacion(c.conv, v_z, 'cancelar', NULL, 'dd-16b');
  PERFORM pg_temp.p_eq('16 cancelled', (v_out ->> 'ok'), 'true');
  PERFORM pg_temp.p_eq('16 one operation left', pg_temp.p_ops(c.conv), 'recarga/12400');
  PERFORM pg_temp.p_registra(c.conv, 12400, '37100016');
  PERFORM pg_temp.p_eq('16 receipt on the recarga', (SELECT count(*)::text FROM remittance_operation_receipts r WHERE r.operation_id = v_r), '1');
  PERFORM pg_temp.p_eq('16 not grouped', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '0');
  -- the baseline: the same recarga alone, no plan ever; its status after the same deposit is the one the dropped-part case must reach too
  SELECT * INTO c FROM pg_temp.p_conv(161);
  PERFORM pg_temp.p_turno(c.conv, 'dd-161', 'recarga');
  PERFORM pg_temp.p_recarga(c.conv, 12400);
  PERFORM pg_temp.p_registra(c.conv, 12400, '37100161');
  PERFORM pg_temp.p_eq('16 same status as a recarga that never had a plan',
    (SELECT status FROM remittance_operations WHERE conversation_id = c.conv),
    (SELECT status FROM remittance_operations WHERE id = v_r));

  -- 17 deposit of exactly the total applies the plan
  SELECT * INTO c FROM pg_temp.p_conv(17);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-17', c_txt, 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-17');
  PERFORM pg_temp.p_registra(c.conv, 25400, '37100017');
  PERFORM pg_temp.p_eq('17 one group of two', (SELECT count(DISTINCT mixed_group_id)::text || '/' || count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL), '1/2');
  PERFORM pg_temp.p_eq('17 amounts', pg_temp.p_ops(c.conv), 'recarga/12400;zelle/13000');
  PERFORM pg_temp.p_eq('17 plan gone', pg_temp.p_plan(c.conv), '-');
  -- the statuses a receipt-only deposit leaves are the ones the same plan made by repartir_envio leaves (no extra incident from the objective)
  SELECT string_agg(cerebro_riel_op(id) || ':' || status, ';' ORDER BY cerebro_riel_op(id)) INTO v_st FROM remittance_operations WHERE conversation_id = c.conv;
  SELECT * INTO c FROM pg_temp.p_conv(171);
  PERFORM pg_temp.p_turno(c.conv, 'dd-171', 'x');
  PERFORM pg_temp.p_recarga(c.conv, 12400);
  PERFORM cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'dd-171');
  PERFORM pg_temp.p_registra(c.conv, 25400, '37100171');
  PERFORM pg_temp.p_eq('17 same statuses as a plan made by repartir_envio',
    v_st, (SELECT string_agg(cerebro_riel_op(id) || ':' || status, ';' ORDER BY cerebro_riel_op(id)) FROM remittance_operations WHERE conversation_id = c.conv));

  -- 18 deposit of the recarga only
  SELECT * INTO c FROM pg_temp.p_conv(18);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-18', c_txt, 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-18');
  PERFORM pg_temp.p_registra(c.conv, 12400, '37100018');
  PERFORM pg_temp.p_eq('18 receipt on the recarga only', (SELECT count(*)::text FROM remittance_operation_receipts r WHERE r.operation_id = v_r), '1');
  PERFORM pg_temp.p_eq('18 zelle has none', (SELECT count(*)::text FROM remittance_operation_receipts r JOIN remittance_operations o ON o.id = r.operation_id
                                              WHERE o.conversation_id = c.conv AND cerebro_riel_op(o.id) = 'zelle'), '0');
  PERFORM pg_temp.p_eq('18 nothing grouped, plan kept', (SELECT count(*)::text FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL) || '|' || pg_temp.p_plan(c.conv),
                       '0|25400:recarga/12400;zelle/13000');

  -- 19 the pending fact goes away
  SELECT * INTO c FROM pg_temp.p_conv(19);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-19', '2 recargas a 55599180 y 55599181. ¿cuanto sale un zelle de 50 usd?', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-19');
  PERFORM pg_temp.p_eq('19 there', pg_temp.p_pend(c.conv), 'zelle/13000/pregunta');
  -- the customer says yes: the bot plans it (repartir_envio) -> gone
  PERFORM cerebro_repartir_envio(c.conv, 'recarga 12400, zelle 13000', 'dd-19b');
  PERFORM pg_temp.p_eq('19 plan makes it go', pg_temp.p_pend(c.conv), '-');
  SELECT * INTO c FROM pg_temp.p_conv(191);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-191', '2 recargas a 55599180 y 55599181. ¿cuanto sale un zelle de 50 usd?', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-191');
  PERFORM pg_temp.p_eq('19b there', pg_temp.p_pend(c.conv), 'zelle/13000/pregunta');
  PERFORM _cerebro_op_parte(c.conv, 'zelle', 'agent:guardar_zelle', 'test shape');
  PERFORM pg_temp.p_eq('19b a zelle operation makes it go', pg_temp.p_pend(c.conv), '-');
  SELECT * INTO c FROM pg_temp.p_conv(192);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-192', '2 recargas a 55599180 y 55599181. ¿cuanto sale un zelle de 50 usd?', 'zelle', 13000, 12400);
  PERFORM cerebro_verificar_coherencia_servicio(c.conv, 'dd-192');
  UPDATE cerebro_declaracion_duda SET creado_at = now() - interval '7 hours' WHERE conversation_id = c.conv;
  PERFORM pg_temp.p_eq('19c older than the quote window', pg_temp.p_pend(c.conv), '-');

  -- 20 a failing hook never changes the coherence answer
  SELECT * INTO c FROM pg_temp.p_conv(20);
  v_r := pg_temp.p_turno_completo(c.conv, 'dd-20', c_txt, 'zelle', 13000, 12400);
  v_out := cerebro_verificar_coherencia_servicio(c.conv, 'dd-20-clean');
  EXECUTE 'CREATE OR REPLACE FUNCTION public._cerebro_declaracion_doble(p_conv uuid, p_exec text) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER AS $b$ BEGIN RAISE EXCEPTION ''boom''; END $b$';
  v_out := cerebro_verificar_coherencia_servicio(c.conv, 'dd-20');
  PERFORM pg_temp.p_eq('20 answer', v_out ->> 'coherente', 'true');
  PERFORM pg_temp.p_eq('20 nothing changed', pg_temp.p_plan(c.conv) || '|' || pg_temp.p_ops(c.conv), '-|recarga/12400');

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
