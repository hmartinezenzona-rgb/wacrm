\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 223 ("Saldo movil" as an operation service). Self-reverting: BEGIN ... ROLLBACK is in this
-- file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so nothing is kept). Each passing case
-- NOTICEs. Runs on staging (production after the owner's go-ahead).
--
-- odd/tasks/saldo-movil-service.md (T1). A mobile balance top-up to a Cuban phone is an operation service of its own
-- (service_type 'saldo'): sold in fixed packages (1,000 GYD = 360 of saldo; cerebro_config precio_saldo_gyd and
-- saldo_unidad_cup), not promo-bound, one Cuban number receives every package, minimum one package. The ledger line is
-- SALDO_MOVIL: units = deposit / price when exact, facturado = units x price, invertido = units x saldo_costo_usdt x
-- usdt_buy_gyd. A deposit that is not a whole multiple of the price, or a missing cost, leaves the line pending (no
-- silent rounding). crm_resolve_pending_entry prices a RECARGA or SALDO_MOVIL line with its own branch (it used to
-- price them as a USD service).
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t223_op(p_user uuid, p_acc uuid, p_phone text, p_service text, p_dm text, p_amount numeric,
                                p_status text DEFAULT 'collecting_information') RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (p_user, p_acc, p_phone, 'test223') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (p_user, p_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, delivery_method, source_currency, quoted_source_amount)
  VALUES (p_acc, v_conv, v_ct, 'collecting_information', p_service, p_dm, 'GYD', p_amount) RETURNING id INTO v_op;
  IF p_status <> 'collecting_information' THEN
    PERFORM set_config('wacrm.origin', 'admin', true);
    UPDATE remittance_operations SET status = p_status WHERE id = v_op;
    PERFORM set_config('wacrm.origin', '', true);
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t223_call(p_op uuid, p_svc text, p_uid uuid) RETURNS jsonb
LANGUAGE plpgsql AS $f$
DECLARE v_r jsonb;
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  v_r := crm_cambiar_servicio(p_op, p_svc);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.t223_add(p_op uuid, p_data jsonb, p_uid uuid) RETURNS text
LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  PERFORM crm_agregar_beneficiario(p_op, p_data);
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.t223_line(p_op uuid) RETURNS remittance_calculator_entries
LANGUAGE sql AS $f$
  SELECT e FROM remittance_calculator_entries e WHERE e.operation_id = p_op AND e.status <> 'void';
$f$;

CREATE FUNCTION pg_temp.t223_side() RETURNS bigint
LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990223%' AND m.sender_type <> 'customer')
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id JOIN contacts ct ON ct.id = c.contact_id WHERE ct.phone LIKE '5990223%')
       -- the row-change feed of remittance_operations fires on the fixtures' own status moves (ready_to_transfer, completed);
       -- it is rolled back with this file and is not a customer message: everything else queued is counted
       + (SELECT count(*) FROM net.http_request_queue q WHERE coalesce(convert_from(q.body, 'utf8'), '') NOT LIKE '%"table": "remittance_operations"%');
$f$;

DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_stranger uuid := gen_random_uuid();
  v_card constant text := '9760039001240356';
  v_ph constant text := '53871234';
  v_op uuid; v_op2 uuid; v_conv uuid; v_r jsonb; v_o remittance_operations%ROWTYPE; v_e remittance_calculator_entries;
  v_n int; v_base bigint; v_row record; v_res text; v_id uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  PERFORM crm_set_calculator_rates(v_acc, '{"saldo_costo_usdt": 1.25, "usdt_buy_gyd": 242, "recarga_costo_usdt": 23.1}'::jsonb, NULL);
  PERFORM set_config('request.jwt.claims', '', true);
  v_base := pg_temp.t223_side();

  -- ---- 1. data, not code: the price and the package size are cerebro_config rows ----
  IF cerebro_config_get('precio_saldo_gyd') IS DISTINCT FROM '1000' OR cerebro_config_get('saldo_unidad_cup') IS DISTINCT FROM '360' THEN
    RAISE EXCEPTION 'case 1: precio_saldo_gyd must be 1000 and saldo_unidad_cup 360, got % / %',
      cerebro_config_get('precio_saldo_gyd'), cerebro_config_get('saldo_unidad_cup'); END IF;
  IF cerebro_saldo_precio() IS DISTINCT FROM 1000 OR cerebro_saldo_paquetes(5000) IS DISTINCT FROM 5
     OR cerebro_saldo_paquetes(1000) IS DISTINCT FROM 1 OR cerebro_saldo_paquetes(5500) IS NOT NULL
     OR cerebro_saldo_paquetes(500) IS NOT NULL OR cerebro_saldo_paquetes(0) IS NOT NULL THEN
    RAISE EXCEPTION 'case 1: price 1000; packages 5000 -> 5, 1000 -> 1, 5500/500/0 -> NULL'; END IF;
  RAISE NOTICE 'PASS 1: price and package size are data; packages only for whole multiples';

  -- ---- 2. a remesa changed to saldo from the chat panel ----
  v_op := pg_temp.t223_op(v_user, v_acc, '59902230001', 'remesa', 'cuban_card', 5000);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', v_card, v_ph, 1, 1, 'notes_parse', 'vigente');
  v_r := pg_temp.t223_call(v_op, 'saldo', v_user);
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'saldo' OR v_o.delivery_method IS NOT NULL OR v_o.quoted_destination_amount IS NOT NULL
     OR v_o.destination_currency IS NOT NULL OR v_o.status <> 'collecting_information' THEN
    RAISE EXCEPTION 'case 2: saldo with no delivery method or destination quote expected, got % / % / %',
      v_o.service_type, v_o.delivery_method, v_o.quoted_destination_amount; END IF;
  IF (v_r ->> 'service') <> 'saldo' OR (v_r ->> 'changed') <> 'true' OR (v_r ->> 'retired_recipients')::int <> 1 THEN
    RAISE EXCEPTION 'case 2: unexpected summary %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') THEN
    RAISE EXCEPTION 'case 2: the card recipient must be retired'; END IF;
  IF cerebro_riel_op(v_op) <> 'saldo' OR calculator_resolve_operation_service(v_op, v_o.delivery_method) <> 'SALDO_MOVIL'
     OR calculator_service_for_operation('saldo') <> 'SALDO_MOVIL' THEN
    RAISE EXCEPTION 'case 2: the rail is saldo and the ledger prices SALDO_MOVIL'; END IF;
  IF NOT (v_o.admin_locked_fields ? 'service_type') OR NOT (v_o.admin_locked_fields ? 'delivery_method') THEN
    RAISE EXCEPTION 'case 2: the service must be locked against the bot, got %', v_o.admin_locked_fields; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_correction' AND field_name = 'service'
                    AND before ->> 'service' = 'cuban_card' AND after ->> 'service' = 'saldo') THEN
    RAISE EXCEPTION 'case 2: the change must be audited'; END IF;
  -- the bot cannot flip it back
  PERFORM cerebro_marcar_destino_usd((SELECT conversation_id FROM remittance_operations WHERE id = v_op), 'clasica', 'exec223-2');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op;
  IF v_o.service_type <> 'saldo' OR v_o.delivery_method IS NOT NULL THEN
    RAISE EXCEPTION 'case 2: the bot flipped a saldo back to % / %', v_o.service_type, v_o.delivery_method; END IF;
  -- the same service again is a no-op; saldo -> a rail and back works
  v_r := pg_temp.t223_call(v_op, 'saldo', v_user);
  IF (v_r ->> 'changed') <> 'false' THEN RAISE EXCEPTION 'case 2: saldo -> saldo must be a no-op, got %', v_r; END IF;
  PERFORM pg_temp.t223_call(v_op, 'cuban_card', v_user);
  IF (SELECT service_type || '/' || delivery_method FROM remittance_operations WHERE id = v_op) <> 'remesa/cuban_card' THEN
    RAISE EXCEPTION 'case 2: saldo -> cuban_card must give a remesa back'; END IF;
  PERFORM pg_temp.t223_call(v_op, 'saldo', v_user);
  -- a recarga becomes a saldo too, and a saldo a recarga
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230002', 'recarga', NULL, 5200);
  PERFORM pg_temp.t223_call(v_op2, 'saldo', v_user);
  IF (SELECT service_type FROM remittance_operations WHERE id = v_op2) <> 'saldo' THEN RAISE EXCEPTION 'case 2: recarga -> saldo'; END IF;
  PERFORM pg_temp.t223_call(v_op2, 'recarga', v_user);
  IF (SELECT service_type FROM remittance_operations WHERE id = v_op2) <> 'recarga' THEN RAISE EXCEPTION 'case 2: saldo -> recarga'; END IF;
  RAISE NOTICE 'PASS 2: remesa -> saldo retires the recipients, locks the service, the bot cannot flip it, audited';

  -- ---- 3. the phone recipient: one Cuban number ----
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 3: a saldo without a number is incomplete'; END IF;
  IF pg_temp.t223_add(v_op, jsonb_build_object('beneficiary_type', 'cuban_card', 'card_number', v_card, 'phone', v_ph, 'amount', 5000, 'currency', 'CUP'), v_user) <> '22023' THEN
    RAISE EXCEPTION 'case 3: a saldo takes a phone recipient only'; END IF;
  IF pg_temp.t223_add(v_op, jsonb_build_object('beneficiary_type', 'recarga', 'phone', '78123456'), v_user) <> '22023' THEN
    RAISE EXCEPTION 'case 3: a landline is not a mobile number'; END IF;
  IF pg_temp.t223_add(v_op, jsonb_build_object('beneficiary_type', 'recarga', 'phone', v_ph), v_stranger) <> '42501' THEN
    RAISE EXCEPTION 'case 3: a non-member must be refused'; END IF;
  IF pg_temp.t223_add(v_op, jsonb_build_object('beneficiary_type', 'recarga', 'phone', v_ph), v_user) <> 'ok' THEN
    RAISE EXCEPTION 'case 3: the phone recipient must be accepted'; END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 3: one valid mobile completes a saldo'; END IF;
  IF pg_temp.t223_add(v_op, jsonb_build_object('beneficiary_type', 'recarga', 'phone', '63123456'), v_user) <> '22023' THEN
    RAISE EXCEPTION 'case 3: a saldo has ONE number: a second one must be refused'; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'recarga') <> 1 THEN
    RAISE EXCEPTION 'case 3: exactly one recipient row expected'; END IF;
  -- a remesa still takes no phone-only recipient
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230003', 'remesa', 'cuban_card', 5000);
  IF pg_temp.t223_add(v_op2, jsonb_build_object('beneficiary_type', 'recarga', 'phone', v_ph), v_user) <> '22023' THEN
    RAISE EXCEPTION 'case 3: a remesa takes no recharge number'; END IF;
  -- a recarga keeps its rule: as many numbers as recharges
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230004', 'recarga', NULL, 10400);
  PERFORM pg_temp.t223_add(v_op2, jsonb_build_object('beneficiary_type', 'recarga', 'phone', v_ph), v_user);
  IF crm_beneficiarios_completos(v_op2) THEN RAISE EXCEPTION 'case 3: a recarga of 2 with one number is still incomplete'; END IF;
  PERFORM pg_temp.t223_add(v_op2, jsonb_build_object('beneficiary_type', 'recarga', 'phone', '63123456'), v_user);
  IF NOT crm_beneficiarios_completos(v_op2) THEN RAISE EXCEPTION 'case 3: a recarga of 2 with two numbers is complete'; END IF;
  RAISE NOTICE 'PASS 3: one phone recipient completes a saldo; a second, a card or a landline is refused; recarga unchanged';

  -- ---- 4. the panel lists it with its recipient ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT * INTO v_row FROM crm_operaciones_de_conversacion((SELECT conversation_id FROM remittance_operations WHERE id = v_op)) LIMIT 1;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_row.operation_id IS DISTINCT FROM v_op OR v_row.operation_service_type IS DISTINCT FROM 'saldo'
     OR v_row.beneficiary_type IS DISTINCT FROM 'recarga' OR v_row.beneficiary_phone IS DISTINCT FROM v_ph
     OR v_row.operation_beneficiaries_complete IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'case 4: the panel must list the saldo with its phone, got % / % / % / %',
      v_row.operation_service_type, v_row.beneficiary_type, v_row.beneficiary_phone, v_row.operation_beneficiaries_complete; END IF;
  RAISE NOTICE 'PASS 4: crm_operaciones_de_conversacion lists the saldo with its phone recipient';

  -- ---- 5. the minimum is one package ----
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230005', 'saldo', NULL, 500);
  IF cerebro_minimo_gyd(v_op2) IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'case 5: the minimum of a saldo is one package (1000), got %', cerebro_minimo_gyd(v_op2); END IF;
  UPDATE cerebro_config SET valor = '1200' WHERE clave = 'precio_saldo_gyd';
  IF cerebro_minimo_gyd(v_op2) IS DISTINCT FROM 1200 OR cerebro_saldo_paquetes(2400) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'case 5: the minimum follows the package price'; END IF;
  UPDATE cerebro_config SET valor = '1000' WHERE clave = 'precio_saldo_gyd';
  PERFORM cerebro_objetivo_minimo((SELECT conversation_id FROM remittance_operations WHERE id = v_op2), v_op2, false);
  IF NOT EXISTS (SELECT 1 FROM cerebro_objetivo_envio x WHERE x.conversation_id = (SELECT conversation_id FROM remittance_operations WHERE id = v_op2)
                    AND x.monto = 1000 AND x.pedido = 'minimo saldo movil') THEN
    RAISE EXCEPTION 'case 5: the objetivo must name the saldo minimum'; END IF;
  RAISE NOTICE 'PASS 5: minimum = one package, named in the objetivo';

  -- ---- 6. the remesa writers leave a saldo alone ----
  v_conv := (SELECT conversation_id FROM remittance_operations WHERE id = v_op2);
  v_res := cerebro_escribir_bloque_beneficiario(v_conv, v_op2, E'BENEFICIARIO\nTarjeta: 9227069911112222\nCelular: 53121212')::text;
  IF v_res = v_op2::text OR EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op2)
     OR (SELECT service_type FROM remittance_operations WHERE id = v_res::uuid) <> 'remesa' THEN
    RAISE EXCEPTION 'case 6: the shared writer must open a remesa next to the saldo and write there'; END IF;
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230006', 'saldo', NULL, 1000);
  v_conv := (SELECT conversation_id FROM remittance_operations WHERE id = v_op2);
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', '9227069911112222 53121212');
  PERFORM cerebro_guardar_beneficiario_auto(v_conv, '9227069911112222', '53121212', '9227069911112222', '53121212', 'assert223');
  IF EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE operation_id = v_op2)
     OR (SELECT count(*) FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'remesa') <> 1 THEN
    RAISE EXCEPTION 'case 6: typed card and phone must open a remesa and leave the saldo untouched'; END IF;
  RAISE NOTICE 'PASS 6: the remesa writers never write on a saldo';

  -- ---- 7. manual close as saldo (the picker) and the ledger line ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230007', 'remesa', NULL, 5000, 'ready_to_transfer');
  PERFORM crm_cerrar_operacion_manual(v_op2, NULL, false, 'saldo');
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_op2;
  IF v_o.service_type <> 'saldo' OR v_o.status <> 'completed' OR v_o.delivery_method IS NOT NULL THEN
    RAISE EXCEPTION 'case 7: the picker must set service_type saldo, got % / %', v_o.service_type, v_o.status; END IF;
  v_e := pg_temp.t223_line(v_op2);
  IF v_e.service IS DISTINCT FROM 'SALDO_MOVIL' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.amount IS DISTINCT FROM 1800
     OR v_e.amount_currency IS DISTINCT FROM 'SM' THEN
    RAISE EXCEPTION 'case 7: expected SALDO_MOVIL completed 1800 SM (5 packages x 360), got % % % %', v_e.service, v_e.status, v_e.amount, v_e.amount_currency; END IF;
  IF v_e.facturado_gyd IS DISTINCT FROM 5000 OR v_e.invertido_gyd IS DISTINCT FROM 1512.5 OR v_e.retorno_gyd IS DISTINCT FROM 3487.5
     OR v_e.basis_gyd IS DISTINCT FROM 5000 THEN
    RAISE EXCEPTION 'case 7: facturado/invertido/retorno must be 5000 / 1512.5 / 3487.5, got % / % / %', v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd; END IF;
  IF v_e.cost_gyd IS DISTINCT FROM 1.25 OR v_e.sale_gyd IS DISTINCT FROM 1000 OR v_e.cup_rate IS DISTINCT FROM 242 OR v_e.usdt_buy_gyd IS DISTINCT FROM 242
     OR v_e.missing_inputs IS NOT NULL THEN
    RAISE EXCEPTION 'case 7: the snapshot reads like a manual saldo line (cost 1.25, sale 1000, rate 242), got % / % / %', v_e.cost_gyd, v_e.sale_gyd, v_e.cup_rate; END IF;
  PERFORM calculator_feed_operation(v_op2);
  IF (SELECT count(*) FROM remittance_calculator_entries WHERE operation_id = v_op2 AND status <> 'void') <> 1 THEN
    RAISE EXCEPTION 'case 7: re-feeding must not duplicate the line'; END IF;
  -- the rates asked for
  IF calculator_missing_rates('SALDO_MOVIL', (SELECT r FROM calculator_rate_versions r WHERE r.account_id = v_acc ORDER BY r.effective_at DESC LIMIT 1)) <> ARRAY[]::text[] THEN
    RAISE EXCEPTION 'case 7: nothing missing while the cost and the buy rate are set'; END IF;
  RAISE NOTICE 'PASS 7: manual close as saldo -> one SALDO_MOVIL line, 1800 SM, 5000 / 1512.5 / 3487.5';

  -- ---- 8. a completed saldo through the normal completion (with its recipient) ----
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230008', 'saldo', NULL, 3000, 'ready_to_transfer');
  PERFORM pg_temp.t223_add(v_op2, jsonb_build_object('beneficiary_type', 'recarga', 'phone', v_ph), v_user);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  PERFORM crm_cerrar_operacion_manual(v_op2);
  v_e := pg_temp.t223_line(v_op2);
  IF v_e.service IS DISTINCT FROM 'SALDO_MOVIL' OR v_e.amount IS DISTINCT FROM 1080 OR v_e.amount_currency IS DISTINCT FROM 'SM'
     OR v_e.facturado_gyd IS DISTINCT FROM 3000 OR v_e.invertido_gyd IS DISTINCT FROM 907.5 THEN
    RAISE EXCEPTION 'case 8: a saldo with its recipient shows 1080 SM and prices 3 packages 3000 / 907.5, got % % % %', v_e.service, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd; END IF;
  RAISE NOTICE 'PASS 8: a saldo with its phone recipient reaches the ledger';

  -- ---- 9. missing cost: pending, naming the cost; resolve with the cost completes it ----
  PERFORM crm_set_calculator_rates(v_acc, '{"saldo_costo_usdt": null}'::jsonb, NULL);
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230009', 'saldo', NULL, 5000, 'ready_to_transfer');
  PERFORM crm_cerrar_operacion_manual(v_op2);
  v_e := pg_temp.t223_line(v_op2);
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR NOT ('saldoCostoUsdt' = ANY (v_e.missing_inputs)) OR v_e.facturado_gyd IS NOT NULL THEN
    RAISE EXCEPTION 'case 9: a missing cost leaves the line pending naming saldoCostoUsdt, got % %', v_e.status, v_e.missing_inputs; END IF;
  -- an exact package count shows its saldo even while pending
  IF v_e.amount IS DISTINCT FROM 1800 OR v_e.amount_currency IS DISTINCT FROM 'SM' THEN
    RAISE EXCEPTION 'case 9: a pending saldo line with an exact package count shows 1800 SM, got % %', v_e.amount, v_e.amount_currency; END IF;
  v_id := v_e.id;
  -- resolve: a payload without the cost still asks for it
  v_r := NULL;
  BEGIN
    PERFORM crm_resolve_pending_entry(v_id, '{"usdt_buy_gyd": 240}'::jsonb, 'assert saldo no cost');
    RAISE EXCEPTION 'case 9: a SALDO_MOVIL line was resolved without its cost';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM NOT LIKE '%saldo%' THEN RAISE EXCEPTION 'case 9: refused for another reason: %', SQLERRM; END IF;
  END;
  v_e := crm_resolve_pending_entry(v_id, '{"saldo_costo_usdt": 1.25}'::jsonb, 'assert saldo cost');
  IF v_e.status <> 'completed' OR v_e.amount <> 1800 OR v_e.amount_currency <> 'SM' OR v_e.facturado_gyd <> 5000 OR v_e.invertido_gyd <> 1512.5 OR v_e.retorno_gyd <> 3487.5
     OR v_e.cost_gyd <> 1.25 OR v_e.sale_gyd <> 1000 OR v_e.missing_inputs IS NOT NULL THEN
    RAISE EXCEPTION 'case 9: resolving with the cost shows 1800 SM and prices like the feed (5000 / 1512.5), got % % % %', v_e.status, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd; END IF;
  RAISE NOTICE 'PASS 9: a missing saldo cost is pending, resolvable with the cost, priced like the feed';

  -- ---- 10. not a whole multiple: pending, no silent rounding, and no rate fixes it ----
  PERFORM crm_set_calculator_rates(v_acc, '{"saldo_costo_usdt": 1.25}'::jsonb, NULL);
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230010', 'saldo', NULL, 5500, 'ready_to_transfer');
  PERFORM crm_cerrar_operacion_manual(v_op2);
  v_e := pg_temp.t223_line(v_op2);
  IF v_e.status IS DISTINCT FROM 'verified_pending' OR NOT ('saldoPaquetes' = ANY (v_e.missing_inputs))
     OR v_e.facturado_gyd IS NOT NULL OR v_e.invertido_gyd IS NOT NULL THEN
    RAISE EXCEPTION 'case 10: 5500 is not a whole number of packages: pending naming saldoPaquetes, got % %', v_e.status, v_e.missing_inputs; END IF;
  -- no exact package count: the raw deposit is shown as GYD, never as SM
  IF v_e.amount IS DISTINCT FROM 5500 OR v_e.amount_currency IS DISTINCT FROM 'GYD' THEN
    RAISE EXCEPTION 'case 10: a non-multiple deposit shows 5500 GYD, got % %', v_e.amount, v_e.amount_currency; END IF;
  BEGIN
    PERFORM crm_resolve_pending_entry(v_e.id, '{"saldo_costo_usdt": 1.25, "usdt_buy_gyd": 242}'::jsonb, 'assert saldo multiple');
    RAISE EXCEPTION 'case 10: a non-multiple saldo line was resolved with rates';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM NOT LIKE '%saldo%' THEN RAISE EXCEPTION 'case 10: refused for another reason: %', SQLERRM; END IF;
  END;
  RAISE NOTICE 'PASS 10: 5500 GYD stays pending (no silent rounding)';

  -- ---- 11. a pending RECARGA line is no longer priced as a USD service ----
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": null}'::jsonb, NULL);
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230011', 'recarga', NULL, 5200, 'ready_to_transfer');
  PERFORM pg_temp.t223_add(v_op2, jsonb_build_object('beneficiary_type', 'recarga', 'phone', v_ph), v_user);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  PERFORM crm_cerrar_operacion_manual(v_op2);
  v_e := pg_temp.t223_line(v_op2);
  IF v_e.service IS DISTINCT FROM 'RECARGA' OR v_e.status IS DISTINCT FROM 'verified_pending' OR NOT ('recargaCostoUsdt' = ANY (v_e.missing_inputs)) THEN
    RAISE EXCEPTION 'case 11: a recarga without cost is pending, got % % %', v_e.service, v_e.status, v_e.missing_inputs; END IF;
  BEGIN
    PERFORM crm_resolve_pending_entry(v_e.id, '{"usdt_sell_gyd": 260, "usdt_buy_gyd": 240}'::jsonb, 'assert recarga as usd');
    RAISE EXCEPTION 'case 11: a RECARGA line was priced with a USD sale rate and no recharge cost';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM NOT LIKE '%recarga%' THEN RAISE EXCEPTION 'case 11: refused for another reason: %', SQLERRM; END IF;
  END;
  v_e := crm_resolve_pending_entry(v_e.id, '{"recarga_costo_usdt": 23.1}'::jsonb, 'assert recarga cost');
  IF v_e.status <> 'completed' OR v_e.amount <> 1 OR v_e.amount_currency <> 'REC' OR v_e.facturado_gyd <> 5200 OR round(v_e.invertido_gyd, 1) <> 5590.2
     OR v_e.cost_gyd <> 23.1 OR v_e.sale_gyd <> 5200 OR v_e.usdt_sell_gyd <> 5200 THEN
    RAISE EXCEPTION 'case 11: a recarga resolved with its cost prices like the feed (1 unit, 5200 / 5590.2), got % % % %', v_e.status, v_e.amount, v_e.facturado_gyd, v_e.invertido_gyd; END IF;
  PERFORM crm_set_calculator_rates(v_acc, '{"recarga_costo_usdt": 23.1}'::jsonb, NULL);
  RAISE NOTICE 'PASS 11: RECARGA pending lines resolve with their own cost, not as a USD service';

  -- ---- 12. the rate payload carries the saldo cost and keeps the others ----
  PERFORM crm_set_calculator_rates(v_acc, '{"saldo_costo_usdt": 1.3}'::jsonb, NULL);
  IF (SELECT r.saldo_costo_usdt || '/' || r.usdt_buy_gyd || '/' || r.recarga_costo_usdt FROM calculator_rates_vigentes(v_acc) r) <> '1.3/242/23.1' THEN
    RAISE EXCEPTION 'case 12: the saldo cost must be stored and the other rates kept'; END IF;
  BEGIN
    PERFORM crm_set_calculator_rates(v_acc, '{"saldo_costo_usdt": 0}'::jsonb, NULL);
    RAISE EXCEPTION 'case 12: a zero saldo cost must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  PERFORM crm_set_calculator_rates(v_acc, '{"saldo_costo_usdt": 1.25}'::jsonb, NULL);
  RAISE NOTICE 'PASS 12: saldo_costo_usdt is a calculator rate';

  -- ---- 13. a saldo is not a recipient-less shipment: the "no recipient" alarm skips it ----
  IF (SELECT prosrc FROM pg_proc WHERE proname = 'cerebro_avisar_envios_sin_beneficiario') NOT LIKE '%''saldo''%' THEN
    RAISE EXCEPTION 'case 13: cerebro_avisar_envios_sin_beneficiario must skip saldo operations'; END IF;
  RAISE NOTICE 'PASS 13: the no-recipient alarm skips a saldo';

  -- ---- 14. other services are untouched (a spot check; the model assertions cover them) ----
  IF cerebro_riel_op(pg_temp.t223_op(v_user, v_acc, '59902230012', 'recarga', NULL, 5200)) <> 'recarga'
     OR cerebro_riel_op(pg_temp.t223_op(v_user, v_acc, '59902230013', 'visa', NULL, 5000)) <> 'visa'
     OR cerebro_minimo_gyd(pg_temp.t223_op(v_user, v_acc, '59902230014', 'recarga', NULL, 5200)) <> 5200 THEN
    RAISE EXCEPTION 'case 14: recarga and visa keep their rails and minimums'; END IF;
  RAISE NOTICE 'PASS 14: recarga and visa unchanged';

  -- ---- 15. refusals and privileges ----
  v_op2 := pg_temp.t223_op(v_user, v_acc, '59902230015', 'remesa', 'cuban_card', 5000, 'completed');
  BEGIN
    PERFORM pg_temp.t223_call(v_op2, 'saldo', v_user);
    RAISE EXCEPTION 'case 15: a completed operation must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  PERFORM set_config('request.jwt.claims', '', true);
  IF has_function_privilege('anon', 'cerebro_saldo_precio()', 'EXECUTE')
     OR has_function_privilege('anon', 'cerebro_saldo_paquetes(numeric)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_cambiar_servicio(uuid, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_agregar_beneficiario(uuid, jsonb)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_resolve_pending_entry(uuid, jsonb, text)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_set_calculator_rates(uuid, jsonb, uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 15: anon must not call the saldo functions'; END IF;
  IF NOT has_function_privilege('authenticated', 'cerebro_saldo_precio()', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'cerebro_saldo_paquetes(numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 15: authenticated and service_role call the saldo helpers'; END IF;
  RAISE NOTICE 'PASS 15: closed refused; anon cannot call the new functions';

  -- ---- 16. nothing was sent ----
  IF pg_temp.t223_side() <> v_base THEN
    RAISE EXCEPTION 'case 16: messages/outbox/net queue grew from % to %', v_base, pg_temp.t223_side(); END IF;
  RAISE NOTICE 'PASS 16: no messages, outbox rows or http requests';

  RAISE NOTICE 'ALL PASS (saldo-model)';
END $$;

ROLLBACK;
