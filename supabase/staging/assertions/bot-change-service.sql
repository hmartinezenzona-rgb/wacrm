\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 230 (cerebro_cambiar_servicio: the bot changes the service of the conversation's open operation).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so
-- nothing is kept). Run it wrapped (BEGIN; \i this file; ROLLBACK;) with these two lines stripped, as the other assertions: a
-- plain `psql -1` can COMMIT a fixture. Each passing case NOTICEs.
-- Production 2026-10-08 (Carlos): cash USD quoted at 290 (162 USD), receipt sent, then "Mejor zelle". The bot quoted 181 USD by Zelle
-- in words but had no write path to Zelle, so the operation stayed efectivo_usd / 162 USD. cerebro_cambiar_servicio(conversation,
-- service, execution) is that path: it resolves the conversation's open operation, applies the SAME core as the panel's
-- crm_cambiar_servicio (_cambiar_servicio_core), audits it as automation_service_change and returns the new quote in one call.
-- Rates are read from crm_tasa_vigente / the Zelle tiers, so the expectations follow staging's rates.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t230_op(p_user uuid, p_acc uuid, p_phone text, p_dm text, p_amount numeric,
                                p_status text DEFAULT 'collecting_information', p_locks jsonb DEFAULT '{}'::jsonb,
                                p_service text DEFAULT 'remesa', p_conv uuid DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_conv uuid := p_conv; v_op uuid;
BEGIN
  IF v_conv IS NULL THEN
    INSERT INTO contacts (user_id, account_id, phone, name) VALUES (p_user, p_acc, '5990230' || lpad((floor(random() * 10000000))::bigint::text, 7, '0'), 'test230') RETURNING id INTO v_ct;
    INSERT INTO conversations (user_id, account_id, contact_id) VALUES (p_user, p_acc, v_ct) RETURNING id INTO v_conv;
  ELSE
    SELECT contact_id INTO v_ct FROM conversations WHERE id = v_conv;
  END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency,
                                     quoted_source_amount, admin_locked_fields)
  VALUES (p_acc, v_conv, v_ct, 'collecting_information', p_service, p_dm, 'GYD', p_amount, p_locks)
  RETURNING id INTO v_op;
  IF p_status <> 'collecting_information' THEN
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = p_status WHERE id = v_op;
    PERFORM set_config('wacrm.origin', '', true);
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t230_ben(p_op uuid, p_type text, p_card text, p_phone text, p_pos integer,
                                 p_amount numeric DEFAULT NULL, p_cur text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, address, position, block_index, source, status, amount, currency)
  VALUES (p_op, p_type, p_card, p_phone, CASE WHEN p_type = 'efectivo_usd' THEN 'Calle 1, Bayamo' END, p_pos, p_pos, 'notes_parse', 'vigente', p_amount, p_cur)
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.t230_conv(p_op uuid) RETURNS uuid LANGUAGE sql AS $f$
  SELECT conversation_id FROM remittance_operations WHERE id = p_op;
$f$;

