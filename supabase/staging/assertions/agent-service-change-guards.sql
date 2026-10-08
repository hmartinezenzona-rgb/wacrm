\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 231 (the agent changes the service with a tool; the database only guards it).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so
-- nothing is kept). Run it wrapped (BEGIN; <this file without its own BEGIN;/ROLLBACK;/\set lines>; ROLLBACK;): a plain `psql -1` can
-- COMMIT a fixture. Each passing case NOTICEs.
-- Owner decision 2026-10-08: the customer's words never decide a Zelle (or cash) switch ("mi hermano usa zelle" must not switch the
-- service); the AGENT decides from context and acts with the cambiar_servicio tool (230). 231 adds only the guards around it.
-- Cases: A detector (negation of the card rails, every 157/174 input unchanged, no Zelle/cash from text); B the registrar changes
-- nothing from Zelle sentences and the removed 231-v1 objects are gone; C THE INCIDENT driven by tool calls; D the agent's choice
-- survives when no operation exists yet (pending + creation); E pending edge cases; F stale-write guard of marcar_destino_usd;
-- G the coherence safety net; H second change of mind through the tool; I grants and constraints.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t231_conv(p_user uuid, p_acc uuid) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_conv uuid;
BEGIN
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (p_user, p_acc, '5990231' || lpad((floor(random() * 10000000))::bigint::text, 7, '0'), 'test231') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (p_user, p_acc, v_ct) RETURNING id INTO v_conv;
  RETURN v_conv;
END $f$;

CREATE FUNCTION pg_temp.t231_op(p_conv uuid, p_dm text, p_amount numeric, p_status text DEFAULT 'collecting_information',
                                p_locks jsonb DEFAULT '{}'::jsonb) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_acc uuid; v_op uuid;
