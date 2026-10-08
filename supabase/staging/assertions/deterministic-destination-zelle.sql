\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 231 (the customer's own words also decide Zelle, and change the open operation through 230's engine).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so
-- nothing is kept). Run it wrapped (BEGIN; <this file without its own BEGIN;/ROLLBACK; lines>; ROLLBACK;): a plain `psql -1` can COMMIT a
-- fixture. Each passing case NOTICEs.
-- Production 2026-10-08 (Carlos): "Mejor zelle" after a cash USD quote and a receipt. cerebro_registrar_destino knew clasica / tropical / cup
-- only, so every Zelle sentence returned NULL, and the receipt turn then marked "efectivo" from chat memory. 231 teaches the deterministic
-- mechanism of 157 to read Zelle (with negations and questions), apply it through cerebro_cambiar_servicio (230), and stops the LLM tool from
-- overwriting a rail the customer stated in the last minutes.
-- Cases: A detector table; B incident replay, tool first; C incident replay, "Mejor zelle" first; D negation changes nothing; E zelle -> CUP -> zelle
-- -> clasica -> tropical -> CUP; F zelle stated before the operation exists; G pending zelle + card insert; H locks, statuses, minimum, two
-- operations, questions; I stale-write window; J grants; K v1 wrapper.
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
                      FROM remittance_beneficiaries b WHERE b.operation_id = o.id))
    FROM remittance_operations o WHERE o.id = p_op;
$f$;

CREATE FUNCTION pg_temp.t231_audits(p_op uuid) RETURNS integer
LANGUAGE sql AS $f$
  SELECT count(*)::integer FROM remittance_admin_audit WHERE row_id = p_op AND action = 'automation_service_change';
$f$;

-- Everything that could reach a customer: messages, outbox rows, notifications, queued http calls.
CREATE FUNCTION pg_temp.t231_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990231%')
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990231%')
       + (SELECT count(*) FROM notifications)
       + (SELECT count(*) FROM net.http_request_queue);
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_efe numeric := crm_tasa_vigente('efectivo');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_card constant text := '9760039001240356';
  v_ph constant text := '58528291';
  v_zelle_usd numeric; v_zelle_rate numeric; v_efe_usd numeric; v_cup_amt numeric; v_cla_usd numeric;
  v_conv uuid; v_conv2 uuid; v_op uuid; v_op2 uuid; v_ben uuid;
  v_r jsonb; v_o remittance_operations%ROWTYPE; v_before text; v_side bigint; v_text text; v_exp text; v_got text; v_acc_txt text;
  v_pairs text[][];
  v_i int; v_n int; v_min numeric;
