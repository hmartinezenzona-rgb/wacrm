\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 222 (crm_cambiar_servicio: an agent changes an open operation's service from the panel).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection
-- closes, so nothing is kept). Each passing case NOTICEs.
-- Production 2026-10-06 (Yilian 6709a0cd): a recharge had been registered as a CUP remesa; crm_corregir_operacion has
-- no service_type, so it was fixed with SQL. crm_cambiar_servicio(operation, service) takes cuban_card, zelle, clasica,
-- tropical, efectivo_usd, recarga, combo or visa; recomputes the quote with the existing calculation; keeps the
-- recipients that fit and retires the rest; locks the rail against the bot; writes one human_correction audit row;
-- changes no status and sends nothing.
-- Rates are read from crm_tasa_vigente, so the expectations follow staging's rates.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t222_op(p_user uuid, p_acc uuid, p_phone text, p_service text, p_dm text, p_amount numeric,
                                p_status text DEFAULT 'collecting_information', p_locks jsonb DEFAULT '{}'::jsonb,
                                p_dest numeric DEFAULT NULL, p_costo numeric DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (p_user, p_acc, p_phone, 'test222') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (p_user, p_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency,
                                     quoted_source_amount, admin_locked_fields, quoted_destination_amount, quoted_destination_origin,
                                     destination_currency, combo_costo_gyd)
  VALUES (p_acc, v_conv, v_ct, 'collecting_information', p_service, p_dm, 'GYD', p_amount, p_locks, p_dest,
          CASE WHEN p_dest IS NOT NULL THEN 'manual' END, CASE WHEN p_dest IS NOT NULL THEN 'CUP' END, p_costo)
  RETURNING id INTO v_op;
  IF p_status <> 'collecting_information' THEN
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = p_status WHERE id = v_op;
    PERFORM set_config('wacrm.origin', '', true);
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t222_ben(p_op uuid, p_type text, p_card text, p_phone text, p_pos integer,
                                 p_amount numeric DEFAULT NULL, p_cur text DEFAULT NULL) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_id uuid;
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status, amount, currency)
  VALUES (p_op, p_type, p_card, p_phone, p_pos, p_pos, 'notes_parse', 'vigente', p_amount, p_cur) RETURNING id INTO v_id;
  RETURN v_id;
END $f$;