BEGIN
  SELECT c.contact_id, c.account_id INTO v_ct, v_acc FROM conversations c WHERE c.id = p_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency,
                                     quoted_source_amount, admin_locked_fields)
  VALUES (v_acc, p_conv, v_ct, 'collecting_information', 'remesa', p_dm, 'GYD', p_amount, p_locks)
  RETURNING id INTO v_op;
  IF p_status <> 'collecting_information' THEN
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = p_status WHERE id = v_op;
    PERFORM set_config('wacrm.origin', '', true);
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t231_ben(p_op uuid, p_type text, p_card text, p_phone text, p_pos integer) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, address, position, block_index, source, status)
  VALUES (p_op, p_type, p_card, p_phone, CASE WHEN p_type = 'efectivo_usd' THEN 'Calle 1, Bayamo' END, p_pos, p_pos, 'notes_parse', 'vigente')
  RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.t231_state(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT concat_ws('|', o.service_type, coalesce(o.delivery_method, '-'), coalesce(o.destination_currency, '-'),
                   coalesce(o.quoted_destination_amount::text, '-'), coalesce(o.quoted_destination_rate::text, '-'),
                   coalesce(o.quoted_destination_origin, '-'), o.status, o.admin_locked_fields::text,
                   (SELECT coalesce(string_agg(b.beneficiary_type || ':' || b.status || ':' || coalesce(b.amount::text, '-'), ',' ORDER BY b.position), '')
                      FROM remittance_beneficiaries b WHERE b.operation_id = o.id),
                   (SELECT count(*) FROM remittance_admin_audit a WHERE a.row_id = o.id))
    FROM remittance_operations o WHERE o.id = p_op;
$f$;

CREATE FUNCTION pg_temp.t231_audits(p_op uuid) RETURNS integer
LANGUAGE sql AS $f$
  SELECT count(*)::integer FROM remittance_admin_audit WHERE row_id = p_op AND action = 'automation_service_change';
$f$;

-- Everything that could reach a customer: messages, outbox rows, queued http calls (notifications are counted apart where alerts are expected).
CREATE FUNCTION pg_temp.t231_customer_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990231%')
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990231%')
       + (SELECT count(*) FROM net.http_request_queue);
$f$;

CREATE FUNCTION pg_temp.t231_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT pg_temp.t231_customer_side() + (SELECT count(*) FROM notifications);
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_efe numeric := crm_tasa_vigente('efectivo');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_ph constant text := '58528291';
  v_zelle_usd numeric; v_zelle_rate numeric; v_efe_usd numeric; v_cup_amt numeric;
  v_conv uuid; v_conv2 uuid; v_op uuid; v_op2 uuid; v_ben uuid;
  v_r jsonb; v_r2 jsonb; v_o remittance_operations%ROWTYPE; v_before text; v_side bigint; v_text text; v_exp text; v_got text;
  v_pairs text[][];
  v_i int; v_n int; v_alert uuid; v_members int;
BEGIN
  IF NOT (v_usd > 0 AND v_efe > 0 AND v_cup > 0) THEN RAISE EXCEPTION 'setup: the rates are needed (usd %, efectivo %, cup %)', v_usd, v_efe, v_cup; END IF;
  SELECT z.usd, z.tasa INTO v_zelle_usd, v_zelle_rate FROM cerebro_zelle_cotizar_gyd(47100) z;
  v_efe_usd := floor(47100 / v_efe);
  v_cup_amt := round(47100 * v_cup);
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT count(*) INTO v_members FROM profiles p WHERE p.account_id = v_acc AND EXISTS (SELECT 1 FROM auth.users au WHERE au.id = p.user_id);

  -- ---- A. the detector: no Zelle, no cash; a rejected card rail is not a named rail; every 157 / 174 input unchanged ----
  -- 'NULL' stands for SQL NULL.
  v_pairs := ARRAY[
    -- Zelle and cash words never decide anything from text (owner decision 2026-10-08)
    ['Mejor zelle', 'NULL'], ['Quiero zelle', 'NULL'], ['mi hermano usa zelle', 'NULL'], ['Ahora envío cuenta zelle', 'NULL'], ['zelle', 'NULL'],
    ['No quiero efectivo en cuba', 'NULL'], ['mejor en efectivo', 'NULL'], ['Voy a mandar 47100 GYD', 'NULL'], ['Puede ser en USD en Bayamo, granma?', 'NULL'],
    ['Ahora paso la cuenta', 'NULL'], ['zelle o clasica?', 'clasica'], ['mejor zelle, no clasica', 'NULL'], ['mi hermano usa clasica', 'clasica'],
    -- negation of the rails the detector already had: a rejected rail is not a named rail
    ['no quiero clasica', 'NULL'], ['No quiero clásica', 'NULL'], ['sin tropical', 'NULL'], ['no quiero cup', 'NULL'], ['clasica no', 'NULL'],
    ['ni clasica ni tropical', 'NULL'], ['en vez de clasica', 'NULL'], ['ya no en CUP', 'NULL'], ['no tropical', 'NULL'],
    ['no quiero clasica, mejor tropical', 'tropical'], ['no quiero clasica, quiero tropical', 'tropical'], ['no es clasica, es tropical', 'tropical'],
    ['en vez de clasica quiero tropical', 'tropical'], ['no quiero tropical, mejor clasica', 'clasica'], ['ya no cup, clasica', 'clasica'],
    ['no quiero cup, mejor clasica', 'clasica'], ['tropical, no clasica', 'tropical'], ['prefiero tropical no clasica', 'tropical'],
    ['no quiero clasica, mejor en CUP', 'cuban_card'], ['clasica, no cup', 'clasica'],
    ['no se si clasica o tropical', 'NULL'], ['no quiero clasica o tropical', 'NULL'],
    -- 157 / 174 / reparto inputs that must keep their result
    ['Es para recibir Clásica en Cuba', 'clasica'], ['tropical', 'tropical'], ['clasica o tropical', 'NULL'], ['en CUP', 'cuban_card'],
    ['hola', 'NULL'], ['clasicamente', 'NULL'], ['QUIERO QUE SEA CLÁSICA', 'clasica'], ['son pesos cubanos, no dolares', 'cuban_card'],
    ['que es mejor, Tropical o clasica?', 'NULL'], ['Lo otro a unas tarjetas clásicas', 'clasica'], ['a las tropicales', 'tropical'],
    ['esa tarjeta clásica', 'clasica'], ['clasica', 'clasica'], ['Clasica', 'clasica'], ['CLASICA', 'clasica'], ['tropico', 'NULL'], ['tarjeta', 'NULL'],
    ['quiero tropical y en CUP', 'tropical'], ['cuánto es por clásica?', 'clasica'], ['pesos cubanos', 'cuban_card'], ['cupones', 'NULL'], ['', 'NULL'],
    ['quiero clasica, no tengo tropical', 'clasica'], ['cuanto es por tropical?', 'tropical'], ['clasica por favor', 'clasica']
  ];
  FOR v_i IN 1..array_length(v_pairs, 1) LOOP
    v_text := v_pairs[v_i][1]; v_exp := v_pairs[v_i][2];
    v_got := coalesce(cerebro_detectar_destino(v_text), 'NULL');
    IF v_got <> v_exp THEN RAISE EXCEPTION 'case A: cerebro_detectar_destino(%) = %, expected %', quote_literal(v_text), v_got, v_exp; END IF;
  END LOOP;
  IF cerebro_detectar_destino(NULL) IS NOT NULL THEN RAISE EXCEPTION 'case A: NULL text must give NULL'; END IF;
  IF NOT (SELECT provolatile = 'i' FROM pg_proc WHERE proname = 'cerebro_detectar_destino') THEN RAISE EXCEPTION 'case A: the detector must stay IMMUTABLE'; END IF;
  RAISE NOTICE 'PASS A: % detector inputs (no Zelle / cash from text, negation of clasica / tropical / cup, 157 inputs unchanged); still IMMUTABLE', array_length(v_pairs, 1);

  -- ---- B. the registrar changes nothing from Zelle sentences; the removed 231-v1 objects are gone ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  v_ben := pg_temp.t231_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  v_before := pg_temp.t231_state(v_op);
  v_side := pg_temp.t231_side();
  FOREACH v_text IN ARRAY ARRAY['mejor zelle', 'quiero zelle', 'mi hermano usa zelle', 'Ahora envío cuenta zelle', 'no quiero efectivo en cuba', 'mejor clasica'] LOOP
    v_got := cerebro_registrar_destino(v_conv, v_text);
    IF v_got IS NOT NULL AND v_text NOT LIKE '%clasica' THEN
      RAISE EXCEPTION 'case B: % must not be detected, got %', v_text, v_got; END IF;
    IF pg_temp.t231_state(v_op) <> v_before THEN RAISE EXCEPTION 'case B: % changed a cash operation', v_text; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv AND tipo = 'zelle') THEN RAISE EXCEPTION 'case B: no zelle may be recorded from text'; END IF;
  IF pg_temp.t231_side() <> v_side THEN RAISE EXCEPTION 'case B: nothing may be sent'; END IF;
  -- 157 still works for the card rails (re-types a CUP card operation)
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := pg_temp.t231_op(v_conv2, 'cuban_card', 47100);
  PERFORM pg_temp.t231_ben(v_op2, 'cuban_card', '9760039001240356', v_ph, 1);
  v_got := cerebro_registrar_destino(v_conv2, 'mejor tropical');
  IF v_got IS DISTINCT FROM 'tropical' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) <> 'tropical' THEN
    RAISE EXCEPTION 'case B: 157''s card re-typing must still work'; END IF;
  -- a rejected rail does not retype the card (the misfire that motivated the negation)
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := pg_temp.t231_op(v_conv2, 'cuban_card', 47100);
  PERFORM pg_temp.t231_ben(v_op2, 'cuban_card', '9760039001240356', v_ph, 1);
  v_got := cerebro_registrar_destino(v_conv2, 'no quiero clasica');
  IF v_got IS NOT NULL OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) <> 'cuban_card'
     OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2) THEN
    RAISE EXCEPTION 'case B: "no quiero clasica" must not retype a CUP operation nor record clasica'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('cerebro_registrar_destino_v2', 'cerebro_destino_es_pregunta', 'cerebro_destino_pendiente_op_creada'))
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_zz_destino_zelle_al_crear') THEN
    RAISE EXCEPTION 'case B: the keyword-fed 231 objects (v2, question helper, creation trigger) must not exist'; END IF;
  RAISE NOTICE 'PASS B: zelle sentences change and record nothing; 157 card re-typing works; "no quiero clasica" does not retype; v2 / question helper / keyword trigger gone';

  -- ---- C. THE INCIDENT at database level, driven by tool calls ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  PERFORM * FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-c1');         -- the LLM marks cash
  v_ben := pg_temp.t231_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;      -- deposit verified
  PERFORM set_config('wacrm.origin', '', true);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.delivery_method <> 'efectivo_usd' OR v_o.quoted_destination_amount <> v_efe_usd OR v_o.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case C setup: cash % USD in ready_to_transfer expected, got % % %', v_efe_usd, v_o.delivery_method, v_o.quoted_destination_amount, v_o.status; END IF;
  v_before := pg_temp.t231_state(v_op);
  -- the customer's sentence changes nothing by itself
  v_got := cerebro_registrar_destino(v_conv, 'Mejor zelle');
  IF v_got IS NOT NULL OR pg_temp.t231_state(v_op) <> v_before THEN RAISE EXCEPTION 'case C: "Mejor zelle" must not change anything by itself'; END IF;
  v_side := pg_temp.t231_customer_side();
  -- the AGENT understood the context and acts with the tool
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-c2');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'ok') <> 'true' OR (v_r ->> 'changed') <> 'true' OR (v_r ->> 'servicio') <> 'zelle' OR (v_r ->> 'destination_amount')::numeric <> v_zelle_usd
     OR (v_r ->> 'rate')::numeric <> v_zelle_rate OR (v_r #>> '{previous,servicio}') <> 'efectivo_usd' OR (v_r ->> 'status') <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case C: the tool must report the change, got %', v_r; END IF;
  IF v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd OR v_o.destination_currency <> 'USD' OR v_o.status <> 'ready_to_transfer'
     OR (v_usd = 260 AND v_zelle_usd <> 181) THEN
    RAISE EXCEPTION 'case C: zelle / % USD (181 at 260) / ready_to_transfer expected, got % / % / %', v_zelle_usd, v_o.delivery_method, v_o.quoted_destination_amount, v_o.status; END IF;
  IF pg_temp.t231_audits(v_op) <> 1 OR NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_service_change' AND reason LIKE '%exec231-c2%') THEN
    RAISE EXCEPTION 'case C: one automation_service_change audit row carrying the execution is expected'; END IF;
  IF (SELECT status FROM remittance_beneficiaries WHERE id = v_ben) <> 'reemplazado' THEN RAISE EXCEPTION 'case C: the cash recipient must be retired'; END IF;
  IF pg_temp.t231_customer_side() <> v_side THEN RAISE EXCEPTION 'case C: no message row, outbox row or http call may be produced'; END IF;
  -- the late receipt-turn tool call with the old rail is refused, names the current choice and writes NOTHING (not even 230's suppressed-write audit)
  v_before := pg_temp.t231_state(v_op);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'Efectivo', 'exec231-c3');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' OR pg_temp.t231_state(v_op) <> v_before THEN
    RAISE EXCEPTION 'case C: the late efectivo tool call must be refused naming Zelle and write nothing, got % (state changed: %)', v_text, pg_temp.t231_state(v_op) <> v_before; END IF;
  IF NOT EXISTS (SELECT 1 FROM tool_execution_log WHERE execution_id = 'exec231-c3' AND tool_name = 'marcar_destino_usd' AND outcome = 'rechazado') THEN
    RAISE EXCEPTION 'case C: the refused call must be logged with outcome rechazado'; END IF;
  -- the same rail again is not an error
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec231-c4');
  IF v_text NOT LIKE 'ERROR:%' THEN RAISE EXCEPTION 'case C: clasica over a zelle operation locked by the tool is refused too, got %', v_text; END IF;
  -- other sentences of the customer change nothing
  FOREACH v_text IN ARRAY ARRAY['Ahora paso la cuenta', 'Ahora envío cuenta zelle', 'No quiero efectivo en cuba', 'Quiero zelle', 'mi hermano usa zelle'] LOOP
    PERFORM cerebro_registrar_destino(v_conv, v_text);
    IF pg_temp.t231_state(v_op) <> v_before THEN RAISE EXCEPTION 'case C: % changed the operation', v_text; END IF;
  END LOOP;
  RAISE NOTICE 'PASS C: efectivo marked, deposit verified, agent calls cambiar_servicio(zelle) -> zelle, % USD at %, ready_to_transfer, audit row, nothing sent; late marcar(efectivo) refused naming Zelle, nothing written', v_zelle_usd, v_zelle_rate;

  -- ---- D. the agent's choice survives when no operation exists yet ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_side := pg_temp.t231_side();
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-d1');
  IF v_r IS DISTINCT FROM jsonb_build_object('ok', true, 'changed', false, 'pendiente', true, 'servicio', 'zelle') THEN
    RAISE EXCEPTION 'case D: with no operation the tool returns {ok,changed:false,pendiente:true,servicio}, got %', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv AND tipo = 'zelle' AND origen = 'agente' AND actualizado > now() - interval '1 minute') THEN
    RAISE EXCEPTION 'case D: the agent-declared service must be recorded as pending (origen agente)'; END IF;
  IF NOT EXISTS (SELECT 1 FROM tool_execution_log WHERE execution_id = 'exec231-d1' AND tool_name = 'cambiar_servicio' AND outcome = 'pendiente') THEN
    RAISE EXCEPTION 'case D: the call is logged with outcome pendiente'; END IF;
  IF pg_temp.t231_side() <> v_side THEN RAISE EXCEPTION 'case D: recording a pending service sends nothing'; END IF;
  -- a late tool call within the window is refused BEFORE it can create an operation as cash
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-d2');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' OR EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = v_conv) THEN
    RAISE EXCEPTION 'case D: marcar(efectivo) right after the agent declared zelle is refused, creates nothing, names Zelle, got %', v_text; END IF;
  -- the receipt path creates the operation (no rail) -> it is zelle with the quote and ONE audit row; the pending row is consumed
  v_op := cerebro_crear_operacion(v_conv, 47100, 'GYD');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd OR v_o.destination_currency <> 'USD' OR pg_temp.t231_audits(v_op) <> 1 THEN
    RAISE EXCEPTION 'case D: the new operation must be zelle with the Zelle quote and one audit row, got % / % / %', v_o.delivery_method, v_o.quoted_destination_amount, pg_temp.t231_audits(v_op); END IF;
  IF EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) THEN RAISE EXCEPTION 'case D: the pending row must be consumed'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_service_change' AND actor = 'automation:cerebro_cambiar_servicio') THEN
    RAISE EXCEPTION 'case D: the audit row is the same one the tool and the panel path write'; END IF;
  -- a late marcar(efectivo) afterwards (operation exists, locked by the automation) is refused too
  v_before := pg_temp.t231_state(v_op);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-d3');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' OR pg_temp.t231_state(v_op) <> v_before THEN
    RAISE EXCEPTION 'case D: late marcar(efectivo) on the zelle operation is refused, got %', v_text; END IF;
  -- THE RECEIPT PATH AS IT RAN IN PRODUCTION: the tool itself creates the operation as cash, the pending row is older than the 5-minute window
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  PERFORM cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-d4');
  UPDATE cerebro_destino_pendiente SET actualizado = now() - interval '10 minutes' WHERE conversation_id = v_conv;
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-d5');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  IF v_op IS NULL THEN RAISE EXCEPTION 'case D: outside the window the tool creates the operation'; END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.delivery_method <> 'zelle' OR pg_temp.t231_audits(v_op) <> 1 THEN
    RAISE EXCEPTION 'case D: created by the tool as cash but the agent declared zelle: it must end zelle with one audit row, got % / %', v_o.delivery_method, pg_temp.t231_audits(v_op); END IF;
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' THEN
    RAISE EXCEPTION 'case D: the tool must not claim it marked cash when the operation is zelle, got %', v_text; END IF;
  RAISE NOTICE 'PASS D: pending recorded; late marcar refused before creating; operation created later is zelle (audit, quote), pending consumed; tool-created-as-cash outside the window still ends zelle and says so';

  -- ---- E. pending edge cases ----
  -- non-remesa services have no pending: a clear refusal
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  FOREACH v_text IN ARRAY ARRAY['recarga', 'combo', 'visa', 'saldo'] LOOP
    v_r := cerebro_cambiar_servicio(v_conv, v_text, 'exec231-e1');
    IF (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'sin_operacion' OR (v_r ->> 'pendiente') <> 'false'
       OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) THEN
      RAISE EXCEPTION 'case E: % with no operation is refused sin_operacion with pendiente:false and nothing recorded, got %', v_text, v_r; END IF;
  END LOOP;
  v_r := cerebro_cambiar_servicio(gen_random_uuid(), 'zelle', 'exec231-e1b');
  IF (v_r ->> 'reason') <> 'sin_operacion' OR (v_r ->> 'pendiente') <> 'false' THEN RAISE EXCEPTION 'case E: an unknown conversation records nothing, got %', v_r; END IF;
  v_r := cerebro_cambiar_servicio(v_conv, 'zzz', 'exec231-e2');
  IF (v_r ->> 'reason') <> 'servicio_desconocido' THEN RAISE EXCEPTION 'case E: unknown service keeps its reason, got %', v_r; END IF;
  -- the five rails are accepted; the last declaration wins; efectivo alias
  FOREACH v_text IN ARRAY ARRAY['clasica', 'tropical', 'cup', 'efectivo', 'zelle'] LOOP
    v_r := cerebro_cambiar_servicio(v_conv, v_text, 'exec231-e3');
    IF (v_r ->> 'pendiente') <> 'true' THEN RAISE EXCEPTION 'case E: % must be accepted as pending, got %', v_text, v_r; END IF;
  END LOOP;
  IF (SELECT tipo FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) <> 'zelle' THEN RAISE EXCEPTION 'case E: the last declaration wins'; END IF;
  -- the customer's own words about a card rail overwrite the pending row and its label (157 stays the customer's mechanism)
  PERFORM cerebro_registrar_destino(v_conv, 'mejor tropical');
  IF NOT EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv AND tipo = 'tropical' AND origen = 'cliente') THEN
    RAISE EXCEPTION 'case E: a card rail said by the customer rewrites the pending row as origen cliente'; END IF;
  -- older than 24 h: not applied to a new operation
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv2, 'zelle', now() - interval '25 hours', 'agente');
  v_op2 := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) IS NOT NULL THEN RAISE EXCEPTION 'case E: a pending service older than 24 h must not type a new operation'; END IF;
  -- a pending row written by the customer's words (origen cliente) is never applied by the creation path
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  PERFORM cerebro_registrar_destino(v_conv2, 'clasica');
  v_op2 := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) IS NOT NULL THEN RAISE EXCEPTION 'case E: only an agent-declared pending is applied at creation'; END IF;
  -- two open remesas: nothing applied, the row stays
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  PERFORM cerebro_cambiar_servicio(v_conv2, 'zelle', 'exec231-e4');
  v_op := pg_temp.t231_op(v_conv2, 'efectivo_usd', 30000);
  v_op2 := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) IS NOT NULL OR pg_temp.t231_audits(v_op2) <> 0 THEN
    RAISE EXCEPTION 'case E: with two open remesas the pending service is not applied to either'; END IF;
  -- an operation created with its own rail is respected
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  PERFORM cerebro_cambiar_servicio(v_conv2, 'zelle', 'exec231-e5');
  v_op2 := pg_temp.t231_op(v_conv2, 'efectivo_usd', 47100);
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) <> 'efectivo_usd' THEN RAISE EXCEPTION 'case E: an operation inserted with its own rail keeps it'; END IF;
  -- a failed application keeps the row (it is not consumed on a refusal): below the Zelle minimum is checked by the tool, not at creation
  -- an existing operation: the tool works as in 230 and leaves no pending row behind
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := pg_temp.t231_op(v_conv2, 'efectivo_usd', 47100, 'ready_to_transfer');
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv2, 'clasica', now(), 'agente');
  v_r := cerebro_cambiar_servicio(v_conv2, 'zelle', 'exec231-e6');
  IF (v_r ->> 'changed') <> 'true' OR (v_r ? 'pendiente') AND (v_r ->> 'pendiente') = 'true' OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2) THEN
    RAISE EXCEPTION 'case E: with an operation the change applies and no agent pending row is left, got %', v_r; END IF;
  -- estado_no_permite stays for an open operation whose state forbids the change (transferring)
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := pg_temp.t231_op(v_conv2, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'transferring' WHERE id = v_op2;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := cerebro_cambiar_servicio(v_conv2, 'zelle', 'exec231-e7');
  IF (v_r ->> 'reason') <> 'estado_no_permite' OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2) THEN RAISE EXCEPTION 'case E: transferring stays estado_no_permite, got %', v_r; END IF;
  -- (gap D4.1) a repeat customer: the latest operation is completed / cancelled, the customer picks a service for the NEW remittance before it
  -- exists -> pending (not estado_no_permite), and the operation created next takes it
  FOREACH v_text IN ARRAY ARRAY['completed', 'cancelled'] LOOP
    v_conv2 := pg_temp.t231_conv(v_user, v_acc);
    v_op2 := pg_temp.t231_op(v_conv2, 'efectivo_usd', 47100, 'ready_to_transfer');
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = v_text WHERE id = v_op2;
    PERFORM set_config('wacrm.origin', '', true);
    v_r := cerebro_cambiar_servicio(v_conv2, 'zelle', 'exec231-e8');
    IF v_r IS DISTINCT FROM jsonb_build_object('ok', true, 'changed', false, 'pendiente', true, 'servicio', 'zelle')
       OR NOT EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2 AND tipo = 'zelle' AND origen = 'agente') THEN
      RAISE EXCEPTION 'case E: with only a % operation the choice is pending, got %', v_text, v_r; END IF;
    v_op := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
    SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
    IF v_op = v_op2 OR v_o.delivery_method IS DISTINCT FROM 'zelle' OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2)
       OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) <> 'efectivo_usd' THEN
      RAISE EXCEPTION 'case E: the new remittance after a % one is born zelle, the old one is untouched, the row consumed', v_text; END IF;
  END LOOP;
  -- the table accepts exactly the five rails
  BEGIN
    INSERT INTO cerebro_destino_pendiente (conversation_id, tipo) VALUES (v_conv2, 'recarga');
    RAISE EXCEPTION 'case E: recarga must be refused by the table';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS E: recarga/combo/visa/saldo -> sin_operacion (pendiente:false); five rails pending, last wins; customer card words relabel; 24 h / cliente-origin / two ops / own-rail leave the operation alone; existing op leaves no row';

  -- ---- F. stale-write guard of the LLM tool ----
  -- (1) a fresh agent-declared service that differs
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv, 'zelle', now(), 'agente');
  v_before := pg_temp.t231_state(v_op);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'tropical', 'exec231-f1');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' OR pg_temp.t231_state(v_op) <> v_before THEN RAISE EXCEPTION 'case F1: refused naming Zelle, nothing written, got %', v_text; END IF;
  -- the same rail the agent declared passes; so does one older than the window; so does a row written by the customer's words
  DELETE FROM cerebro_destino_pendiente WHERE conversation_id = v_conv;
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv, 'efectivo_usd', now(), 'agente');
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-f2');
  IF v_text LIKE 'ERROR:%' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd' THEN RAISE EXCEPTION 'case F2: marking the rail the agent declared is fine, got %', v_text; END IF;
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv, 'zelle', now() - interval '10 minutes', 'agente');
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-f3');
  IF v_text LIKE 'ERROR:%' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd' THEN RAISE EXCEPTION 'case F3: an agent declaration older than 5 minutes no longer blocks, got %', v_text; END IF;
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  PERFORM cerebro_registrar_destino(v_conv, 'clasica');
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-f4');
  IF v_text LIKE 'ERROR:%' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd' THEN RAISE EXCEPTION 'case F4: 221 behaviour kept (a customer-word pending row does not block the tool), got %', v_text; END IF;
  -- (2) the rail was set by the tool: refused with the message naming the current choice; the same rail passes; a human lock is not this guard's business
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM cerebro_cambiar_servicio(v_conv, 'tropical', 'exec231-f5');
  v_before := pg_temp.t231_state(v_op);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-f6');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%tropical%' OR pg_temp.t231_state(v_op) <> v_before THEN RAISE EXCEPTION 'case F5: refused naming Tropical, nothing written (no suppressed-write audit), got %', v_text; END IF;
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'tropical', 'exec231-f7');
  IF v_text LIKE 'ERROR:%' OR v_text NOT ILIKE 'sin cambios%' THEN RAISE EXCEPTION 'case F6: the rail the tool set is "sin cambios", got %', v_text; END IF;
  -- unchanged outside the guard: invalid type message, and a plain operation without any lock is marked as in 221
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'zzz', 'exec231-f8');
  IF v_text NOT LIKE 'ERROR: el tipo debe ser clasica, tropical o efectivo%' THEN RAISE EXCEPTION 'case F: invalid-type message unchanged, got %', v_text; END IF;
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec231-f9');
  IF v_text <> 'destino marcado: entrega en USD por Clasica' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'clasica' THEN RAISE EXCEPTION 'case F: 221 happy path unchanged, got %', v_text; END IF;
  IF NOT EXISTS (SELECT 1 FROM tool_execution_log WHERE execution_id = 'exec231-f9' AND tool_name = 'marcar_destino_usd' AND outcome = 'marcado') THEN RAISE EXCEPTION 'case F: success logged as marcado'; END IF;
  RAISE NOTICE 'PASS F: marcar_destino_usd refuses a rail different from a fresh agent declaration (<5 min) and from the one the tool set; same rail / old / customer-word rows / happy path unchanged; outcomes logged';

  -- ---- G. the safety net: cerebro_verificar_coherencia_servicio ----
  -- G1: quoted Zelle, operation cash, no change call -> ONE alert for the team, nothing for the customer
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g1', 47100);
  IF NOT EXISTS (SELECT 1 FROM tool_execution_log WHERE execution_id = 'exec231-g1' AND tool_name = 'calcular_usd_desde_gyd' AND outcome = 'zelle') THEN
    RAISE EXCEPTION 'case G: the quote tool call must be logged with its via'; END IF;
  IF (SELECT destino_monto FROM cerebro_ultima_cotizacion WHERE conversation_id = v_conv AND destino_moneda = 'USD') <> v_zelle_usd THEN RAISE EXCEPTION 'case G: the last quote keeps being recorded'; END IF;
  v_side := pg_temp.t231_customer_side();
  v_n := (SELECT count(*) FROM notifications);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g1');
  IF (v_r ->> 'coherente') <> 'false' OR (v_r ->> 'cotizado') <> 'zelle' OR (v_r ->> 'operacion') <> 'efectivo_usd' OR (v_r ->> 'alert_id') IS NULL THEN
    RAISE EXCEPTION 'case G1: quoted zelle, operation cash -> {coherente:false, cotizado, operacion, alert_id}, got %', v_r; END IF;
  v_alert := (v_r ->> 'alert_id')::uuid;
  IF (SELECT count(*) FROM notifications WHERE type = 'coherencia_servicio' AND conversation_id = v_conv) <> v_members OR (SELECT count(*) FROM notifications) - v_n <> v_members THEN
    RAISE EXCEPTION 'case G1: exactly one notification per team member (%), got %', v_members, (SELECT count(*) FROM notifications WHERE type = 'coherencia_servicio' AND conversation_id = v_conv); END IF;
  IF EXISTS (SELECT 1 FROM notifications WHERE conversation_id = v_conv AND (title NOT ILIKE '%Zelle%' OR body NOT ILIKE '%Zelle%' OR body NOT ILIKE '%Efectivo%')) THEN RAISE EXCEPTION 'case G1: neutral Spanish text naming both services'; END IF;
  IF pg_temp.t231_customer_side() <> v_side THEN RAISE EXCEPTION 'case G1: the customer receives nothing'; END IF;
  IF pg_temp.t231_state(v_op) LIKE '%zelle%' THEN RAISE EXCEPTION 'case G1: the check changes nothing'; END IF;
  -- G2: no duplicate, same turn again and a later turn quoting the same pair
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g1');
  IF (v_r ->> 'coherente') <> 'false' OR (v_r ->> 'alert_id')::uuid <> v_alert THEN RAISE EXCEPTION 'case G2: same alert on a second call, got %', v_r; END IF;
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g2', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g2');
  IF (v_r ->> 'alert_id')::uuid <> v_alert OR (SELECT count(*) FROM notifications WHERE type = 'coherencia_servicio' AND conversation_id = v_conv) <> v_members
     OR (SELECT count(*) FROM cerebro_alertas_coherencia WHERE conversation_id = v_conv AND resuelta_en IS NULL) <> 1 THEN
    RAISE EXCEPTION 'case G2: at most one open alert per operation and pair of services'; END IF;
  -- G3: the operation becomes zelle (the agent switched it later) -> the next turn resolves the alert (marks it read); the turn itself is coherent
  PERFORM cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-g3');
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g4');
  IF (v_r ->> 'coherente') <> 'true' OR coalesce((v_r ->> 'resueltas')::int, 0) <> 1 THEN RAISE EXCEPTION 'case G3: coherent and the alert resolved, got %', v_r; END IF;
  IF (SELECT resuelta_en FROM cerebro_alertas_coherencia WHERE id = v_alert) IS NULL OR EXISTS (SELECT 1 FROM notifications WHERE conversation_id = v_conv AND type = 'coherencia_servicio' AND read_at IS NULL) THEN
    RAISE EXCEPTION 'case G3: the alert is resolved and its notifications read'; END IF;
  -- G4: an execution that quoted AND changed is coherent (the change is excused even if someone moved the rail afterwards)
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g5', 47100);
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-g5');
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g5');
  IF (v_r ->> 'coherente') <> 'true' THEN RAISE EXCEPTION 'case G4: quoted and changed -> coherent, got %', v_r; END IF;
  PERFORM cerebro_cambiar_servicio(v_conv, 'efectivo', 'exec231-other');
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g5');
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'via_confirmada' THEN RAISE EXCEPTION 'case G4: a successful change to the quoted service in this execution excuses it, got %', v_r; END IF;
  -- G5: a change that was refused does not excuse (human lock): the bot talked as if switched
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'cuban_card', 47100, 'ready_to_transfer',
                          jsonb_build_object('delivery_method', jsonb_build_object('by', gen_random_uuid()::text, 'at', now())));
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g6', 47100);
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-g6');
  IF (v_r ->> 'reason') <> 'bloqueado_por_humano' THEN RAISE EXCEPTION 'case G5 setup: %', v_r; END IF;
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g6');
  IF (v_r ->> 'coherente') <> 'false' OR (v_r ->> 'cotizado') <> 'zelle' OR (v_r ->> 'operacion') <> 'cuban_card' THEN RAISE EXCEPTION 'case G5: a refused change does not excuse the quote, got %', v_r; END IF;
  -- G6: an agent-declared pending row for the quoted service excuses it
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado, origen) VALUES (v_conv, 'zelle', now(), 'agente');
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g7', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g7');
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'via_declarada' THEN RAISE EXCEPTION 'case G6: agent-declared pending excuses, got %', v_r; END IF;
  -- G7: only the LAST quote of the turn counts: [zelle, efectivo] is coherent on a cash operation, [efectivo, zelle] is not
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g8', 47100);
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_efe_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'efectivo', 'exec231-g8', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g8');
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'misma_via' THEN RAISE EXCEPTION 'case G7: last quote equals the rail -> coherent, got %', v_r; END IF;
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_efe_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'efectivo', 'exec231-g9', 47100);
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-g9', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-g9');
  IF (v_r ->> 'coherente') <> 'false' OR (v_r ->> 'cotizado') <> 'zelle' THEN RAISE EXCEPTION 'case G7: last quote differs -> alert, got %', v_r; END IF;
  -- G8: no quote, no execution id, no open operation, two open operations, a non-remesa, a quote with no via -> coherent, no alert
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-h1');
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'sin_operacion' THEN RAISE EXCEPTION 'case G8: no operation, got %', v_r; END IF;
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-h2');
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'sin_cotizacion' THEN RAISE EXCEPTION 'case G8: no quote in the execution, got %', v_r; END IF;
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', NULL, 'exec231-h3', 47100);
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'mexico', 'exec231-h3', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-h3');
  IF (v_r ->> 'coherente') <> 'true' THEN RAISE EXCEPTION 'case G8: a quote with no via, or a via that is not a rail of the operation, is no evidence, got %', v_r; END IF;
  FOREACH v_text IN ARRAY ARRAY['', '   '] LOOP
    v_r := cerebro_verificar_coherencia_servicio(v_conv, v_text);
    IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'sin_ejecucion' THEN RAISE EXCEPTION 'case G8: blank execution id, got %', v_r; END IF;
  END LOOP;
  v_r := cerebro_verificar_coherencia_servicio(v_conv, NULL);
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'sin_ejecucion' THEN RAISE EXCEPTION 'case G8: NULL execution id, got %', v_r; END IF;
  v_op2 := pg_temp.t231_op(v_conv, 'efectivo_usd', 20000);
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-h4', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-h4');
  IF (v_r ->> 'coherente') <> 'true' OR (v_r ->> 'motivo') <> 'operacion_ambigua' THEN RAISE EXCEPTION 'case G8: two open operations -> no alert, got %', v_r; END IF;
  -- G9: the operation closes (or the rail moves to a third one) -> an open alert is resolved, not left behind
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-i1', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-i1');
  v_alert := (v_r ->> 'alert_id')::uuid;
  PERFORM cerebro_cambiar_servicio(v_conv, 'clasica', 'exec231-i2');
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-i3');
  IF (v_r ->> 'coherente') <> 'true' OR (SELECT resuelta_en FROM cerebro_alertas_coherencia WHERE id = v_alert) IS NULL THEN RAISE EXCEPTION 'case G9: a third rail resolves the alert of the old pair, got %', v_r; END IF;
  -- the pair can alert again later (a new open alert, because the old one is resolved)
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_zelle_usd, 'USD', 'calcular_usd_desde_gyd'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_usd_desde_gyd', 'zelle', 'exec231-i4', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-i4');
  IF (v_r ->> 'coherente') <> 'false' OR (v_r ->> 'operacion') <> 'clasica' OR (v_r ->> 'alert_id')::uuid = v_alert THEN RAISE EXCEPTION 'case G9: new pair, new alert, got %', v_r; END IF;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'transferring' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-i5');
  IF (v_r ->> 'coherente') <> 'true' OR coalesce((v_r ->> 'resueltas')::int, 0) <> 1 THEN RAISE EXCEPTION 'case G9: when no operation is open the alert is resolved, got %', v_r; END IF;
  -- the CUP quote by the CUP tool counts as via cuban_card
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM cerebro_registrar_cotizacion(v_conv, 47100, v_cup_amt, 'CUP', 'calcular_envio'); PERFORM cerebro_registrar_via_cotizada(v_conv, 'calcular_envio', 'cup', 'exec231-j1', 47100);
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-j1');
  IF (v_r ->> 'coherente') <> 'false' OR (v_r ->> 'cotizado') <> 'cuban_card' THEN RAISE EXCEPTION 'case G: a CUP quote is via cuban_card, got %', v_r; END IF;
  RAISE NOTICE 'PASS G: quote!=rail & no change -> one alert (one notification per member, no duplicate, nothing to the customer); resolved when the rails match / move / close; excused by a successful change or an agent-declared pending; refused change does not excuse; last quote counts; no evidence -> coherent';

  -- ---- H. a second change of mind through the tool: zelle -> cup -> zelle ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM pg_temp.t231_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-k1');
  IF (v_r ->> 'changed') <> 'true' THEN RAISE EXCEPTION 'case H1: %', v_r; END IF;
  v_r := cerebro_cambiar_servicio(v_conv, 'cup', 'exec231-k2');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'cuban_card' OR v_o.destination_currency <> 'CUP' OR v_o.quoted_destination_amount <> v_cup_amt THEN
    RAISE EXCEPTION 'case H2: zelle -> cup, got % / % / %', v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  v_r := cerebro_cambiar_servicio(v_conv, 'zelle', 'exec231-k3');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd OR v_o.destination_currency <> 'USD' OR pg_temp.t231_audits(v_op) <> 3 THEN
    RAISE EXCEPTION 'case H3: cup -> zelle after the automation lock, 3 audits, got % / % / %', v_r, v_o.delivery_method, pg_temp.t231_audits(v_op); END IF;
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-k4');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' THEN RAISE EXCEPTION 'case H4: late efectivo refused after the chain, got %', v_text; END IF;
  RAISE NOTICE 'PASS H: zelle -> cup -> zelle through the tool (3 audits), late efectivo refused';

  -- ---- I. grants and constraints ----
  IF NOT has_function_privilege('service_role', 'public.cerebro_cambiar_servicio(uuid, text, text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_verificar_coherencia_servicio(uuid, text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_registrar_via_cotizada(uuid, text, text, text, numeric)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_registrar_destino(uuid, text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_detectar_destino(text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_marcar_destino_usd(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case I: service_role must execute the bot functions'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname IN ('cerebro_verificar_coherencia_servicio', 'cerebro_cambiar_servicio', 'cerebro_registrar_via_cotizada', 'cerebro_servicio_normalizar', 'cerebro_registrar_destino',
                                  'cerebro_detectar_destino', 'cerebro_marcar_destino_usd', 'cerebro_destino_riel_negado', 'cerebro_destino_riel_afirmado',
                                  'cerebro_destino_agente_al_crear', 'cerebro_destino_pendiente_origen')
                AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE')
                     OR has_function_privilege('public', p.oid, 'EXECUTE'))) THEN
    RAISE EXCEPTION 'case I: anon, authenticated and PUBLIC must not execute any bot function (%)',
      (SELECT string_agg(p.proname, ',') FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
          AND p.proname IN ('cerebro_verificar_coherencia_servicio', 'cerebro_cambiar_servicio', 'cerebro_registrar_via_cotizada', 'cerebro_servicio_normalizar', 'cerebro_registrar_destino',
                            'cerebro_detectar_destino', 'cerebro_marcar_destino_usd', 'cerebro_destino_riel_negado', 'cerebro_destino_riel_afirmado',
                            'cerebro_destino_agente_al_crear', 'cerebro_destino_pendiente_origen')
          AND (has_function_privilege('anon', p.oid, 'EXECUTE') OR has_function_privilege('authenticated', p.oid, 'EXECUTE') OR has_function_privilege('public', p.oid, 'EXECUTE'))); END IF;
  IF has_table_privilege('anon', 'public.cerebro_alertas_coherencia', 'SELECT') OR has_table_privilege('authenticated', 'public.cerebro_alertas_coherencia', 'SELECT') THEN
    RAISE EXCEPTION 'case I: the alert table is not readable by API roles'; END IF;
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  SET LOCAL ROLE anon;
  BEGIN PERFORM cerebro_verificar_coherencia_servicio(v_conv, 'exec231-l'); RESET ROLE; RAISE EXCEPTION 'case I: anon must not call the coherence check';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM cerebro_verificar_coherencia_servicio(v_conv, 'exec231-l'); RESET ROLE; RAISE EXCEPTION 'case I: authenticated must not call the coherence check';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
  SET LOCAL ROLE service_role;
  v_r := cerebro_verificar_coherencia_servicio(v_conv, 'exec231-l');
  RESET ROLE;
  IF (v_r ->> 'coherente') <> 'true' THEN RAISE EXCEPTION 'case I: service_role can call the check, got %', v_r; END IF;
  IF coalesce(current_setting('wacrm.origin', true), '') <> '' OR coalesce(current_setting('wacrm.actor', true), '') <> '' THEN
    RAISE EXCEPTION 'case I: the admin origin / actor context must not leak out of any call'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'notifications_type_check' AND pg_get_constraintdef(oid) LIKE '%coherencia_servicio%'
                    AND pg_get_constraintdef(oid) LIKE '%entrega_efectivo_lista%' AND pg_get_constraintdef(oid) LIKE '%remesa_abierta_vieja%') THEN
    RAISE EXCEPTION 'case I: the notification type list gains coherencia_servicio and keeps the others'; END IF;
  RAISE NOTICE 'PASS I: bot role only (cambiar_servicio, verificar_coherencia, registrar_cotizacion, marcar, registrar, detectar); alert table closed to API roles; type list extended';

  RAISE NOTICE 'ALL PASS (agent-service-change-guards)';
END $$;

ROLLBACK;
