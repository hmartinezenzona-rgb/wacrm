-- =====================================================================
-- Assertion for migration 213 (visa extensions as operations: deposit routing, panel, calculator). Self-reverting:
-- one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging (production after the owner's go-ahead).
--
-- odd/tasks/visa-end-to-end.md (T1). A visa extension is 5,000 GYD per person paid by MMG before; the customer sends
-- the receipt by WhatsApp and fills the online form himself, so a visa has no recipients. Its deposit must land on a
-- 'visa' operation (not a remesa), the panel must list it, and a completed visa feeds the calculator as VISA
-- (facturado = deposit, invertido = 0). "visa" alone is never enough: customers call the Clasica card "tarjeta Visa".
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.conv_t213(p_tag text, p_texts text[]) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_i int := 0; v_t text;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5992' || lpad(floor(random() * 10000000)::int::text, 7, '0'), 'test213' || p_tag) RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  FOREACH v_t IN ARRAY p_texts LOOP
    v_i := v_i + 1;
    INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
    VALUES (v_conv, 'customer', 'text', v_t, now() - make_interval(mins => 30 - v_i));
  END LOOP;
  RETURN v_conv;
END $$;
CREATE OR REPLACE FUNCTION pg_temp.ops_t213(p_conv uuid) RETURNS text
LANGUAGE sql AS $$
  SELECT coalesce(string_agg(o.service_type || '/' || o.status || '/' || o.quoted_source_amount::int, ';' ORDER BY o.created_at, o.service_type), '')
    FROM remittance_operations o WHERE o.conversation_id = p_conv;
$$;

DO $$
DECLARE
  v_conv uuid; v_conv2 uuid; v_op uuid; v_op2 uuid; v_e record; v_acc uuid; v_admin uuid; v_res text; v_n int; v_row record;
  v_phrase text; v_exp boolean;
  c_verif constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
BEGIN
  -- Staging keeps a fake promo: discard every one, then run the precedence cases with a live one of our own.
  UPDATE promo_etecsa SET estado = 'descartada' WHERE estado IN ('confirmada', 'detectada');
  INSERT INTO promo_etecsa (min_cup, max_cup, multiplicador, vigente_desde, vigente_hasta, titulo, url, texto_crudo, huella, estado)
  VALUES (600, 1250, 5, (now() AT TIME ZONE 'America/Guyana')::date - 1, (now() AT TIME ZONE 'America/Guyana')::date + 2,
          'ASSERT VIGENTE', 'https://assert.invalid/v', 'assert', md5('assert-vigente-213'), 'confirmada');
  SELECT w.account_id INTO v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  SELECT p.user_id INTO v_admin FROM profiles p WHERE p.account_id = v_acc AND p.account_role IN ('owner', 'admin') LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- 1. The customer asks for the visa extension, then deposits 5,000: a visa operation, no remesa.
  v_conv := pg_temp.conv_t213('01', ARRAY['hola', 'quiero hacer la extension de visa']);
  PERFORM cerebro_registrar_deposito(v_conv, 5000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv) <> 'visa/deposit_verification/5000' THEN
    RAISE EXCEPTION 'case 1: a visa conversation must open a visa operation, got %', pg_temp.ops_t213(v_conv); END IF;

  -- 2. "tarjeta Visa" is the Clasica card, never a visa extension: the deposit stays a remesa.
  v_conv2 := pg_temp.conv_t213('02', ARRAY['quiero mandar a una tarjeta visa clasica']);
  PERFORM cerebro_registrar_deposito(v_conv2, 6000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'remesa/deposit_verification/6000' THEN
    RAISE EXCEPTION 'case 2: a Clasica-card conversation must stay a remesa, got %', pg_temp.ops_t213(v_conv2); END IF;
  v_op2 := (SELECT id FROM remittance_operations WHERE conversation_id = v_conv2);

  -- 2b. The phrases (case and accent insensitive) and the non-phrases.
  FOR v_phrase, v_exp IN
    SELECT * FROM (VALUES
      ('Quiero la Extensión de la visa', true), ('quiero extension de visa', true), ('necesito EXTENDER la visa', true),
      ('quiero extender mi visa', true), ('mi visa vencida', true), ('mi visa se me vence', true), ('la visa se vence', true),
      ('mi visa por vencer', true), ('tengo que ir a Inmigración', true), ('inmigracion', true),
      ('https://acortar.link/extension_de_visa', true),
      ('visa', false), ('mi visa', false), ('quiero la tarjeta visa', false), ('tarjeta Visa Clasica', false),
      ('quiero mandar dinero', false)) AS t(p, e)
  LOOP
    v_conv2 := pg_temp.conv_t213('p' || md5(v_phrase), ARRAY[v_phrase]);
    IF cerebro_visa_en_curso(v_conv2) IS DISTINCT FROM v_exp THEN
      RAISE EXCEPTION 'case 2b: "%" must give % in cerebro_visa_en_curso', v_phrase, v_exp; END IF;
  END LOOP;
  -- 2c. A card pending next to the phrase: not a visa (the customer is sending a remesa).
  v_conv2 := pg_temp.conv_t213('2c', ARRAY['quiero la extension de visa']);
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, tarjeta) VALUES (v_conv2, '9225129912345678');
  IF cerebro_visa_en_curso(v_conv2) THEN RAISE EXCEPTION 'case 2c: a pending card must switch the text rule off'; END IF;
  DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv2;
  INSERT INTO cerebro_beneficiario_parcial (conversation_id, zelle_cuenta) VALUES (v_conv2, 'alguien@example.com');
  IF cerebro_visa_en_curso(v_conv2) THEN RAISE EXCEPTION 'case 2c: pending Zelle data must switch the text rule off'; END IF;
  DELETE FROM cerebro_beneficiario_parcial WHERE conversation_id = v_conv2;

  -- 3. The agent tool: opens the visa for N people (5,000 each), updates the people, never duplicates.
  IF has_function_privilege('authenticated', 'crm_abrir_visa(uuid, integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_abrir_visa(uuid, integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'crm_abrir_visa(uuid, integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 3: crm_abrir_visa is for service_role only'; END IF;
  v_conv := pg_temp.conv_t213('03', ARRAY['hola buenas']);
  v_res := crm_abrir_visa(v_conv, 2);
  IF pg_temp.ops_t213(v_conv) <> 'visa/collecting_information/10000' THEN
    RAISE EXCEPTION 'case 3: crm_abrir_visa(2) must open a visa of 10000, got %', pg_temp.ops_t213(v_conv); END IF;
  IF v_res NOT LIKE '%2 personas%' OR v_res NOT LIKE '%10,000 GYD%' OR v_res NOT LIKE '%MMG%' THEN
    RAISE EXCEPTION 'case 3: the instruction names people, total and MMG, got %', v_res; END IF;
  SELECT * INTO v_row FROM remittance_operations WHERE conversation_id = v_conv;
  IF v_row.source_currency IS DISTINCT FROM 'GYD' OR v_row.status IS DISTINCT FROM 'collecting_information' THEN
    RAISE EXCEPTION 'case 3: the visa opens in GYD, collecting_information'; END IF;
  v_op := v_row.id;
  PERFORM crm_abrir_visa(v_conv, 3);
  IF pg_temp.ops_t213(v_conv) <> 'visa/collecting_information/15000' THEN
    RAISE EXCEPTION 'case 3: crm_abrir_visa(3) updates the same visa to 15000, got %', pg_temp.ops_t213(v_conv); END IF;
  PERFORM crm_abrir_visa(v_conv);
  IF pg_temp.ops_t213(v_conv) <> 'visa/collecting_information/15000' THEN
    RAISE EXCEPTION 'case 3: crm_abrir_visa without people leaves the amount, got %', pg_temp.ops_t213(v_conv); END IF;
  PERFORM crm_abrir_visa(v_conv, 2);
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_visa_registered') THEN
    RAISE EXCEPTION 'case 3: the tool audits'; END IF;
  -- 3b. Without people: one person.
  v_conv2 := pg_temp.conv_t213('3b', ARRAY['hola']);
  PERFORM crm_abrir_visa(v_conv2);
  IF pg_temp.ops_t213(v_conv2) <> 'visa/collecting_information/5000' THEN
    RAISE EXCEPTION 'case 3b: one person by default, got %', pg_temp.ops_t213(v_conv2); END IF;
  -- 3c. The panel lock on the amount wins.
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('quoted_source_amount', jsonb_build_object('by', 'x', 'at', now()))
   WHERE conversation_id = v_conv2;
  PERFORM crm_abrir_visa(v_conv2, 4);
  IF pg_temp.ops_t213(v_conv2) <> 'visa/collecting_information/5000' THEN
    RAISE EXCEPTION 'case 3c: the panel lock on the amount must hold, got %', pg_temp.ops_t213(v_conv2); END IF;

  -- 4. A deposit with the visa open lands on it (movido), with no text about visa at all. The amount is the deposit.
  PERFORM cerebro_registrar_deposito(v_conv, 10000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv) <> 'visa/deposit_verification/10000' THEN
    RAISE EXCEPTION 'case 4: the deposit must land on the open visa, got %', pg_temp.ops_t213(v_conv); END IF;
  IF (SELECT count(*) FROM remittance_operations WHERE conversation_id = v_conv) <> 1 THEN
    RAISE EXCEPTION 'case 4: no second operation'; END IF;
  -- 4b. A visa the tool opened with no amount typed ("collecting", people unknown) takes the deposit as its amount.
  v_conv2 := pg_temp.conv_t213('4b', ARRAY['hola']);
  PERFORM crm_abrir_visa(v_conv2);
  PERFORM cerebro_registrar_deposito(v_conv2, 15000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'visa/deposit_verification/15000' THEN
    RAISE EXCEPTION 'case 4b: the deposit is the amount of the visa, got %', pg_temp.ops_t213(v_conv2); END IF;

  -- 5. Precedence: the OPEN operation wins; with nothing open: recarga > combo > visa.
  v_conv2 := pg_temp.conv_t213('5a', ARRAY['quiero la extension de visa', 'y tambien una recarga']);
  PERFORM cerebro_registrar_deposito(v_conv2, 6200, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'recarga/deposit_verification/6200' THEN
    RAISE EXCEPTION 'case 5a: text only, recarga beats visa, got %', pg_temp.ops_t213(v_conv2); END IF;
  v_conv2 := pg_temp.conv_t213('5b', ARRAY['quiero la extension de visa', 'y tambien un combo']);
  PERFORM cerebro_registrar_deposito(v_conv2, 25000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'combo/deposit_verification/25000' THEN
    RAISE EXCEPTION 'case 5b: text only, combo beats visa, got %', pg_temp.ops_t213(v_conv2); END IF;
  v_conv2 := pg_temp.conv_t213('5c', ARRAY['quiero una recarga', 'y un combo']);
  PERFORM crm_abrir_visa(v_conv2, 1);
  PERFORM cerebro_registrar_deposito(v_conv2, 5000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'visa/deposit_verification/5000' THEN
    RAISE EXCEPTION 'case 5c: an open visa beats recarga and combo text, got %', pg_temp.ops_t213(v_conv2); END IF;
  v_conv2 := pg_temp.conv_t213('5d', ARRAY['quiero la extension de visa']);
  PERFORM crm_registrar_destinatario_combo(v_conv2, 'Ana Gil', '53111222', NULL, NULL, NULL, NULL);
  PERFORM cerebro_registrar_deposito(v_conv2, 25000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'combo/deposit_verification/25000' THEN
    RAISE EXCEPTION 'case 5d: an open combo beats visa text, got %', pg_temp.ops_t213(v_conv2); END IF;
  v_conv2 := pg_temp.conv_t213('5e', ARRAY['hola']);
  PERFORM crm_abrir_visa(v_conv2, 1);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  SELECT v.account_id, v.id, v.contact_id, 'collecting_information', 'recarga', 'GYD', 0 FROM conversations v WHERE v.id = v_conv2;
  PERFORM cerebro_registrar_deposito(v_conv2, 6200, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'recarga/deposit_verification/6200;visa/collecting_information/5000' THEN
    RAISE EXCEPTION 'case 5e: with both open the recarga wins, got %', pg_temp.ops_t213(v_conv2); END IF;
  -- 5f. Plain conversations behave as before: remesa stays a remesa, a recarga text still goes to recarga.
  v_conv2 := pg_temp.conv_t213('5f', ARRAY['quiero mandar dinero a mi mama']);
  PERFORM cerebro_registrar_deposito(v_conv2, 7000, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'remesa/deposit_verification/7000' THEN
    RAISE EXCEPTION 'case 5f: a plain conversation stays a remesa, got %', pg_temp.ops_t213(v_conv2); END IF;
  v_conv2 := pg_temp.conv_t213('5g', ARRAY['quiero una recarga']);
  PERFORM cerebro_registrar_deposito(v_conv2, 6200, 'GYD', c_verif, NULL, NULL);
  IF pg_temp.ops_t213(v_conv2) <> 'recarga/deposit_verification/6200' THEN
    RAISE EXCEPTION 'case 5g: a recarga conversation stays a recarga, got %', pg_temp.ops_t213(v_conv2); END IF;

  -- 6. Minimum and rail of a visa: 5,000 GYD, rail 'visa'.
  IF cerebro_riel_op(v_op) IS DISTINCT FROM 'visa' OR cerebro_minimo_gyd(v_op) IS DISTINCT FROM 5000 THEN
    RAISE EXCEPTION 'case 6: the visa has its own rail and a 5000 minimum, got % / %', cerebro_riel_op(v_op), cerebro_minimo_gyd(v_op); END IF;

  -- 7. Typed Cuban numbers and the remesa tools never write on a visa (they used to hit the combo the same way).
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text) VALUES (v_conv, 'customer', 'text', '53845687');
  SELECT accion INTO v_res FROM cerebro_guardar_beneficiario_auto(v_conv, '', '53845687', '', '53845687', 'assert213');
  IF v_res NOT ILIKE '%visa%' THEN RAISE EXCEPTION 'case 7: the auto registration must say a visa is open, got %', v_res; END IF;
  PERFORM cerebro_guardar_beneficiario_auto(v_conv, '9225129912345678', '53845687', '9225129912345678', '53845687', 'assert213');
  PERFORM cerebro_escribir_bloque_beneficiario(v_conv, v_op, E'Tarjeta: 9227069999999999\nCelular: 53845687');
  PERFORM cerebro_escribir_bloque_beneficiario(v_conv, NULL, E'Tarjeta: 9227069999999999\nCelular: 53845687');
  PERFORM cerebro_guardar_beneficiario(v_conv, 'X', '', '53845687', 'assert213', v_op, 'assert');
  IF EXISTS (SELECT 1 FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id WHERE o.conversation_id = v_conv) THEN
    RAISE EXCEPTION 'case 7: a remesa writer put a beneficiary on the visa conversation'; END IF;
  IF pg_temp.ops_t213(v_conv) <> 'visa/deposit_verification/10000' THEN
    RAISE EXCEPTION 'case 7: a typed number opened another operation, got %', pg_temp.ops_t213(v_conv); END IF;

  -- 8. Completeness: a visa needs no recipients. A remesa with no beneficiary is still incomplete.
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 8: a visa is complete without recipients'; END IF;
  IF crm_beneficiarios_completos(v_op2) THEN RAISE EXCEPTION 'case 8: a remesa without beneficiary stays incomplete'; END IF;

  -- 9. The panel lists the visa once, with no beneficiary row; the remesa next to it still lists.
  SELECT count(*) INTO v_n FROM crm_operaciones_de_conversacion(v_conv);
  SELECT * INTO v_row FROM crm_operaciones_de_conversacion(v_conv) LIMIT 1;
  IF v_n <> 1 OR v_row.operation_id IS DISTINCT FROM v_op OR v_row.operation_service_type IS DISTINCT FROM 'visa'
     OR v_row.beneficiary_id IS NOT NULL OR v_row.operation_beneficiaries_complete IS DISTINCT FROM true
     OR v_row.operation_quoted_source_amount IS DISTINCT FROM 10000 OR v_row.operation_is_history THEN
    RAISE EXCEPTION 'case 9: the panel must list the visa once with no beneficiary, got % rows: % % % % %',
      v_n, v_row.operation_service_type, v_row.beneficiary_id, v_row.operation_beneficiaries_complete, v_row.operation_quoted_source_amount, v_row.operation_is_history; END IF;

  -- 10. Completing the visa writes ONE VISA line: facturado = the deposit, invertido = 0, never pending.
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op;
  PERFORM crm_cerrar_operacion_manual(v_op);
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void';
  IF v_n <> 1 OR v_e.service IS DISTINCT FROM 'VISA' OR v_e.status IS DISTINCT FROM 'completed' OR v_e.missing_inputs IS NOT NULL THEN
    RAISE EXCEPTION 'case 10: expected ONE completed VISA line, got % lines: % % %', v_n, v_e.service, v_e.status, v_e.missing_inputs; END IF;
  IF v_e.facturado_gyd IS DISTINCT FROM 10000 OR v_e.invertido_gyd IS DISTINCT FROM 0 OR v_e.retorno_gyd IS DISTINCT FROM 10000
     OR v_e.amount IS DISTINCT FROM 10000 OR v_e.amount_currency IS DISTINCT FROM 'GYD' OR v_e.basis_gyd IS DISTINCT FROM 10000 THEN
    RAISE EXCEPTION 'case 10: expected 10000 / 0 / 10000 in GYD, got % / % / % amount % %',
      v_e.facturado_gyd, v_e.invertido_gyd, v_e.retorno_gyd, v_e.amount, v_e.amount_currency; END IF;
  IF v_e.cost_gyd IS DISTINCT FROM 0 OR v_e.sale_gyd IS DISTINCT FROM 10000
     OR v_e.cup_global_rate IS NOT NULL OR v_e.cup_rate IS NOT NULL OR v_e.usdt_buy_gyd IS NOT NULL OR v_e.usdt_sell_gyd IS NOT NULL THEN
    RAISE EXCEPTION 'case 10: the VISA line snapshots cost 0 / sale = deposit and no rate'; END IF;
  -- The same completion again never duplicates the line.
  PERFORM calculator_feed_operation(v_op);
  IF (SELECT count(*) FROM remittance_calculator_entries WHERE operation_id = v_op AND status <> 'void') <> 1 THEN
    RAISE EXCEPTION 'case 10: re-feeding a visa must not duplicate its line'; END IF;
  -- The panel lists it as history, still with no beneficiary row.
  SELECT * INTO v_row FROM crm_operaciones_de_conversacion(v_conv) LIMIT 1;
  IF v_row.operation_id IS DISTINCT FROM v_op OR v_row.operation_is_history IS NOT TRUE OR v_row.operation_status <> 'completed' THEN
    RAISE EXCEPTION 'case 10: the completed visa appears in the panel history'; END IF;
  -- 10b. calculator_missing_rates asks for no rate.
  IF coalesce(array_length(calculator_missing_rates('VISA', NULL::calculator_rate_versions), 1), 0) <> 0 THEN
    RAISE EXCEPTION 'case 10b: VISA asks for no rate'; END IF;

  -- 11. The manual-close picker accepts 'visa': a remesa without beneficiary (the 6,000 "tarjeta visa" case, filed as a
  -- remesa today) is closed as a visa and the calculator prices it as VISA.
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op2;
  PERFORM crm_cerrar_operacion_manual(v_op2, NULL, false, 'visa');
  SELECT * INTO v_row FROM remittance_operations WHERE id = v_op2;
  IF v_row.service_type IS DISTINCT FROM 'visa' OR v_row.status IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'case 11: the picker must set service_type visa, got % %', v_row.service_type, v_row.status; END IF;
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE operation_id = v_op2 AND status <> 'void';
  IF v_e.service IS DISTINCT FROM 'VISA' OR v_e.facturado_gyd IS DISTINCT FROM 6000 OR v_e.invertido_gyd IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'case 11: the picked visa feeds VISA 6000 / 0, got % % %', v_e.service, v_e.facturado_gyd, v_e.invertido_gyd; END IF;

  -- 12. crm_resolve_pending_entry refuses VISA lines (their status never needs rates).
  v_conv2 := pg_temp.conv_t213('12', ARRAY['hola']);
  PERFORM crm_abrir_visa(v_conv2, 1);
  SELECT id INTO v_op2 FROM remittance_operations WHERE conversation_id = v_conv2;
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, service, amount, amount_currency, missing_inputs, completed_at)
  VALUES (v_acc, 'completed_operation', 'verified_pending', v_op2, current_date, 'VISA', 5000, 'GYD', ARRAY['x'], now())
  RETURNING * INTO v_e;
  BEGIN
    PERFORM crm_resolve_pending_entry(v_e.id, '{"usdt_buy_gyd": 230}'::jsonb, 'assert visa resolve');
    RAISE EXCEPTION 'case 12: a VISA line was resolved with rates';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    IF SQLERRM NOT LIKE '%visa%' THEN RAISE EXCEPTION 'case 12: refused for another reason: %', SQLERRM; END IF;
  END;

  -- 13. The assistant takes the order: the service row says so and stays bot-handled; the price and link are kept.
  IF NOT EXISTS (SELECT 1 FROM cerebro_servicios s WHERE s.clave = 'visa' AND NOT s.requiere_humano AND s.activo
                   AND s.hechos LIKE '%5,000 GYD%' AND s.hechos LIKE '%20,000 GYD%' AND s.hechos LIKE '%PROHIBIDO ofrecer rebajas%'
                   AND s.enlace = 'https://acortar.link/extension_de_visa' AND s.hechos LIKE '%TOMA el pedido%') THEN
    RAISE EXCEPTION 'case 13: the visa service row must keep its facts and say the assistant takes the order'; END IF;

  -- 14. A verified visa has no recipient by design: the "no recipient" alarm leaves it alone.
  IF (SELECT prosrc FROM pg_proc WHERE proname = 'cerebro_avisar_envios_sin_beneficiario') NOT LIKE '%''visa''%' THEN
    RAISE EXCEPTION 'case 14: cerebro_avisar_envios_sin_beneficiario must skip visa operations'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