-- 'type/currency/amount' of the only current recipient, 'n=<count>' otherwise.
CREATE FUNCTION pg_temp.t230_one(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT CASE WHEN count(*) = 1 THEN max(beneficiary_type || '/' || coalesce(currency, '-') || '/' || coalesce(amount::text, '-'))
              ELSE 'n=' || count(*) END
    FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$f$;

-- Everything that could reach a customer: messages, outbox rows, notifications, queued http calls.
CREATE FUNCTION pg_temp.t230_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990230%')
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990230%')
       + (SELECT count(*) FROM notifications)
       + (SELECT count(*) FROM net.http_request_queue);
$f$;

-- The observable state of an operation after a change (panel and bot must leave the same one).
CREATE FUNCTION pg_temp.t230_state(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws('|', o.service_type, coalesce(o.delivery_method, '-'), coalesce(o.destination_currency, '-'),
                   coalesce(o.quoted_destination_amount::text, '-'), coalesce(o.quoted_destination_rate::text, '-'),
                   coalesce(o.quoted_destination_origin, '-'), o.status,
                   (SELECT coalesce(string_agg(b.beneficiary_type || ':' || b.status || ':' || coalesce(b.amount::text, '-'), ',' ORDER BY b.position), '')
                      FROM remittance_beneficiaries b WHERE b.operation_id = o.id))
    FROM remittance_operations o WHERE o.id = p_op;
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_efe numeric := crm_tasa_vigente('efectivo');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_card constant text := '9760039001240356';
  v_ph constant text := '58528291';
  v_op uuid; v_op2 uuid; v_conv uuid; v_r jsonb; v_o remittance_operations%ROWTYPE; v_n int; v_base bigint;
  v_zelle_usd numeric; v_zelle_rate numeric; v_efe_usd numeric; v_ben uuid; v_a remittance_admin_audit%ROWTYPE;
  v_before text; v_t text; v_panel jsonb; v_bot jsonb; v_pop uuid; v_bop uuid; v_audits int;
BEGIN
  IF NOT (v_usd > 0 AND v_efe > 0 AND v_cup > 0) THEN RAISE EXCEPTION 'setup: the rates are needed (usd %, efectivo %, cup %)', v_usd, v_efe, v_cup; END IF;
  SELECT z.usd, z.tasa INTO v_zelle_usd, v_zelle_rate FROM cerebro_zelle_cotizar_gyd(47100) z;
  v_efe_usd := floor(47100 / v_efe);
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- ---- a. the incident: efectivo_usd after a verified deposit -> zelle ----
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300001', 'efectivo_usd', 47100, 'ready_to_transfer');
  v_ben := pg_temp.t230_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.quoted_destination_amount IS DISTINCT FROM v_efe_usd OR v_o.destination_currency <> 'USD' OR v_o.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'setup a: the cash operation should be % USD in ready_to_transfer, got % % %', v_efe_usd, v_o.quoted_destination_amount, v_o.destination_currency, v_o.status; END IF;
  v_base := pg_temp.t230_side();
  v_conv := pg_temp.t230_conv(v_op);

  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-a');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'ok') <> 'true' OR (v_r ->> 'changed') <> 'true' OR (v_r ->> 'operation_id') <> v_op::text
     OR (v_r ->> 'servicio') <> 'zelle' OR (v_r ->> 'source_amount_gyd')::numeric <> 47100
     OR (v_r ->> 'destination_amount')::numeric <> v_zelle_usd OR (v_r ->> 'destination_currency') <> 'USD'
     OR (v_r ->> 'rate')::numeric <> v_zelle_rate OR (v_r ->> 'status') <> 'ready_to_transfer'
     OR (v_r ->> 'retired_recipients')::int <> 1
     OR (v_r #>> '{previous,servicio}') <> 'efectivo_usd' OR (v_r #>> '{previous,destination_amount}')::numeric <> v_efe_usd
     OR (v_r #>> '{previous,destination_currency}') <> 'USD' OR (v_r #>> '{previous,rate}')::numeric <> v_efe THEN
    RAISE EXCEPTION 'case a: unexpected result %', v_r; END IF;
  IF v_o.delivery_method <> 'zelle' OR v_o.service_type <> 'remesa' OR v_o.quoted_destination_amount <> v_zelle_usd
     OR v_o.destination_currency <> 'USD' OR v_o.quoted_destination_origin <> 'calculated' OR v_o.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case a: the operation should be remesa/zelle/% USD/calculated/ready_to_transfer, got % / % / % / % / %',
      v_zelle_usd, v_o.service_type, v_o.delivery_method, v_o.quoted_destination_amount, v_o.quoted_destination_origin, v_o.status; END IF;
  IF v_zelle_usd <> 181 AND v_usd = 260 THEN RAISE EXCEPTION 'case a: 47,100 GYD at 260 must quote 181 USD by Zelle, got %', v_zelle_usd; END IF;
  IF (SELECT status FROM remittance_beneficiaries WHERE id = v_ben) <> 'reemplazado' OR pg_temp.t230_one(v_op) <> 'n=0' THEN
    RAISE EXCEPTION 'case a: the cash recipient must be retired'; END IF;
  IF NOT (v_o.admin_locked_fields ? 'delivery_method') OR (v_o.admin_locked_fields ? 'quoted_destination_amount')
     OR (v_o.admin_locked_fields ->> 'quoted_destination_amount') IS NOT NULL
     OR (v_o.admin_locked_fields #>> '{delivery_method,by}') NOT LIKE 'automation:%' THEN
    RAISE EXCEPTION 'case a: the rail must be locked by the automation and the recalculated quote must not be, got %', v_o.admin_locked_fields; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case a: expected one service audit row, got %', v_n; END IF;
  SELECT * INTO v_a FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service';
  IF v_a.action <> 'automation_service_change' OR v_a.actor NOT LIKE 'automation:%' OR v_a.reason NOT LIKE '%exec230-a%'
     OR v_a.before ->> 'service' <> 'efectivo_usd' OR v_a.after ->> 'service' <> 'zelle'
     OR (v_a.before ->> 'quoted_destination_amount')::numeric <> v_efe_usd OR (v_a.after ->> 'quoted_destination_amount')::numeric <> v_zelle_usd THEN
    RAISE EXCEPTION 'case a: the audit row must carry actor, execution, before and after, got % / % / % / %', v_a.action, v_a.actor, v_a.reason, v_a.after; END IF;
  IF NOT EXISTS (SELECT 1 FROM tool_execution_log WHERE tool_name = 'cambiar_servicio' AND execution_id = 'exec230-a' AND operation_id = v_op) THEN
    RAISE EXCEPTION 'case a: the call should be logged in tool_execution_log'; END IF;
  IF calculator_resolve_operation_service(v_op, 'zelle') <> 'ZELLE' THEN RAISE EXCEPTION 'case a: the ledger should price ZELLE'; END IF;
  IF pg_temp.t230_side() > v_base THEN
    RAISE EXCEPTION 'case a: messages/outbox/notifications/net queue grew from % to %', v_base, pg_temp.t230_side(); END IF;
  RAISE NOTICE 'PASS a: efectivo_usd -> zelle after verification: % -> % USD, status kept, recipient retired, audited, nothing sent', v_efe_usd, v_zelle_usd;

  -- ---- b. idempotent: the same service again changes and audits nothing; a late stale write of the old rail is suppressed ----
  v_before := pg_temp.t230_state(v_op);
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-b');
  IF (v_r ->> 'ok') <> 'true' OR (v_r ->> 'changed') <> 'false' OR (v_r ->> 'servicio') <> 'zelle'
     OR (v_r ->> 'destination_amount')::numeric <> v_zelle_usd OR pg_temp.t230_state(v_op) <> v_before THEN
    RAISE EXCEPTION 'case b: the same service must be a no-op that still answers the quote, got %', v_r; END IF;
  v_r := cerebro_cambiar_servicio(v_conv, 'ZELLE', 'exec230-a');
  IF (v_r ->> 'changed') <> 'false' THEN RAISE EXCEPTION 'case b: upper case and a replayed execution must be a no-op'; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case b: no new audit row expected, got % in total', v_n; END IF;
  -- the stale turn of the race: the receipt turn marks "efectivo" from its chat memory after the switch
  PERFORM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec230-stale');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'zelle' THEN
    RAISE EXCEPTION 'case b: a late bot write of the old rail must not undo the change'; END IF;
  RAISE NOTICE 'PASS b: same service is a no-op (idempotent), and the late stale marcar_destino_usd is suppressed';

  -- ---- c. the bot can change its own earlier change; aliases: cup, efectivo ----
  v_r := cerebro_cambiar_servicio(v_conv, 'cup', 'exec230-c1');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'ok') <> 'true' OR (v_r ->> 'servicio') <> 'cuban_card' OR v_o.delivery_method <> 'cuban_card'
     OR v_o.destination_currency <> 'CUP' OR v_o.quoted_destination_amount <> round(47100 * v_cup)
     OR (v_r ->> 'destination_amount')::numeric <> round(47100 * v_cup) OR (v_r #>> '{previous,servicio}') <> 'zelle' THEN
    RAISE EXCEPTION 'case c1: zelle -> cup (alias of cuban_card) expected, got % %', v_r, pg_temp.t230_state(v_op); END IF;
  v_r := cerebro_cambiar_servicio(v_conv, 'Efectivo', 'exec230-c2');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'servicio') <> 'efectivo_usd' OR v_o.delivery_method <> 'efectivo_usd' OR v_o.quoted_destination_amount <> v_efe_usd THEN
    RAISE EXCEPTION 'case c2: cuban_card -> efectivo (alias) expected, got %', v_r; END IF;
  v_r := cerebro_cambiar_servicio(v_conv, ' clasica ', 'exec230-c3');
  IF (v_r ->> 'servicio') <> 'clasica' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'clasica' THEN
    RAISE EXCEPTION 'case c3: clasica expected'; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_service_change';
  IF v_n <> 4 THEN RAISE EXCEPTION 'case c: four real changes, four audit rows expected, got %', v_n; END IF;
  RAISE NOTICE 'PASS c: zelle -> cup (alias) -> efectivo (alias) -> clasica, each audited, the bot may change its own change';

  -- ---- d. zelle -> cuban_card with its recipient retired like the panel ----
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300002', 'zelle', 47100, 'deposit_verification');
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Test Zelle', 'z230@test.invalid', 1, 1, 'notes_parse', 'vigente') RETURNING id INTO v_ben;
  IF pg_temp.t230_one(v_op) NOT LIKE 'zelle/USD/%' THEN RAISE EXCEPTION 'setup d: the zelle recipient should be priced, got %', pg_temp.t230_one(v_op); END IF;
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'cuban_card', 'exec230-d');
  IF (v_r ->> 'retired_recipients')::int <> 1 OR (SELECT status FROM remittance_beneficiaries WHERE id = v_ben) <> 'reemplazado'
     OR (SELECT replaced_at FROM remittance_beneficiaries WHERE id = v_ben) IS NULL
     OR (v_r ->> 'status') <> 'deposit_verification'
     OR (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op) <> round(47100 * v_cup) THEN
    RAISE EXCEPTION 'case d: the zelle recipient must be retired, the status kept and the CUP quote made, got %', v_r; END IF;
  RAISE NOTICE 'PASS d: zelle -> cuban_card retires the zelle recipient exactly as the panel does';

  -- ---- e. parity with the panel: two identical operations, one through each door, end in the same state ----
  v_pop := pg_temp.t230_op(v_user, v_acc, '59902300003', 'cuban_card', 47100, 'ready_to_transfer');
  PERFORM pg_temp.t230_ben(v_pop, 'cuban_card', v_card, v_ph, 1);
  v_bop := pg_temp.t230_op(v_user, v_acc, '59902300004', 'cuban_card', 47100, 'ready_to_transfer');
  PERFORM pg_temp.t230_ben(v_bop, 'cuban_card', v_card, v_ph, 1);
  FOREACH v_t IN ARRAY ARRAY['clasica', 'zelle', 'efectivo_usd', 'cuban_card', 'tropical', 'recarga', 'combo', 'visa', 'saldo', 'cuban_card'] LOOP
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
    v_panel := crm_cambiar_servicio(v_pop, v_t);
    PERFORM set_config('request.jwt.claims', '', true);
    v_bot := cerebro_cambiar_servicio(pg_temp.t230_conv(v_bop), v_t, 'exec230-e');
    IF (v_bot ->> 'ok') <> 'true' OR (v_bot ->> 'changed') <> (v_panel ->> 'changed')
       OR (v_bot ->> 'retired_recipients')::int <> (v_panel ->> 'retired_recipients')::int
       OR pg_temp.t230_state(v_pop) <> pg_temp.t230_state(v_bop) THEN
      RAISE EXCEPTION 'case e (%): panel % / bot % leave different states: % vs %', v_t, v_panel, v_bot, pg_temp.t230_state(v_pop), pg_temp.t230_state(v_bop); END IF;
  END LOOP;
  IF (SELECT string_agg(k, ',' ORDER BY k) FROM jsonb_object_keys(v_panel) k) <> 'changed,operation_id,retired_recipients,retyped_recipients,service' THEN
    RAISE EXCEPTION 'case e: the panel RPC must keep its returned shape, got %', v_panel; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_pop AND action = 'human_correction' AND field_name = 'service';
  SELECT count(*) INTO v_audits FROM remittance_admin_audit WHERE row_id = v_bop AND action = 'automation_service_change' AND field_name = 'service';
  IF v_n <> v_audits OR v_n <> 10 THEN
    RAISE EXCEPTION 'case e: panel and bot must audit the same number of changes (% vs %)', v_n, v_audits; END IF;
  RAISE NOTICE 'PASS e: panel and bot end in the same state across 10 consecutive services; the panel RPC keeps its shape and audit';

  -- ---- f. unknown service: nothing is written ----
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300005', 'cuban_card', 47100, 'ready_to_transfer');
  v_conv := pg_temp.t230_conv(v_op);
  v_before := pg_temp.t230_state(v_op);
  FOREACH v_t IN ARRAY ARRAY['bitcoin', '', '   ', 'zelle; drop table x'] LOOP
    v_r := cerebro_cambiar_servicio(v_conv, v_t, 'exec230-f');
    IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'servicio_desconocido' THEN
      RAISE EXCEPTION 'case f: "%" must be servicio_desconocido, got %', v_t, v_r; END IF;
  END LOOP;
  v_r := cerebro_cambiar_servicio(v_conv, NULL, 'exec230-f');
  IF (v_r ->> 'reason') <> 'servicio_desconocido' THEN RAISE EXCEPTION 'case f: a null service must be servicio_desconocido, got %', v_r; END IF;
  IF pg_temp.t230_state(v_op) <> v_before OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service') THEN
    RAISE EXCEPTION 'case f: nothing may be written'; END IF;
  RAISE NOTICE 'PASS f: unknown, blank and null services answer servicio_desconocido and write nothing';

  -- ---- g. a human fixed it: the service or the quoted amount is admin-locked ----
  FOREACH v_t IN ARRAY ARRAY['delivery_method', 'service_type', 'quoted_destination_amount'] LOOP
    v_op := pg_temp.t230_op(v_user, v_acc, '59902300006', 'cuban_card', 47100, 'ready_to_transfer',
                            jsonb_build_object(v_t, jsonb_build_object('by', gen_random_uuid()::text, 'at', now())));
    v_before := pg_temp.t230_state(v_op);
    v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'zelle', 'exec230-g');
    IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'bloqueado_por_humano' OR (v_r ->> 'campo') <> v_t THEN
      RAISE EXCEPTION 'case g: a human lock on % must answer bloqueado_por_humano, got %', v_t, v_r; END IF;
    IF pg_temp.t230_state(v_op) <> v_before OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service') THEN
      RAISE EXCEPTION 'case g: nothing may be written for a lock on %', v_t; END IF;
  END LOOP;
  -- the panel's own change leaves a human lock on the rail: the bot then hands over
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300007', 'cuban_card', 47100, 'ready_to_transfer');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  PERFORM crm_cambiar_servicio(v_op, 'clasica');
  PERFORM set_config('request.jwt.claims', '', true);
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'zelle', 'exec230-g2');
  IF (v_r ->> 'reason') <> 'bloqueado_por_humano' THEN RAISE EXCEPTION 'case g: a service fixed in the panel must be left to humans, got %', v_r; END IF;
  RAISE NOTICE 'PASS g: a human lock on the rail, the service type or the quote answers bloqueado_por_humano and writes nothing';

  -- ---- h. statuses ----
  FOREACH v_t IN ARRAY ARRAY['transferring', 'incident'] LOOP
    v_op := pg_temp.t230_op(v_user, v_acc, '59902300008', 'cuban_card', 47100, v_t);
    v_before := pg_temp.t230_state(v_op);
    v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'zelle', 'exec230-h');
    IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'estado_no_permite' OR (v_r ->> 'status') <> v_t THEN
      RAISE EXCEPTION 'case h: status % must answer estado_no_permite, got %', v_t, v_r; END IF;
    IF pg_temp.t230_state(v_op) <> v_before OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service') THEN
      RAISE EXCEPTION 'case h: nothing may be written for status %', v_t; END IF;
  END LOOP;
  FOREACH v_t IN ARRAY ARRAY['collecting_information', 'awaiting_deposit', 'deposit_received', 'deposit_verification', 'ready_to_transfer'] LOOP
    v_op := pg_temp.t230_op(v_user, v_acc, '59902300009', 'cuban_card', 47100, v_t);
    v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'clasica', 'exec230-h');
    IF (v_r ->> 'ok') <> 'true' OR (v_r ->> 'changed') <> 'true' OR (v_r ->> 'status') <> v_t
       OR (SELECT status FROM remittance_operations WHERE id = v_op) <> v_t THEN
      RAISE EXCEPTION 'case h: status % must allow the change and keep its status, got %', v_t, v_r; END IF;
  END LOOP;
  -- (231, gap D4.1) a latest operation that is completed / cancelled is "no OPEN operation": the choice of a service for the NEW remittance is
  -- recorded as the agent-declared pending service (remesa rails only), nothing is written to the old operation.
  FOREACH v_t IN ARRAY ARRAY['completed', 'cancelled'] LOOP
    v_op := pg_temp.t230_op(v_user, v_acc, '59902300008', 'cuban_card', 47100, v_t);
    v_before := pg_temp.t230_state(v_op);
    v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'zelle', 'exec230-h');
    IF v_r IS DISTINCT FROM jsonb_build_object('ok', true, 'changed', false, 'pendiente', true, 'servicio', 'zelle') THEN
      RAISE EXCEPTION 'case h: status % must answer pendiente (no open operation), got %', v_t, v_r; END IF;
    IF pg_temp.t230_state(v_op) <> v_before OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service') THEN
      RAISE EXCEPTION 'case h: nothing may be written to the % operation', v_t; END IF;
    IF NOT EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = pg_temp.t230_conv(v_op) AND tipo = 'zelle' AND origen = 'agente') THEN
      RAISE EXCEPTION 'case h: the agent pending row must exist for status %', v_t; END IF;
    v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'recarga', 'exec230-h');
    IF (v_r ->> 'reason') <> 'sin_operacion' OR (v_r ->> 'pendiente') <> 'false' THEN
      RAISE EXCEPTION 'case h: recarga with only a % operation is sin_operacion, got %', v_t, v_r; END IF;
  END LOOP;
  RAISE NOTICE 'PASS h: transferring and incident are refused; completed and cancelled count as no open operation (pending); the five open statuses change and keep their status';

  -- ---- i. below the minimum of the new service ----
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300010', 'cuban_card', 5200);
  v_before := pg_temp.t230_state(v_op);
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'zelle', 'exec230-i1');
  IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'por_debajo_del_minimo'
     OR (v_r ->> 'minimo_gyd')::numeric <> coalesce(nullif(cerebro_config_get('minimo_gyd_usd'), '')::numeric, nullif(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000)
     OR (v_r ->> 'source_amount_gyd')::numeric <> 5200 OR (v_r ->> 'servicio') <> 'zelle' THEN
    RAISE EXCEPTION 'case i1: 5,200 GYD to Zelle must answer por_debajo_del_minimo with the minimum, got %', v_r; END IF;
  IF pg_temp.t230_state(v_op) <> v_before OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service')
     OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'cuban_card' THEN
    RAISE EXCEPTION 'case i1: a refusal below the minimum must write nothing'; END IF;
  v_op2 := pg_temp.t230_op(v_user, v_acc, '59902300011', 'clasica', 20000);
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op2), 'efectivo_usd', 'exec230-i2');
  IF (v_r ->> 'reason') <> 'por_debajo_del_minimo' OR (v_r ->> 'minimo_gyd')::numeric <> cerebro_minimo_efectivo_gyd() THEN
    RAISE EXCEPTION 'case i2: 20,000 GYD to cash USD must answer por_debajo_del_minimo with the cash minimum, got %', v_r; END IF;
  -- exactly at the minimum is enough
  v_op2 := pg_temp.t230_op(v_user, v_acc, '59902300012', 'cuban_card', 13000);
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op2), 'zelle', 'exec230-i3');
  IF (v_r ->> 'ok') <> 'true' THEN RAISE EXCEPTION 'case i3: the exact minimum must be accepted, got %', v_r; END IF;
  RAISE NOTICE 'PASS i: below the new service minimum -> por_debajo_del_minimo with minimo_gyd, nothing written; the exact minimum passes';

  -- ---- j. several recipients with their own amounts cannot move between CUP and USD ----
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300013', 'cuban_card', 60000, 'ready_to_transfer');
  PERFORM pg_temp.t230_ben(v_op, 'cuban_card', v_card, v_ph, 1, 30000, 'CUP');
  PERFORM pg_temp.t230_ben(v_op, 'cuban_card', '9227959879614050', '54363811', 2, 30000, 'CUP');
  v_before := pg_temp.t230_state(v_op);
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'clasica', 'exec230-j');
  IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'varios_destinatarios' OR pg_temp.t230_state(v_op) <> v_before
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service') THEN
    RAISE EXCEPTION 'case j: CUP shares to a USD rail must answer varios_destinatarios and write nothing, got %', v_r; END IF;
  RAISE NOTICE 'PASS j: several CUP shares to a USD rail -> varios_destinatarios, nothing written';

  -- ---- k. resolving the operation ----
  -- k1. none
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902300014', 'test230') RETURNING id INTO v_ben;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ben) RETURNING id INTO v_conv;
  -- (231) a remesa rail with no operation yet is recorded as the agent's pending service (agent-service-change-guards.sql); the other
  -- services keep 230's refusal
  v_r := cerebro_cambiar_servicio(v_conv, 'recarga', 'exec230-k1');
  IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'sin_operacion' THEN RAISE EXCEPTION 'case k1: no operation, got %', v_r; END IF;
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-k1');
  IF (v_r ->> 'ok') <> 'true' OR (v_r ->> 'pendiente') <> 'true' OR (v_r ->> 'changed') <> 'false' THEN RAISE EXCEPTION 'case k1: zelle with no operation is pending since 231, got %', v_r; END IF;
  v_r := cerebro_cambiar_servicio(gen_random_uuid(), 'zelle', 'exec230-k1');
  IF (v_r ->> 'reason') <> 'sin_operacion' THEN RAISE EXCEPTION 'case k1: unknown conversation, got %', v_r; END IF;
  -- k2. two open operations: the same hand-over as the bot's other writers, nothing changed
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300014', 'cuban_card', 47100, 'collecting_information', '{}'::jsonb, 'remesa', v_conv);
  v_op2 := pg_temp.t230_op(v_user, v_acc, '59902300014', 'clasica', 47100, 'collecting_information', '{}'::jsonb, 'remesa', v_conv);
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-k2');
  IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'operacion_ambigua' OR (v_r ->> 'derivado') <> 'true'
     OR (SELECT ai_autoreply_disabled FROM conversations WHERE id = v_conv) IS NOT TRUE
     OR (SELECT count(*) FROM remittance_operations WHERE conversation_id = v_conv AND delivery_method = 'zelle') <> 0 THEN
    RAISE EXCEPTION 'case k2: two open operations must hand over and change nothing, got %', v_r; END IF;
  -- k3. an operation type that is not a remittance-like service
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300015', NULL, 1000, 'collecting_information', '{}'::jsonb, 'traduccion');
  v_r := cerebro_cambiar_servicio(pg_temp.t230_conv(v_op), 'zelle', 'exec230-k3');
  IF (v_r ->> 'reason') <> 'tipo_no_soportado' THEN RAISE EXCEPTION 'case k3: a translation operation, got %', v_r; END IF;
  RAISE NOTICE 'PASS k: no operation, two open operations (hand-over) and a non-remittance type are answered without writing';

  -- ---- l. the panel RPC still refuses what it refused ----
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300016', 'cuban_card', 47100, 'completed');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  -- (383) An owner or an admin may edit a closed operation now; the refusal below is the AGENT's. The role change is rolled back with the rest.
  UPDATE profiles SET account_role = 'agent' WHERE user_id = v_user;
  BEGIN PERFORM crm_cambiar_servicio(v_op, 'clasica'); RAISE EXCEPTION 'case l: a completed operation must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  UPDATE profiles SET account_role = 'owner' WHERE user_id = v_user;
  BEGIN PERFORM crm_cambiar_servicio(v_op, 'bitcoin'); RAISE EXCEPTION 'case l: an unknown service must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  BEGIN PERFORM crm_cambiar_servicio(pg_temp.t230_op(v_user, v_acc, '59902300017', 'cuban_card', 47100), 'clasica'); RAISE EXCEPTION 'case l: a non-member must be refused';
  EXCEPTION WHEN SQLSTATE '42501' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true);
  RAISE NOTICE 'PASS l: crm_cambiar_servicio keeps its refusals (closed, unknown service, non-member)';

  -- ---- m. privileges: the bot role can, nobody else; the core is internal ----
  IF NOT has_function_privilege('service_role', 'public.cerebro_cambiar_servicio(uuid, text, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_cambiar_servicio(uuid, text, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_cambiar_servicio(uuid, text, text)', 'EXECUTE')
     OR has_function_privilege('public', 'public.cerebro_cambiar_servicio(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case m: cerebro_cambiar_servicio must be executable by service_role only'; END IF;
  IF has_function_privilege('service_role', 'public._cambiar_servicio_core(uuid, text, text, text, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public._cambiar_servicio_core(uuid, text, text, text, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._cambiar_servicio_core(uuid, text, text, text, text)', 'EXECUTE')
     OR has_function_privilege('public', 'public._cambiar_servicio_core(uuid, text, text, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case m: the internal core must not be callable by API roles'; END IF;
  IF NOT has_function_privilege('authenticated', 'public.crm_cambiar_servicio(uuid, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crm_cambiar_servicio(uuid, text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.crm_cambiar_servicio(uuid, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case m: crm_cambiar_servicio keeps its grants (authenticated and service_role, not anon)'; END IF;
  -- really calling it as each role
  v_op := pg_temp.t230_op(v_user, v_acc, '59902300018', 'cuban_card', 47100, 'ready_to_transfer');
  v_conv := pg_temp.t230_conv(v_op);
  SET LOCAL ROLE anon;
  BEGIN PERFORM cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-m'); RESET ROLE; RAISE EXCEPTION 'case m: anon must not call it';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-m'); RESET ROLE; RAISE EXCEPTION 'case m: authenticated must not call it';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
  SET LOCAL ROLE service_role;
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec230-m');
  RESET ROLE;
  IF (v_r ->> 'ok') <> 'true' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'zelle' THEN
    RAISE EXCEPTION 'case m: service_role must be able to change the service, got %', v_r; END IF;
  IF coalesce(current_setting('wacrm.origin', true), '') <> '' OR coalesce(current_setting('wacrm.actor', true), '') <> '' THEN
    RAISE EXCEPTION 'case m: the admin origin / actor context must not leak out of the call (% / %)', current_setting('wacrm.origin', true), current_setting('wacrm.actor', true); END IF;
  RAISE NOTICE 'PASS m: service_role calls it; anon, authenticated and PUBLIC cannot; the core is internal; no context leaks';

  RAISE NOTICE 'ALL PASS (bot-change-service)';
END $$;

ROLLBACK;