BEGIN
  IF NOT (v_usd > 0 AND v_efe > 0 AND v_cup > 0) THEN RAISE EXCEPTION 'setup: the rates are needed (usd %, efectivo %, cup %)', v_usd, v_efe, v_cup; END IF;
  SELECT z.usd, z.tasa INTO v_zelle_usd, v_zelle_rate FROM cerebro_zelle_cotizar_gyd(47100) z;
  v_efe_usd := floor(47100 / v_efe);
  v_cup_amt := round(47100 * v_cup);
  v_cla_usd := floor(47100 / v_usd);
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- ---- A. the detector table (pure text) ----
  -- 'NULL' stands for SQL NULL. Group 1: every sentence of the incident. Group 2: Zelle statements. Group 3: negations. Group 4: two rails.
  -- Group 5: questions. Group 6: the clasica / tropical / cup inputs of 157 / 174 and the reparto adapters, which must not change.
  v_pairs := ARRAY[
    -- incident
    ['Voy a mandar 47100 GYD', 'NULL'],
    ['Puede ser en USD en Bayamo, granma?', 'NULL'],
    ['Mejor zelle', 'zelle'],
    ['Ahora paso la cuenta', 'NULL'],
    ['Ahora envío cuenta zelle', 'zelle'],
    ['No quiero efectivo en cuba', 'NULL'],
    ['Quiero zelle', 'zelle'],
    -- Zelle as a statement of choice
    ['zelle', 'zelle'], ['Zelle.', 'zelle'], ['ZELLE', 'zelle'], ['mejor por zelle', 'zelle'], ['por zelle', 'zelle'],
    ['que sea zelle', 'zelle'], ['ponlo por zelle', 'zelle'], ['envíalo por zelle', 'zelle'], ['es para zelle', 'zelle'],
    ['Prefiero zelle, gracias', 'zelle'], ['si, zelle', 'zelle'], ['mejor zelles', 'zelle'], ['Ahora envio cuenta zelle: Juan Perez', 'zelle'],
    -- negations: a rail rejected in the turn is not a named rail
    ['no quiero zelle', 'NULL'], ['no zelle', 'NULL'], ['ya no quiero zelle', 'NULL'], ['mejor no zelle', 'NULL'], ['sin zelle', 'NULL'],
    ['no quiero que sea por zelle', 'NULL'], ['en vez de zelle', 'NULL'], ['No tengo zelle', 'NULL'], ['zelle no', 'NULL'],
    ['no quiero zelle, mejor tropical', 'tropical'], ['en vez de zelle, clásica', 'clasica'], ['zelle no, tropical', 'tropical'],
    ['tropical, no zelle', 'tropical'], ['clasica no, zelle', 'zelle'], ['no, mejor zelle', 'zelle'], ['no mejor zelle', 'zelle'],
    ['no quiero efectivo, quiero zelle', 'zelle'], ['No quiero efectivo en Cuba, quiero zelle', 'zelle'],
    ['no quiero clasica, quiero tropical', 'tropical'], ['no clasica', 'NULL'], ['sin tropical', 'NULL'], ['ya no en CUP', 'NULL'],
    ['en lugar de CUP, zelle', 'zelle'],
    -- two different positive rails in one turn
    ['zelle o clasica?', 'NULL'], ['zelle o clasica', 'NULL'], ['zelle o tropical', 'NULL'], ['zelle o cup', 'NULL'], ['clasica o tropical', 'NULL'],
    -- questions that only ask about Zelle
    ['¿tienen zelle?', 'NULL'], ['tienen zelle', 'NULL'], ['cuánto es por zelle?', 'NULL'], ['cuanto seria por zelle', 'NULL'],
    ['se puede por zelle?', 'NULL'], ['se puede por zelle', 'NULL'], ['mejor zelle?', 'NULL'], ['Cómo funciona zelle', 'NULL'],
    ['y si lo mando por zelle, cuanto llega', 'NULL'], ['hay zelle?', 'NULL'], ['aceptan zelle', 'NULL'],
    -- a Zelle address is not a Zelle choice
    ['mi cuenta es juan.zelle@gmail.com', 'NULL'], ['zelle: pepe@zelle.com', 'zelle'],
    -- 157 / 174 / reparto inputs that must keep their result
    ['Es para recibir Clásica en Cuba', 'clasica'], ['tropical', 'tropical'], ['clasica o tropical', 'NULL'], ['en CUP', 'cuban_card'],
    ['hola', 'NULL'], ['clasicamente', 'NULL'], ['QUIERO QUE SEA CLÁSICA', 'clasica'], ['son pesos cubanos, no dolares', 'cuban_card'],
    ['que es mejor, Tropical o clasica?', 'NULL'], ['Lo otro a unas tarjetas clásicas', 'clasica'], ['a las tropicales', 'tropical'],
    ['esa tarjeta clásica', 'clasica'], ['clasica', 'clasica'], ['Clasica', 'clasica'], ['CLASICA', 'clasica'], ['tropico', 'NULL'], ['tarjeta', 'NULL'],
    ['quiero tropical y en CUP', 'tropical'], ['cuánto es por clásica?', 'clasica'], ['pesos cubanos', 'cuban_card'], ['cupones', 'NULL'], ['', 'NULL']
  ];
  FOR v_i IN 1..array_length(v_pairs, 1) LOOP
    v_text := v_pairs[v_i][1]; v_exp := v_pairs[v_i][2];
    v_got := coalesce(cerebro_detectar_destino(v_text), 'NULL');
    IF v_got <> v_exp THEN RAISE EXCEPTION 'case A: cerebro_detectar_destino(%) = %, expected %', quote_literal(v_text), v_got, v_exp; END IF;
  END LOOP;
  IF cerebro_detectar_destino(NULL) IS NOT NULL THEN RAISE EXCEPTION 'case A: NULL text must give NULL'; END IF;
  IF NOT (SELECT provolatile = 'i' FROM pg_proc WHERE proname = 'cerebro_detectar_destino') THEN RAISE EXCEPTION 'case A: the detector must stay IMMUTABLE'; END IF;
  RAISE NOTICE 'PASS A: % detector inputs (incident, Zelle, negations, two rails, questions, 157 inputs unchanged); still IMMUTABLE', array_length(v_pairs, 1);

  -- ---- B. THE INCIDENT, tool first: the LLM marks efectivo, the deposit is verified, then "Mejor zelle" ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Voy a mandar 47100 GYD', 'exec231-b1');
  IF v_r ->> 'tipo' IS NOT NULL OR (v_r ->> 'changed') <> 'false' THEN RAISE EXCEPTION 'case B: turn 1 detects nothing, got %', v_r; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'Puede ser en USD en Bayamo, granma?', 'exec231-b2');
  IF v_r ->> 'tipo' IS NOT NULL THEN RAISE EXCEPTION 'case B: turn 2 detects nothing, got %', v_r; END IF;
  PERFORM * FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-b-tool');
  v_ben := pg_temp.t231_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.delivery_method <> 'efectivo_usd' OR v_o.quoted_destination_amount <> v_efe_usd OR v_o.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case B setup: cash % USD in ready_to_transfer expected, got % % %', v_efe_usd, v_o.delivery_method, v_o.quoted_destination_amount, v_o.status; END IF;
  v_side := pg_temp.t231_side();

  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-b3');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'tipo') <> 'zelle' OR (v_r ->> 'ok') <> 'true' OR (v_r ->> 'changed') <> 'true' OR (v_r ->> 'servicio') <> 'zelle'
     OR (v_r ->> 'operation_id') <> v_op::text OR (v_r ->> 'destination_amount')::numeric <> v_zelle_usd OR (v_r ->> 'destination_currency') <> 'USD'
     OR (v_r ->> 'rate')::numeric <> v_zelle_rate OR (v_r ->> 'source_amount_gyd')::numeric <> 47100 OR (v_r ->> 'status') <> 'ready_to_transfer'
     OR (v_r #>> '{previous,servicio}') <> 'efectivo_usd' OR (v_r #>> '{previous,destination_amount}')::numeric <> v_efe_usd THEN
    RAISE EXCEPTION 'case B: "Mejor zelle" must report the change with the new amount and the previous one, got %', v_r; END IF;
  IF v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd OR v_o.destination_currency <> 'USD' OR v_o.status <> 'ready_to_transfer'
     OR (v_zelle_usd <> 181 AND v_usd = 260) THEN
    RAISE EXCEPTION 'case B: the operation must be zelle / % USD / ready_to_transfer (181 at 260), got % / % / %', v_zelle_usd, v_o.delivery_method, v_o.quoted_destination_amount, v_o.status; END IF;
  IF (SELECT status FROM remittance_beneficiaries WHERE id = v_ben) <> 'reemplazado' THEN RAISE EXCEPTION 'case B: the cash recipient must be retired'; END IF;
  IF pg_temp.t231_audits(v_op) <> 1 OR NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_service_change' AND reason LIKE '%exec231-b3%') THEN
    RAISE EXCEPTION 'case B: one automation_service_change audit row carrying the execution is expected'; END IF;
  IF pg_temp.t231_side() <> v_side THEN RAISE EXCEPTION 'case B: no message, outbox row, notification or http call may be produced'; END IF;
  IF (SELECT tipo FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) <> 'zelle' THEN RAISE EXCEPTION 'case B: the pending destination must now be zelle'; END IF;
  -- the rest of the incident's sentences leave the operation as it is
  v_before := pg_temp.t231_state(v_op);
  FOREACH v_text IN ARRAY ARRAY['Ahora paso la cuenta', 'Ahora envío cuenta zelle', 'No quiero efectivo en cuba', 'Quiero zelle'] LOOP
    v_r := cerebro_registrar_destino_v2(v_conv, v_text, 'exec231-b4');
    IF (v_r ->> 'changed') <> 'false' THEN RAISE EXCEPTION 'case B: % must not change anything (second time), got %', v_text, v_r; END IF;
    IF v_text IN ('Ahora envío cuenta zelle', 'Quiero zelle') AND ((v_r ->> 'tipo') <> 'zelle' OR (v_r ->> 'ok') <> 'true') THEN
      RAISE EXCEPTION 'case B: % is zelle and already zelle, got %', v_text, v_r; END IF;
    IF v_text IN ('Ahora paso la cuenta', 'No quiero efectivo en cuba') AND (v_r ->> 'tipo') IS NOT NULL THEN
      RAISE EXCEPTION 'case B: % names no rail, got %', v_text, v_r; END IF;
    IF pg_temp.t231_state(v_op) <> v_before OR pg_temp.t231_audits(v_op) <> 1 THEN RAISE EXCEPTION 'case B: % changed the operation', v_text; END IF;
  END LOOP;
  -- a LATE tool call with the old rail (the receipt turn) is refused and writes nothing
  v_side := (SELECT count(*) FROM tool_execution_log WHERE conversation_id = v_conv);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'Efectivo', 'exec231-b-late');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' OR pg_temp.t231_state(v_op) <> v_before THEN
    RAISE EXCEPTION 'case B: the late efectivo tool call must be refused naming Zelle, got % ', v_text; END IF;
  RAISE NOTICE 'PASS B: incident replay, tool first -> 181 USD at 260, ready_to_transfer, cash recipient retired, one audit row, nothing sent, later sentences change nothing, late tool refused';

  -- ---- C. THE INCIDENT, "Mejor zelle" first: the tool's efectivo arrives afterwards and is refused ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-c1');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd THEN
    RAISE EXCEPTION 'case C: "Mejor zelle" on a fresh operation must make it zelle with the Zelle quote, got % / % / %', v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  v_before := pg_temp.t231_state(v_op);
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-c-tool');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%zelle%' OR pg_temp.t231_state(v_op) <> v_before OR pg_temp.t231_audits(v_op) <> 1 THEN
    RAISE EXCEPTION 'case C: the tool must refuse efectivo after the customer said zelle (message names Zelle) and write nothing, got %', v_text; END IF;
  -- it does not refuse the very rail the customer stated, and does not refuse an unrelated invalid call differently
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'zzz', 'exec231-c-tool2');
  IF v_text NOT LIKE 'ERROR: el tipo debe ser clasica, tropical o efectivo%' THEN RAISE EXCEPTION 'case C: the invalid-type message is unchanged, got %', v_text; END IF;
  RAISE NOTICE 'PASS C: "Mejor zelle" first -> zelle; the tool''s efectivo is refused with a message naming Zelle and writes nothing';

  -- ---- D. a rejection changes nothing ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM pg_temp.t231_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  v_before := pg_temp.t231_state(v_op);
  v_r := cerebro_registrar_destino_v2(v_conv, 'No quiero efectivo en cuba', 'exec231-d');
  IF v_r ->> 'tipo' IS NOT NULL OR (v_r ->> 'changed') <> 'false' OR pg_temp.t231_state(v_op) <> v_before OR pg_temp.t231_audits(v_op) <> 0
     OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) THEN
    RAISE EXCEPTION 'case D: a rejection must change and record nothing, got %', v_r; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'no quiero zelle', 'exec231-d2');
  IF v_r ->> 'tipo' IS NOT NULL OR pg_temp.t231_state(v_op) <> v_before THEN RAISE EXCEPTION 'case D: "no quiero zelle" must change nothing, got %', v_r; END IF;
  RAISE NOTICE 'PASS D: "No quiero efectivo en cuba" and "no quiero zelle" change and record nothing';

  -- ---- E. a customer who keeps changing their mind: zelle -> CUP -> zelle -> clasica -> tropical -> CUP (the automation lock never blocks the bot) ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  PERFORM pg_temp.t231_ben(v_op, 'efectivo_usd', NULL, v_ph, 1);
  v_r := cerebro_registrar_destino_v2(v_conv, 'mejor zelle', 'exec231-e1');
  IF (v_r ->> 'changed') <> 'true' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'zelle' THEN RAISE EXCEPTION 'case E1: %', v_r; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'mejor en CUP', 'exec231-e2');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR (v_r ->> 'tipo') <> 'cuban_card' OR v_o.delivery_method <> 'cuban_card' OR v_o.destination_currency <> 'CUP'
     OR v_o.quoted_destination_amount <> v_cup_amt OR (v_r ->> 'destination_amount')::numeric <> v_cup_amt OR (v_r #>> '{previous,servicio}') <> 'zelle' THEN
    RAISE EXCEPTION 'case E2: "mejor en CUP" after zelle must give cuban_card with % CUP, got % / % %', v_cup_amt, v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'ahora si, zelle otra vez', 'exec231-e3');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd OR v_o.destination_currency <> 'USD' THEN
    RAISE EXCEPTION 'case E3: the second change of mind (cup -> zelle) must work after the automation lock, got % / % / %', v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'mejor clasica', 'exec231-e4');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'clasica' OR v_o.quoted_destination_amount <> v_cla_usd OR v_o.destination_currency <> 'USD' THEN
    RAISE EXCEPTION 'case E4: zelle -> clasica, got % / % / %', v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'mejor tropical', 'exec231-e5');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'tropical' OR v_o.quoted_destination_amount <> v_cla_usd THEN
    RAISE EXCEPTION 'case E5: clasica -> tropical (a card rail under the automation lock), got % / % / %', v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv, 'mejor en CUP', 'exec231-e6');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF (v_r ->> 'changed') <> 'true' OR v_o.delivery_method <> 'cuban_card' OR v_o.quoted_destination_amount <> v_cup_amt THEN
    RAISE EXCEPTION 'case E6: tropical -> CUP, got % / % / %', v_r, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  IF pg_temp.t231_audits(v_op) <> 6 THEN RAISE EXCEPTION 'case E: six changes, six audit rows, got %', pg_temp.t231_audits(v_op); END IF;
  -- a question about another rail does NOT change a cash / Zelle operation, and records nothing
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := pg_temp.t231_op(v_conv2, 'efectivo_usd', 47100, 'ready_to_transfer');
  v_before := pg_temp.t231_state(v_op2);
  v_r := cerebro_registrar_destino_v2(v_conv2, 'y por clasica cuanto seria?', 'exec231-e7');
  IF (v_r ->> 'changed') <> 'false' OR v_r ->> 'reason' <> 'es_pregunta' OR pg_temp.t231_state(v_op2) <> v_before
     OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv2) THEN
    RAISE EXCEPTION 'case E7: a question about clasica on a cash operation must change and record nothing, got %', v_r; END IF;
  v_r := cerebro_registrar_destino_v2(v_conv2, 'mejor clasica', 'exec231-e8');
  IF (v_r ->> 'changed') <> 'true' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) <> 'clasica' THEN
    RAISE EXCEPTION 'case E8: "mejor clasica" over cash USD must apply (cards apply when the rail is zelle / efectivo_usd), got %', v_r; END IF;
  RAISE NOTICE 'PASS E: zelle -> CUP -> zelle -> clasica -> tropical -> CUP all applied (6 audits); a question about another rail changes nothing; card rails apply over cash';

  -- ---- F. zelle stated before any operation exists, then the operation is created ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-f1');
  IF (v_r ->> 'tipo') <> 'zelle' OR (v_r ->> 'registrado') <> 'true' OR (v_r ->> 'changed') <> 'false' OR (v_r ->> 'reason') <> 'sin_operacion'
     OR (SELECT tipo FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) <> 'zelle' THEN
    RAISE EXCEPTION 'case F: with no operation the destination is only recorded, got %', v_r; END IF;
  v_op := cerebro_crear_operacion(v_conv, 47100, 'GYD');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.delivery_method <> 'zelle' OR v_o.quoted_destination_amount <> v_zelle_usd OR v_o.destination_currency <> 'USD' OR pg_temp.t231_audits(v_op) <> 1 THEN
    RAISE EXCEPTION 'case F: the new operation must be zelle with the Zelle quote and one audit row, got % / % / %', v_o.delivery_method, v_o.quoted_destination_amount, pg_temp.t231_audits(v_op); END IF;
  -- no pending zelle -> a new operation is left alone; an old pending (older than 24 h) too
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) IS NOT NULL THEN RAISE EXCEPTION 'case F: no pending zelle, no rail'; END IF;
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv2, 'zelle', now() - interval '25 hours');
  v_op2 := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) IS NOT NULL THEN RAISE EXCEPTION 'case F: a pending zelle older than 24 h must not type a new operation'; END IF;
  -- a pending clasica is not applied by the creation trigger (157's beneficiary trigger owns it)
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  PERFORM cerebro_registrar_destino_v2(v_conv2, 'clasica', 'exec231-f2');
  v_op2 := cerebro_crear_operacion(v_conv2, 47100, 'GYD');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op2) IS NOT NULL THEN RAISE EXCEPTION 'case F: only a pending zelle types a new operation'; END IF;
  RAISE NOTICE 'PASS F: zelle stated before the operation exists -> the new operation is zelle (quote, audit); no/old/other pending leaves it alone';

  -- ---- G. a pending zelle does not corrupt a card beneficiary insert ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv, 'zelle', now());
  v_ben := pg_temp.t231_ben(v_op, 'cuban_card', v_card, v_ph, 1);
  IF (SELECT beneficiary_type FROM remittance_beneficiaries WHERE id = v_ben) <> 'cuban_card' THEN
    RAISE EXCEPTION 'case G: a card arriving while zelle is pending must stay a card'; END IF;
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op) IS NOT NULL AND (SELECT delivery_method FROM remittance_operations WHERE id = v_op) NOT IN ('cuban_card') THEN
    RAISE EXCEPTION 'case G: the operation must not become zelle from a card insert'; END IF;
  IF (SELECT tipo FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) <> 'zelle' THEN RAISE EXCEPTION 'case G: the trigger leaves the pending row alone (chosen rule)'; END IF;
  -- same with a clasica operation: the pending zelle does not override the operation's own rail
  v_conv2 := pg_temp.t231_conv(v_user, v_acc);
  v_op2 := pg_temp.t231_op(v_conv2, 'clasica', 47100);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv2, 'zelle', now());
  v_ben := pg_temp.t231_ben(v_op2, 'cuban_card', v_card, v_ph, 1);
  IF (SELECT beneficiary_type FROM remittance_beneficiaries WHERE id = v_ben) <> 'clasica' THEN
    RAISE EXCEPTION 'case G: 221''s rule (operation rail clasica) must still type the card, got %', (SELECT beneficiary_type FROM remittance_beneficiaries WHERE id = v_ben); END IF;
  RAISE NOTICE 'PASS G: a card + phone arriving while zelle is pending stays a card (the beneficiary trigger ignores a pending zelle; 221 still works)';

  -- ---- H. refusals: human lock, status, minimum, two operations, questions ----
  -- human lock on the rail
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'cuban_card', 47100, 'ready_to_transfer',
                          jsonb_build_object('delivery_method', jsonb_build_object('by', gen_random_uuid()::text, 'at', now())));
  v_before := pg_temp.t231_state(v_op);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-h1');
  IF (v_r ->> 'changed') <> 'false' OR (v_r ->> 'ok') <> 'false' OR (v_r ->> 'reason') <> 'bloqueado_por_humano' OR pg_temp.t231_state(v_op) <> v_before OR pg_temp.t231_audits(v_op) <> 0 THEN
    RAISE EXCEPTION 'case H1: a human lock must stop the change and say why, got %', v_r; END IF;
  -- human beneficiaries lock
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer',
                          jsonb_build_object('beneficiaries', jsonb_build_object('by', gen_random_uuid()::text, 'at', now())));
  v_before := pg_temp.t231_state(v_op);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-h1b');
  IF (v_r ->> 'changed') <> 'false' OR (v_r ->> 'reason') <> 'bloqueado_por_humano' OR pg_temp.t231_state(v_op) <> v_before THEN
    RAISE EXCEPTION 'case H1b: a human lock on the recipients must stop the change, got %', v_r; END IF;
  -- status transferring and completed
  FOREACH v_text IN ARRAY ARRAY['transferring', 'completed'] LOOP
    v_conv := pg_temp.t231_conv(v_user, v_acc);
    v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
    PERFORM set_config('wacrm.origin', 'admin', true);
    IF v_text = 'completed' THEN
      UPDATE remittance_operations SET status = 'transferring' WHERE id = v_op;
    END IF;
    UPDATE remittance_operations SET status = v_text WHERE id = v_op;
    PERFORM set_config('wacrm.origin', '', true);
    v_before := pg_temp.t231_state(v_op);
    v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-h2');
    IF (v_r ->> 'changed') <> 'false' OR (v_r ->> 'reason') <> 'estado_no_permite' OR (v_r ->> 'status') <> v_text OR pg_temp.t231_state(v_op) <> v_before OR pg_temp.t231_audits(v_op) <> 0 THEN
      RAISE EXCEPTION 'case H2: status % must refuse with estado_no_permite, got %', v_text, v_r; END IF;
  END LOOP;
  -- below the Zelle minimum
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'cuban_card', 5200);
  v_before := pg_temp.t231_state(v_op);
  v_min := coalesce(nullif(cerebro_config_get('minimo_gyd_usd'), '')::numeric, nullif(cerebro_config_get('zelle_minimo_gyd'), '')::numeric, 13000);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-h3');
  IF (v_r ->> 'changed') <> 'false' OR (v_r ->> 'reason') <> 'por_debajo_del_minimo' OR (v_r ->> 'minimo_gyd')::numeric <> v_min
     OR (v_r ->> 'source_amount_gyd')::numeric <> 5200 OR pg_temp.t231_state(v_op) <> v_before OR pg_temp.t231_audits(v_op) <> 0 THEN
    RAISE EXCEPTION 'case H3: below the Zelle minimum nothing changes and the minimum is reported, got %', v_r; END IF;
  -- two open remesas: record, apply nothing, no hand-over
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100);
  v_op2 := pg_temp.t231_op(v_conv, 'efectivo_usd', 30000);
  v_before := pg_temp.t231_state(v_op) || pg_temp.t231_state(v_op2);
  v_r := cerebro_registrar_destino_v2(v_conv, 'Mejor zelle', 'exec231-h4');
  IF (v_r ->> 'changed') <> 'false' OR (v_r ->> 'reason') <> 'operacion_ambigua' OR (v_r ->> 'tipo') <> 'zelle'
     OR v_before <> pg_temp.t231_state(v_op) || pg_temp.t231_state(v_op2)
     OR (SELECT tipo FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) <> 'zelle' THEN
    RAISE EXCEPTION 'case H4: two open remesas record zelle and apply nothing, got %', v_r; END IF;
  -- questions about Zelle change nothing and record nothing
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  v_before := pg_temp.t231_state(v_op);
  FOREACH v_text IN ARRAY ARRAY['¿tienen zelle?', 'cuánto es por zelle?', 'se puede por zelle?'] LOOP
    v_r := cerebro_registrar_destino_v2(v_conv, v_text, 'exec231-h5');
    IF v_r ->> 'tipo' IS NOT NULL OR (v_r ->> 'changed') <> 'false' OR pg_temp.t231_state(v_op) <> v_before
       OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) THEN
      RAISE EXCEPTION 'case H5: the question % must change and record nothing, got %', v_text, v_r; END IF;
  END LOOP;
  RAISE NOTICE 'PASS H: human lock (rail / recipients), transferring / completed, below the minimum (minimum reported), two operations, questions -> nothing changes, reason given';

  -- ---- I. the stale-write window of the tool ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv, 'zelle', now() - interval '10 minutes');
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-i1');
  IF v_text LIKE 'ERROR:%' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd' THEN
    RAISE EXCEPTION 'case I: a zelle stated 10 minutes ago no longer blocks the tool (behaviour as before), got %', v_text; END IF;
  -- the tool's own pending row (clasica, written through 221) never blocks a later tool call
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  PERFORM * FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec231-i2');
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec231-i3');
  IF v_text LIKE 'ERROR:%' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd' THEN
    RAISE EXCEPTION 'case I: a pending row written by the tool itself must not block the tool, got %', v_text; END IF;
  -- the customer said clasica, the tool asks for tropical: refused; asks for clasica: fine
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, NULL, 47100);
  PERFORM cerebro_registrar_destino_v2(v_conv, 'clasica', 'exec231-i4');
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'tropical', 'exec231-i5');
  IF v_text NOT LIKE 'ERROR:%' OR v_text NOT ILIKE '%clasica%' THEN RAISE EXCEPTION 'case I: tropical after the customer said clasica must be refused naming Clasica, got %', v_text; END IF;
  SELECT accion INTO v_text FROM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec231-i6');
  IF v_text LIKE 'ERROR:%' THEN RAISE EXCEPTION 'case I: marking the rail the customer stated is fine, got %', v_text; END IF;
  RAISE NOTICE 'PASS I: the tool refuses a rail that differs from what the customer said in the last 5 minutes; older / tool-written / same rail pass';

  -- ---- J. grants ----
  IF NOT has_function_privilege('service_role', 'public.cerebro_registrar_destino_v2(uuid, text, text, boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_registrar_destino(uuid, text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_detectar_destino(text)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.cerebro_marcar_destino_usd(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case J: service_role must execute the bot functions'; END IF;
  IF has_function_privilege('anon', 'public.cerebro_registrar_destino_v2(uuid, text, text, boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_registrar_destino_v2(uuid, text, text, boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_registrar_destino(uuid, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_registrar_destino(uuid, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_detectar_destino(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_detectar_destino(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_destino_es_pregunta(text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_destino_es_pregunta(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_destino_riel_negado(text, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_destino_riel_negado(text, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_destino_pendiente_op_creada()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_destino_pendiente_op_creada()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.cerebro_marcar_destino_usd(uuid, text, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_marcar_destino_usd(uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case J: anon and authenticated must not execute any of them'; END IF;
  IF EXISTS (SELECT 1 FROM pg_proc p WHERE p.proname IN ('cerebro_registrar_destino_v2', 'cerebro_destino_es_pregunta', 'cerebro_destino_riel_negado', 'cerebro_destino_pendiente_op_creada')
                AND has_function_privilege('public', p.oid, 'EXECUTE')) THEN
    RAISE EXCEPTION 'case J: PUBLIC must not execute the new functions'; END IF;
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  SET LOCAL ROLE anon;
  BEGIN PERFORM cerebro_registrar_destino_v2(v_conv, 'zelle', 'exec231-j'); RESET ROLE; RAISE EXCEPTION 'case J: anon must not call v2';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
  SET LOCAL ROLE authenticated;
  BEGIN PERFORM cerebro_registrar_destino(v_conv, 'zelle'); RESET ROLE; RAISE EXCEPTION 'case J: authenticated must not call v1';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE; END;
  SET LOCAL ROLE service_role;
  v_r := cerebro_registrar_destino_v2(v_conv, 'zelle', 'exec231-j');
  RESET ROLE;
  IF (v_r ->> 'tipo') <> 'zelle' THEN RAISE EXCEPTION 'case J: service_role must be able to call v2, got %', v_r; END IF;
  IF coalesce(current_setting('wacrm.origin', true), '') <> '' OR coalesce(current_setting('wacrm.actor', true), '') <> '' THEN
    RAISE EXCEPTION 'case J: the admin origin / actor context must not leak out of the call'; END IF;
  RAISE NOTICE 'PASS J: service_role executes; anon, authenticated and PUBLIC cannot; no context leaks';

  -- ---- K. v1 stays what the node reads today: the detected tipo as text (and it applies the change too) ----
  v_conv := pg_temp.t231_conv(v_user, v_acc);
  v_op := pg_temp.t231_op(v_conv, 'efectivo_usd', 47100, 'ready_to_transfer');
  IF cerebro_registrar_destino(v_conv, 'hola') IS NOT NULL THEN RAISE EXCEPTION 'case K: v1 returns NULL when nothing is named'; END IF;
  v_text := cerebro_registrar_destino(v_conv, 'Mejor zelle');
  IF v_text IS DISTINCT FROM 'zelle' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'zelle' OR pg_temp.t231_audits(v_op) <> 1 THEN
    RAISE EXCEPTION 'case K: v1 returns zelle (text) and applies the change, got %', v_text; END IF;
  IF pg_typeof(cerebro_registrar_destino(v_conv, 'tropical'))::text <> 'text' THEN RAISE EXCEPTION 'case K: v1 keeps its text return type'; END IF;
  RAISE NOTICE 'PASS K: v1 returns the tipo as text, NULL when nothing is named, and applies the same change';

  RAISE NOTICE 'ALL PASS (deterministic-destination-zelle)';
END $$;

ROLLBACK;