CREATE FUNCTION pg_temp.t222_call(p_op uuid, p_svc text, p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  v_r := crm_cambiar_servicio(p_op, p_svc);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.t222_try(p_op uuid, p_svc text, p_uid uuid) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t222_call(p_op, p_svc, p_uid);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE;
END $f$;

-- 'type/currency/amount' of the only current recipient, 'n=<count>' otherwise.
CREATE FUNCTION pg_temp.t222_one(p_op uuid) RETURNS text
LANGUAGE sql AS $f$
  SELECT CASE WHEN count(*) = 1 THEN max(beneficiary_type || '/' || coalesce(currency, '-') || '/' || coalesce(amount::text, '-'))
              ELSE 'n=' || count(*) END
    FROM remittance_beneficiaries WHERE operation_id = p_op AND status = 'vigente';
$f$;

CREATE FUNCTION pg_temp.t222_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990222%')
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990222%')
       + (SELECT count(*) FROM net.http_request_queue);
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_stranger uuid := gen_random_uuid();
  v_card constant text := '9760039001240356';
  v_ph constant text := '58528291';
  v_op uuid; v_op2 uuid; v_conv uuid; v_r jsonb; v_o remittance_operations%ROWTYPE; v_t text; v_n int; v_base bigint;
  v_usd_amt numeric; v_cup_amt numeric; v_ben uuid; v_a jsonb;
  v_closed1 uuid; v_closed2 uuid; v_cx uuid;
BEGIN
  IF NOT (v_usd > 0 AND v_cup > 0) THEN RAISE EXCEPTION 'setup: both rates are needed (usd %, cup %)', v_usd, v_cup; END IF;
  v_usd_amt := floor(5200 / v_usd);
  v_cup_amt := round(5200 * v_cup);
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- closed fixtures first: their status changes may legitimately post; the side-effect baseline is taken after them
  v_closed1 := pg_temp.t222_op(v_user, v_acc, '59902220090', 'remesa', 'cuban_card', 5200, 'completed');
  v_closed2 := pg_temp.t222_op(v_user, v_acc, '59902220091', 'remesa', 'cuban_card', 5200, 'cancelled');
  v_base := pg_temp.t222_side();

  -- ---- a. a CUP remesa walks through every service ----
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220001', 'remesa', 'cuban_card', 5200);
  v_ben := pg_temp.t222_ben(v_op, 'cuban_card', v_card, v_ph, 1);
  IF pg_temp.t222_one(v_op) <> 'cuban_card/CUP/' || v_cup_amt THEN
    RAISE EXCEPTION 'setup a: the CUP card should be priced % CUP, got %', v_cup_amt, pg_temp.t222_one(v_op); END IF;

  -- a1. -> clasica: the same card re-typed, USD floor(5200 / rate), destination USD
  v_r := pg_temp.t222_call(v_op, 'clasica', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'remesa' OR v_o.delivery_method <> 'clasica' OR v_o.destination_currency IS DISTINCT FROM 'USD'
     OR v_o.quoted_destination_amount IS DISTINCT FROM v_usd_amt OR v_o.quoted_destination_origin IS DISTINCT FROM 'calculated'
     OR v_o.quoted_destination_rate IS DISTINCT FROM v_usd OR v_o.status <> 'collecting_information' THEN
    RAISE EXCEPTION 'case a1: expected remesa/clasica/USD/%/calculated and the same status, got % / % / % / % / % / %',
      v_usd_amt, v_o.service_type, v_o.delivery_method, v_o.destination_currency, v_o.quoted_destination_amount, v_o.quoted_destination_origin, v_o.status; END IF;
  IF pg_temp.t222_one(v_op) <> 'clasica/USD/' || v_usd_amt THEN
    RAISE EXCEPTION 'case a1: the card should be clasica/USD/%, got %', v_usd_amt, pg_temp.t222_one(v_op); END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND card_number = v_card AND phone = v_ph AND id = v_ben) THEN
    RAISE EXCEPTION 'case a1: the same card and phone must stay'; END IF;
  IF (v_r ->> 'service') <> 'clasica' OR (v_r ->> 'changed') <> 'true' OR (v_r ->> 'operation_id') <> v_op::text THEN
    RAISE EXCEPTION 'case a1: unexpected summary %', v_r; END IF;
  IF NOT (v_o.admin_locked_fields ? 'delivery_method') OR (v_o.admin_locked_fields ? 'quoted_destination_amount')
     OR (v_o.admin_locked_fields ? 'destination_currency') THEN
    RAISE EXCEPTION 'case a1: the rail must be locked and the recalculated quote must not be, got %', v_o.admin_locked_fields; END IF;
  IF calculator_resolve_operation_service(v_op, v_o.delivery_method) <> 'CLASICA' THEN
    RAISE EXCEPTION 'case a1: the ledger should price CLASICA'; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_correction' AND field_name = 'service';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case a1: expected one human_correction audit row, got %', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_correction' AND field_name = 'service'
                    AND before ->> 'service' = 'cuban_card' AND after ->> 'service' = 'clasica'
                    AND (before ->> 'quoted_destination_amount')::numeric = v_cup_amt
                    AND (after ->> 'quoted_destination_amount')::numeric = v_usd_amt AND after ->> 'destination_currency' = 'USD') THEN
    RAISE EXCEPTION 'case a1: the audit row must carry before/after service and quote'; END IF;
  RAISE NOTICE 'PASS a1: CUP remesa -> clasica (% USD), card kept, rail locked, quote not locked, audited', v_usd_amt;

  -- a2. -> tropical
  PERFORM pg_temp.t222_call(v_op, 'tropical', v_user);
  IF pg_temp.t222_one(v_op) <> 'tropical/USD/' || v_usd_amt
     OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'tropical'
     OR calculator_resolve_operation_service(v_op, 'tropical') <> 'TROPICAL' THEN
    RAISE EXCEPTION 'case a2: tropical expected, got %', pg_temp.t222_one(v_op); END IF;
  RAISE NOTICE 'PASS a2: clasica -> tropical';

  -- a3. -> cuban_card: back to CUP
  PERFORM pg_temp.t222_call(v_op, 'cuban_card', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF pg_temp.t222_one(v_op) <> 'cuban_card/CUP/' || v_cup_amt OR v_o.destination_currency IS DISTINCT FROM 'CUP'
     OR v_o.quoted_destination_amount IS DISTINCT FROM v_cup_amt OR v_o.delivery_method <> 'cuban_card'
     OR calculator_resolve_operation_service(v_op, 'cuban_card') <> 'CUP' THEN
    RAISE EXCEPTION 'case a3: back to CUP/% expected, got % / % / %', v_cup_amt, pg_temp.t222_one(v_op), v_o.destination_currency, v_o.quoted_destination_amount; END IF;
  RAISE NOTICE 'PASS a3: tropical -> cuban_card, CUP % again', v_cup_amt;

  -- a4. -> zelle: the card is retired, the destination waits for a Zelle recipient
  PERFORM pg_temp.t222_call(v_op, 'zelle', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF pg_temp.t222_one(v_op) <> 'n=0' OR v_o.delivery_method <> 'zelle' OR v_o.service_type <> 'remesa'
     OR v_o.quoted_destination_amount IS NOT NULL OR v_o.destination_currency IS NOT NULL
     OR v_o.quoted_destination_rate IS NOT NULL OR v_o.quoted_destination_origin IS NOT NULL THEN
    RAISE EXCEPTION 'case a4: zelle with no recipient and no destination expected, got % / % / % / %',
      pg_temp.t222_one(v_op), v_o.delivery_method, v_o.quoted_destination_amount, v_o.destination_currency; END IF;
  IF (SELECT status FROM remittance_beneficiaries WHERE id = v_ben) <> 'reemplazado'
     OR (SELECT replaced_at FROM remittance_beneficiaries WHERE id = v_ben) IS NULL THEN
    RAISE EXCEPTION 'case a4: the card must be retired (reemplazado)'; END IF;
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case a4: a zelle with no recipient must not be complete'; END IF;
  RAISE NOTICE 'PASS a4: cuban_card -> zelle retires the card and clears the destination';

  -- a5. -> efectivo_usd
  PERFORM pg_temp.t222_call(v_op, 'efectivo_usd', v_user);
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd'
     OR calculator_resolve_operation_service(v_op, 'efectivo_usd') <> 'EFECTIVO' THEN
    RAISE EXCEPTION 'case a5: efectivo_usd expected'; END IF;
  RAISE NOTICE 'PASS a5: zelle -> efectivo_usd';

  -- a6. -> recarga: service_type recarga, no delivery method, no destination; the ledger feed follows with no recipients
  PERFORM pg_temp.t222_call(v_op, 'recarga', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'recarga' OR v_o.delivery_method IS NOT NULL OR v_o.quoted_destination_amount IS NOT NULL
     OR v_o.destination_currency IS NOT NULL OR pg_temp.t222_one(v_op) <> 'n=0'
     OR calculator_resolve_operation_service(v_op, v_o.delivery_method) <> 'RECARGA' THEN
    RAISE EXCEPTION 'case a6: recarga with no delivery method, destination or recipients expected, got % / % / %',
      v_o.service_type, v_o.delivery_method, calculator_resolve_operation_service(v_op, v_o.delivery_method); END IF;
  RAISE NOTICE 'PASS a6: efectivo_usd -> recarga, the ledger prices RECARGA';

  -- a7. recarga -> cuban_card: a remesa again, asking for the card
  PERFORM pg_temp.t222_call(v_op, 'cuban_card', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'remesa' OR v_o.delivery_method <> 'cuban_card' OR crm_beneficiarios_completos(v_op)
     OR calculator_resolve_operation_service(v_op, v_o.delivery_method) <> 'CUP' THEN
    RAISE EXCEPTION 'case a7: remesa/cuban_card waiting for its card expected'; END IF;
  RAISE NOTICE 'PASS a7: recarga -> cuban_card asks for the card';

  -- a8. the bot cannot flip the rail back
  PERFORM cerebro_marcar_destino_usd((SELECT conversation_id FROM remittance_operations WHERE id = v_op), 'clasica', 'exec222-a8');
  IF (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'cuban_card' THEN
    RAISE EXCEPTION 'case a8: the bot flipped the locked rail back to %', (SELECT delivery_method FROM remittance_operations WHERE id = v_op); END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_write_suppressed' AND field_name = 'delivery_method') THEN
    RAISE EXCEPTION 'case a8: the suppressed bot write should be audited'; END IF;
  RAISE NOTICE 'PASS a8: the bot cannot flip the rail back';

  -- a9. -> visa, a10. -> combo
  PERFORM pg_temp.t222_call(v_op, 'visa', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'visa' OR v_o.delivery_method IS NOT NULL OR calculator_resolve_operation_service(v_op, NULL) <> 'VISA'
     OR cerebro_riel_op(v_op) <> 'visa' THEN RAISE EXCEPTION 'case a9: visa expected'; END IF;
  PERFORM pg_temp.t222_call(v_op, 'combo', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'combo' OR v_o.delivery_method IS NOT NULL OR calculator_resolve_operation_service(v_op, NULL) <> 'COMBO'
     OR cerebro_riel_op(v_op) <> 'combo' THEN RAISE EXCEPTION 'case a10: combo expected'; END IF;
  RAISE NOTICE 'PASS a9/a10: -> visa, -> combo, the ledger follows';

  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_correction' AND field_name = 'service';
  IF v_n <> 9 THEN RAISE EXCEPTION 'case a: nine switches expected nine audit rows, got %', v_n; END IF;

  -- ---- b. a recarga with a bot that tries to turn it into a clasica ----
  v_op2 := pg_temp.t222_op(v_user, v_acc, '59902220002', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.t222_ben(v_op2, 'cuban_card', v_card, v_ph, 1);
  PERFORM pg_temp.t222_call(v_op2, 'recarga', v_user);
  PERFORM cerebro_marcar_destino_usd((SELECT conversation_id FROM remittance_operations WHERE id = v_op2), 'clasica', 'exec222-b');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op2;
  IF v_o.service_type <> 'recarga' OR v_o.delivery_method IS NOT NULL OR pg_temp.t222_one(v_op2) <> 'n=0' THEN
    RAISE EXCEPTION 'case b: the bot must not turn the recarga back (got % / % / %)', v_o.service_type, v_o.delivery_method, pg_temp.t222_one(v_op2); END IF;
  RAISE NOTICE 'PASS b: a recarga stays a recarga against the bot';

  -- ---- c. zelle recipient + other recipient types retire when they do not fit ----
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220003', 'remesa', 'zelle', 5200);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Test Zelle', 'z222@test.invalid', 1, 1, 'notes_parse', 'vigente');
  IF pg_temp.t222_one(v_op) NOT LIKE 'zelle/USD/%' THEN RAISE EXCEPTION 'setup c: the zelle recipient should be priced, got %', pg_temp.t222_one(v_op); END IF;
  PERFORM pg_temp.t222_call(v_op, 'cuban_card', v_user);
  IF pg_temp.t222_one(v_op) <> 'n=0' OR (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_op) IS NOT NULL THEN
    RAISE EXCEPTION 'case c: the zelle recipient should be retired and the zelle quote cleared, got %', pg_temp.t222_one(v_op); END IF;
  RAISE NOTICE 'PASS c: zelle -> cuban_card retires the zelle recipient';

  -- ---- d. a locked-beneficiaries operation and a manual quote are recomputed ----
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220004', 'remesa', 'cuban_card', 5200,
                          'collecting_information', '{"beneficiaries":{"by":"x","at":"2026-10-01T00:00:00Z"},"quoted_destination_amount":{"by":"x","at":"2026-10-01T00:00:00Z"}}'::jsonb,
                          15000);
  PERFORM pg_temp.t222_ben(v_op, 'cuban_card', v_card, v_ph, 1, 15000, 'CUP');
  PERFORM pg_temp.t222_call(v_op, 'clasica', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.quoted_destination_amount IS DISTINCT FROM v_usd_amt OR v_o.quoted_destination_origin <> 'calculated'
     OR v_o.destination_currency <> 'USD' OR (v_o.admin_locked_fields ? 'quoted_destination_amount') THEN
    RAISE EXCEPTION 'case d: the manual quote must be recomputed (% / % / %)', v_o.quoted_destination_amount, v_o.quoted_destination_origin, v_o.destination_currency; END IF;
  IF pg_temp.t222_one(v_op) <> 'clasica/USD/' || v_usd_amt THEN
    RAISE EXCEPTION 'case d: the recipient of a beneficiaries-locked operation must follow, got %', pg_temp.t222_one(v_op); END IF;
  IF NOT (v_o.admin_locked_fields ? 'beneficiaries') THEN RAISE EXCEPTION 'case d: an existing lock must not be lost'; END IF;
  RAISE NOTICE 'PASS d: manual quote and locked recipient follow the new service';

  -- ---- e. several recipients with their own amounts ----
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220005', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.t222_ben(v_op, 'cuban_card', v_card, v_ph, 1, 30000, 'CUP');
  PERFORM pg_temp.t222_ben(v_op, 'cuban_card', '9227959879614050', '54363811', 2, 30000, 'CUP');
  IF pg_temp.t222_try(v_op, 'clasica', v_user) <> '22023' THEN
    RAISE EXCEPTION 'case e: CUP shares cannot become USD ones automatically'; END IF;
  IF pg_temp.t222_one(v_op) <> 'n=2' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'cuban_card' THEN
    RAISE EXCEPTION 'case e: a refused change must leave the operation as it was'; END IF;
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220006', 'remesa', 'clasica', 5200);
  PERFORM pg_temp.t222_ben(v_op, 'clasica', v_card, v_ph, 1, 10, 'USD');
  PERFORM pg_temp.t222_ben(v_op, 'clasica', '9227959879614050', '54363811', 2, 20, 'USD');
  PERFORM pg_temp.t222_call(v_op, 'tropical', v_user);
  IF (SELECT string_agg(beneficiary_type || '/' || amount, ',' ORDER BY position) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 'tropical/10,tropical/20' THEN
    RAISE EXCEPTION 'case e: both USD shares should become tropical with their amounts'; END IF;
  RAISE NOTICE 'PASS e: several shares: refused across currencies, kept on a USD rail change';

  -- ---- f. a combo's recipients and cost go when it becomes a remesa ----
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220007', 'combo', NULL, 25000, 'collecting_information', '{}'::jsonb, NULL, 1000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, address, reference, amount, currency, position, block_index, source, status)
  VALUES (v_op, 'combo', 'Test Combo', v_ph, 'Calle 1, La Habana', 'ref', 25000, 'GYD', 1, 1, 'admin_addition', 'vigente');
  PERFORM pg_temp.t222_call(v_op, 'clasica', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'remesa' OR v_o.delivery_method <> 'clasica' OR pg_temp.t222_one(v_op) <> 'n=0' OR v_o.combo_costo_gyd IS NOT NULL THEN
    RAISE EXCEPTION 'case f: a combo becoming a clasica remesa loses its recipients and cost'; END IF;
  RAISE NOTICE 'PASS f: combo -> clasica';

  -- ---- g. the same service changes nothing and audits nothing ----
  v_op := pg_temp.t222_op(v_user, v_acc, '59902220008', 'remesa', 'cuban_card', 5200);
  PERFORM pg_temp.t222_ben(v_op, 'cuban_card', v_card, v_ph, 1);
  v_r := pg_temp.t222_call(v_op, 'cuban_card', v_user);
  IF (v_r ->> 'changed') <> 'false' OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND field_name = 'service')
     OR pg_temp.t222_one(v_op) <> 'cuban_card/CUP/' || v_cup_amt THEN
    RAISE EXCEPTION 'case g: the same service must be a no-op, got %', v_r; END IF;
  RAISE NOTICE 'PASS g: same service is a no-op';

  -- ---- h. refusals ----
  IF pg_temp.t222_try(v_closed1, 'clasica', v_user) <> '22023' THEN RAISE EXCEPTION 'case h: a completed operation must be refused'; END IF;
  IF pg_temp.t222_try(v_closed2, 'clasica', v_user) <> '22023' THEN RAISE EXCEPTION 'case h: a cancelled operation must be refused'; END IF;
  IF pg_temp.t222_try(v_op, 'clasica', v_stranger) <> '42501' THEN RAISE EXCEPTION 'case h: a non-member must be refused'; END IF;
  IF pg_temp.t222_try(v_op, 'clasica', NULL) <> '42501' THEN RAISE EXCEPTION 'case h: an unauthenticated call must be refused'; END IF;
  IF pg_temp.t222_try(v_op, 'bitcoin', v_user) <> '22023' THEN RAISE EXCEPTION 'case h: an unknown service must be refused'; END IF;
  IF pg_temp.t222_try(v_op, NULL, v_user) <> '22023' THEN RAISE EXCEPTION 'case h: a null service must be refused'; END IF;
  IF pg_temp.t222_try(gen_random_uuid(), 'clasica', v_user) <> 'P0002' THEN RAISE EXCEPTION 'case h: an unknown operation must be refused'; END IF;
  v_cx := pg_temp.t222_op(v_user, v_acc, '59902220009', 'traduccion', NULL, 1000);
  IF pg_temp.t222_try(v_cx, 'clasica', v_user) <> '22023' THEN RAISE EXCEPTION 'case h: a translation operation must be refused'; END IF;
  IF (SELECT status FROM remittance_operations WHERE id = v_closed1) <> 'completed'
     OR (SELECT status FROM remittance_operations WHERE id = v_closed2) <> 'cancelled' THEN
    RAISE EXCEPTION 'case h: closed operations must stay closed'; END IF;
  RAISE NOTICE 'PASS h: closed, non-member, unauthenticated, unknown service, unknown operation and other types are refused';

  -- ---- i. nothing was sent ----
  IF pg_temp.t222_side() <> v_base THEN
    RAISE EXCEPTION 'case i: messages/outbox/net queue grew from % to %', v_base, pg_temp.t222_side(); END IF;
  RAISE NOTICE 'PASS i: no messages, outbox rows or http requests';

  RAISE NOTICE 'ALL PASS (change-operation-service)';
END $$;

ROLLBACK;
