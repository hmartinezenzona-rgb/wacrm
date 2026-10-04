-- =====================================================================
-- Assertion for migration 208 (the food combo operation: recipients, cost, panel RPCs). Self-reverting: one DO block
-- that ends in RAISE EXCEPTION 'ALL PASS'. Runs on staging (and production after the owner's go-ahead).
--
-- odd/tasks/combos-end-to-end.md (T1a). A combo is one operation with several recipients (as a recharge has several
-- numbers); each recipient has name, phone, address, reference, contact phone and an amount of at least 25,000 GYD.
-- The bot sends the fields over several messages; the panel lists, adds to and closes the combo; the admin enters
-- the cost by hand.
-- =====================================================================
DO $$
DECLARE
  v_user  uuid;
  v_acc   uuid;
  v_ct    uuid;
  v_conv  uuid;
  v_op    uuid;
  v_op2   uuid;
  v_res   text;
  v_n     int;
  v_sum   numeric;
  v_ok    boolean;
  v_r     record;
  v_j     jsonb;
BEGIN
  -- A fresh conversation of the business account (staging can have none after a reset).
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990020801', 'test208') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- 1. Opening a combo with a first, partial recipient: the operation opens (GYD, collecting information), one row,
  --    and the reply lists what is missing for that recipient.
  v_res := crm_registrar_destinatario_combo(v_conv, 'Maria Perez', '53871234', NULL, NULL, NULL, NULL);
  SELECT o.id INTO v_op FROM remittance_operations o
   WHERE o.conversation_id = v_conv AND o.service_type = 'combo' AND o.status NOT IN ('completed', 'cancelled');
  IF v_op IS NULL THEN RAISE EXCEPTION 'case 1: the combo did not open (reply: %)', v_res; END IF;
  SELECT status, source_currency INTO v_r FROM remittance_operations WHERE id = v_op;
  IF v_r.status <> 'collecting_information' OR v_r.source_currency <> 'GYD' THEN
    RAISE EXCEPTION 'case 1: status % currency %', v_r.status, v_r.source_currency; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'combo') <> 1 THEN
    RAISE EXCEPTION 'case 1: expected one combo recipient'; END IF;
  -- Owner 2026-10-04: only the recipient's phone is asked for; a second contact phone is never asked for.
  IF v_res NOT LIKE '%FALTA:%direccion%de Maria Perez%' OR v_res NOT LIKE '%referencia%' OR v_res LIKE '%contacto%' THEN
    RAISE EXCEPTION 'case 1: the reply must list what is missing, got %', v_res; END IF;
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 1: a partial recipient must not be complete'; END IF;
  -- The same call is idempotent: no second recipient, no second operation.
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Maria Perez', '53871234', NULL, NULL, NULL, NULL);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 1
     OR (SELECT count(*) FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'combo') <> 1 THEN
    RAISE EXCEPTION 'case 1: a repeat must not duplicate'; END IF;
  -- Audited with the new action.
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_combo_recipient_registered') THEN
    RAISE EXCEPTION 'case 1: the audit row is missing'; END IF;

  -- 2. Completing it over a second call, matched by phone, without losing the fields already stored (empty args do
  --    not overwrite). An amount below the minimum is reported.
  v_res := crm_registrar_destinatario_combo(v_conv, NULL, '53871234', 'Calle 10 #45 e/ 3ra y 5ta, Vedado', 'Frente a la bodega azul', NULL, 20000);
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_r.name <> 'Maria Perez' OR v_r.phone <> '53871234' OR v_r.address <> 'Calle 10 #45 e/ 3ra y 5ta, Vedado'
     OR v_r.reference <> 'Frente a la bodega azul' OR v_r.amount <> 20000 OR v_r.currency <> 'GYD' OR v_r.beneficiary_type <> 'combo' THEN
    RAISE EXCEPTION 'case 2: fields lost or not stored: %', to_jsonb(v_r); END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 1 THEN
    RAISE EXCEPTION 'case 2: the second call must update the same recipient'; END IF;
  IF v_res NOT LIKE '%el minimo por combo es 25,000 GYD%' THEN RAISE EXCEPTION 'case 2: the minimum rule is not stated: %', v_res; END IF;
  IF v_res LIKE '%contacto%' THEN RAISE EXCEPTION 'case 2: a contact phone must not be asked for: %', v_res; END IF;
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 2: below the minimum is not complete'; END IF;
  -- 2b. A valid amount, but the address names no province (owner 2026-10-04: the delivery time and the admin need
  --     it): still incomplete, and the reply asks for the province.
  v_res := crm_registrar_destinatario_combo(v_conv, NULL, '53871234', NULL, NULL, NULL, 25000);
  IF v_res NOT LIKE '%FALTA:%provincia%de Maria Perez%' OR crm_beneficiarios_completos(v_op) THEN
    RAISE EXCEPTION 'case 2b: an address without province must be incomplete and ask for it, got %', v_res; END IF;
  -- 2c. With the province in the address it is complete, WITHOUT a second contact phone.
  v_res := crm_registrar_destinatario_combo(v_conv, NULL, '53871234', 'Calle 10 #45 e/ 3ra y 5ta, Vedado, La Habana', NULL, NULL, NULL);
  IF v_res NOT LIKE 'Datos completos. Total a pagar: 25,000 GYD%' OR NOT crm_beneficiarios_completos(v_op) THEN
    RAISE EXCEPTION 'case 2c: complete with province and without a contact phone, got %', v_res; END IF;
  IF cerebro_combo_provincia('calle 40 entre 30/45, Santa Fe') IS NOT NULL
     OR cerebro_combo_provincia('Reparto Pedro Diaz, Holguín') IS DISTINCT FROM 'Holguín'
     OR cerebro_combo_provincia('Vedado, LA HABANA') IS DISTINCT FROM 'La Habana'
     OR cerebro_combo_provincia('Santiago de Cuba') IS DISTINCT FROM 'Santiago de Cuba' THEN
    RAISE EXCEPTION 'case 2c: province reading is wrong'; END IF;

  -- 3. Completeness false, then true: the contact phone and a valid amount close the gap. A phone with +53 and
  --    separators is stored normalised. quoted_source_amount follows the amount.
  v_res := crm_registrar_destinatario_combo(v_conv, 'Maria Perez', '53871234', NULL, NULL, '+53 5222 3344', 25000);
  IF v_res NOT LIKE 'Datos completos. Total a pagar: 25,000 GYD%' THEN RAISE EXCEPTION 'case 3: got %', v_res; END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 3: the combo must be complete'; END IF;
  IF (SELECT contact_phone FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> '52223344' THEN
    RAISE EXCEPTION 'case 3: the contact phone must be stored as digits'; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 25000 THEN
    RAISE EXCEPTION 'case 3: quoted_source_amount must be 25000'; END IF;

  -- 4. A second recipient (new row), found later by NAME while it has no phone; quoted_source_amount = the sum.
  v_res := crm_registrar_destinatario_combo(v_conv, 'Juan Lopez', NULL, NULL, NULL, NULL, 30000);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 2 THEN
    RAISE EXCEPTION 'case 4: expected two recipients'; END IF;
  IF crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 4: the second recipient is incomplete'; END IF;
  IF v_res NOT LIKE '%FALTA:%telefono%de Juan Lopez%' THEN RAISE EXCEPTION 'case 4: got %', v_res; END IF;
  IF v_res LIKE '%Datos completos%' THEN RAISE EXCEPTION 'case 4: must not say complete: %', v_res; END IF;
  v_res := crm_registrar_destinatario_combo(v_conv, 'juan lopez', '53998877', 'Calle Real 12, Matanzas', 'Casa verde al lado de la iglesia', '53112233', NULL);
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 2 THEN
    RAISE EXCEPTION 'case 4: the name must match the same recipient, not add a third'; END IF;
  SELECT sum(amount) INTO v_sum FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_sum <> 55000 OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 55000 THEN
    RAISE EXCEPTION 'case 4: sum % / quoted %', v_sum, (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op); END IF;
  IF v_res NOT LIKE 'Datos completos. Total a pagar: 55,000 GYD%' THEN RAISE EXCEPTION 'case 4: got %', v_res; END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 4: both recipients are complete'; END IF;

  -- 5. Other branches are untouched: an operation with no recipients is not complete, a remesa keeps the card rule.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO v_op2;
  IF crm_beneficiarios_completos(v_op2) THEN RAISE EXCEPTION 'case 5: an empty remesa is not complete'; END IF;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op2, 'cuban_card', '9235123487781111', '53871234', 1, 1, 'test', 'vigente');
  IF NOT crm_beneficiarios_completos(v_op2) THEN RAISE EXCEPTION 'case 5: a remesa with card and phone is complete'; END IF;
  DELETE FROM remittance_beneficiaries WHERE operation_id = v_op2;
  DELETE FROM remittance_operations WHERE id = v_op2;

  -- 6. The panel lists the combo (open) with every recipient field and the cost column.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  SELECT count(*) INTO v_n FROM crm_operaciones_de_conversacion(v_conv) WHERE operation_id = v_op AND operation_service_type = 'combo';
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 6: the panel must list the combo with 2 recipients, got %', v_n; END IF;
  SELECT * INTO v_r FROM crm_operaciones_de_conversacion(v_conv)
   WHERE operation_id = v_op AND beneficiary_name = 'Maria Perez';
  IF v_r.beneficiary_type <> 'combo' OR v_r.beneficiary_phone <> '53871234' OR v_r.beneficiary_address <> 'Calle 10 #45 e/ 3ra y 5ta, Vedado, La Habana'
     OR v_r.beneficiary_reference <> 'Frente a la bodega azul' OR v_r.beneficiary_contact_phone <> '52223344'
     OR v_r.beneficiary_amount <> 25000 OR v_r.beneficiary_currency <> 'GYD' OR v_r.operation_beneficiaries_complete IS NOT TRUE
     OR v_r.operation_combo_costo_gyd IS NOT NULL THEN
    RAISE EXCEPTION 'case 6: the panel row is wrong: %', to_jsonb(v_r); END IF;

  -- 7. The admin enters the cost: stored, audited, refused for a negative number, a remesa, or a non-admin.
  v_j := crm_set_combo_costo(v_op, 41500.5);
  IF (SELECT combo_costo_gyd FROM remittance_operations WHERE id = v_op) <> 41500.5 THEN
    RAISE EXCEPTION 'case 7: the cost was not stored'; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'human_combo_cost_set'
                  AND (after ->> 'combo_costo_gyd')::numeric = 41500.5) THEN
    RAISE EXCEPTION 'case 7: the audit row is missing'; END IF;
  IF (SELECT operation_combo_costo_gyd FROM crm_operaciones_de_conversacion(v_conv) WHERE operation_id = v_op LIMIT 1) <> 41500.5 THEN
    RAISE EXCEPTION 'case 7: the panel must return the cost'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_set_combo_costo(v_op, -1); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7: a negative cost must be refused'; END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO v_op2;
  v_ok := false;
  BEGIN PERFORM crm_set_combo_costo(v_op2, 10); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7: a cost on a remesa must be refused'; END IF;
  v_ok := false;
  BEGIN PERFORM crm_set_combo_costo(gen_random_uuid(), 10); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = 'P0002'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7: an unknown operation must be P0002'; END IF;
  -- a caller who is not a member of the account
  PERFORM set_config('request.jwt.claims', json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
  v_ok := false;
  BEGIN PERFORM crm_set_combo_costo(v_op, 10); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '42501'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 7: a stranger must get 42501'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  DELETE FROM remittance_operations WHERE id = v_op2;

  -- 8. The panel adds a recipient by hand: it locks the beneficiaries, so the bot can no longer change them.
  v_j := crm_agregar_beneficiario(v_op, jsonb_build_object('beneficiary_type', 'combo', 'name', 'Ana Gomez', 'phone', '53445566',
           'address', 'Av 5ta 100, Pinar del Rio', 'reference', 'Esquina de la farmacia', 'contact_phone', '53667788',
           'amount', 26000, 'currency', 'GYD'));
  IF (v_j ->> 'id') IS NULL OR (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 3 THEN
    RAISE EXCEPTION 'case 8: the recipient was not added: %', v_j; END IF;
  SELECT * INTO v_r FROM remittance_beneficiaries WHERE id = (v_j ->> 'id')::uuid;
  IF v_r.beneficiary_type <> 'combo' OR v_r.name <> 'Ana Gomez' OR v_r.address <> 'Av 5ta 100, Pinar del Rio'
     OR v_r.reference <> 'Esquina de la farmacia' OR v_r.contact_phone <> '53667788' OR v_r.amount <> 26000 OR v_r.currency <> 'GYD' THEN
    RAISE EXCEPTION 'case 8: fields: %', to_jsonb(v_r); END IF;
  IF (v_j ->> 'complete')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'case 8: complete expected: %', v_j; END IF;
  -- a card cannot go on a combo, and a combo recipient cannot go on a remesa
  v_ok := false;
  BEGIN PERFORM crm_agregar_beneficiario(v_op, '{"beneficiary_type": "cuban_card", "card_number": "9235123487781111", "amount": 1, "currency": "CUP"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 8: a card on a combo must be refused'; END IF;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'collecting_information', 'remesa', 'GYD', 0) RETURNING id INTO v_op2;
  v_ok := false;
  BEGIN PERFORM crm_agregar_beneficiario(v_op2, '{"beneficiary_type": "combo", "name": "X", "phone": "53445566", "amount": 25000, "currency": "GYD"}'::jsonb);
  EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 8: a combo recipient on a remesa must be refused'; END IF;
  DELETE FROM remittance_operations WHERE id = v_op2;
  -- the panel lock: the bot's function now changes nothing
  v_res := crm_registrar_destinatario_combo(v_conv, 'Pedro Nuevo', '53000111', 'x', 'y', 'z', 99999);
  IF v_res NOT LIKE '%persona desde el panel%' THEN RAISE EXCEPTION 'case 8: the lock must be respected: %', v_res; END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') <> 3 THEN
    RAISE EXCEPTION 'case 8: the lock did not stop the write'; END IF;

  -- 9. Manual close with the picker 'combo': a verified remesa with no recipient becomes a combo.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 30000) RETURNING id INTO v_op2;
  PERFORM crm_cerrar_operacion_manual(v_op2, NULL, false, 'combo');
  SELECT service_type AS t, delivery_method AS m, status AS s INTO v_r FROM remittance_operations WHERE id = v_op2;
  IF v_r.t IS DISTINCT FROM 'combo' OR v_r.m IS NOT NULL OR v_r.s <> 'completed' THEN
    RAISE EXCEPTION 'case 9: expected combo / no method / completed, got % / % / %', v_r.t, v_r.m, v_r.s; END IF;
  -- an unknown service is still refused
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 30000) RETURNING id INTO v_op2;
  v_ok := false;
  BEGIN PERFORM crm_cerrar_operacion_manual(v_op2, NULL, false, 'visa'); EXCEPTION WHEN OTHERS THEN v_ok := SQLSTATE = '22023'; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'case 9: an unknown service must be refused'; END IF;

  -- 10. A completed combo stays in the panel history; the service text no longer hands the payment to a person.
  PERFORM crm_cerrar_operacion_manual(v_op2, NULL, false, 'combo');
  IF NOT EXISTS (SELECT 1 FROM crm_operaciones_de_conversacion(v_conv) WHERE operation_id = v_op2 AND operation_is_history) THEN
    RAISE EXCEPTION 'case 10: a completed combo must appear in the history'; END IF;
  SELECT hechos, requiere_humano INTO v_r FROM cerebro_servicio_get('combos');
  IF v_r.hechos LIKE '%NO gestiona todavia el pago%' OR v_r.hechos NOT LIKE '%25,000 GYD%' OR v_r.hechos NOT LIKE '%MMG%'
     OR v_r.hechos NOT LIKE '%llamada con una persona del equipo%' OR v_r.hechos LIKE '%otra persona de contacto%'
     OR v_r.requiere_humano THEN
    RAISE EXCEPTION 'case 10: the combos text is wrong: %', v_r.hechos; END IF;

  -- 11. Access: the bot function is for service_role only; the panel RPCs are for authenticated.
  IF has_function_privilege('authenticated', 'crm_registrar_destinatario_combo(uuid,text,text,text,text,text,numeric,integer)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_registrar_destinatario_combo(uuid,text,text,text,text,text,numeric,integer)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'crm_registrar_destinatario_combo(uuid,text,text,text,text,text,numeric,integer)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 11: wrong ACL on crm_registrar_destinatario_combo'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_set_combo_costo(uuid,numeric)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_set_combo_costo(uuid,numeric)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 11: wrong ACL on crm_set_combo_costo'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_operaciones_de_conversacion(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'crm_operaciones_de_conversacion(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 11: wrong ACL on crm_operaciones_de_conversacion'; END IF;

  -- 12. Owner test 2026-10-04: "dos combos, uno de 30 mil y otro de 25 mil", said before any name. The agent
  -- numbers the combos in the order the customer said them; each call goes to its own recipient (it used to
  -- overwrite the latest one, leaving one recipient of 25,000).
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990020812', 'test208b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM crm_registrar_destinatario_combo(v_conv, '', '', '', '', '', 30000, 1);
  v_res := crm_registrar_destinatario_combo(v_conv, '', '', '', '', '', 25000, 2);
  IF (SELECT string_agg(b.position || ':' || b.amount::int, ',' ORDER BY b.position)
        FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
       WHERE o.conversation_id = v_conv AND b.status = 'vigente' AND b.beneficiary_type = 'combo') IS DISTINCT FROM '1:30000,2:25000'
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE conversation_id = v_conv AND service_type = 'combo') <> 55000 THEN
    RAISE EXCEPTION 'case 12: two numbered combos must be two recipients totalling 55000, got %', v_res; END IF;
  -- the data of combo 2 then lands on combo 2, and combo 1 keeps its amount
  PERFORM crm_registrar_destinatario_combo(v_conv, 'Rosa Diaz', '53711122', 'Calle 2, Holguin', '', '', NULL, 2);
  IF (SELECT string_agg(coalesce(b.name, '-') || ':' || b.amount::int, ',' ORDER BY b.position)
        FROM remittance_beneficiaries b JOIN remittance_operations o ON o.id = b.operation_id
       WHERE o.conversation_id = v_conv AND b.status = 'vigente' AND b.beneficiary_type = 'combo') IS DISTINCT FROM '-:30000,Rosa Diaz:25000' THEN
    RAISE EXCEPTION 'case 12: the data of combo 2 went elsewhere'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
