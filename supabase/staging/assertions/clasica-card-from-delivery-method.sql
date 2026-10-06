-- =====================================================================
-- Assertion for migration 221 (a card for a Clasica/Tropical operation is stored as that rail).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Production 2026-10-06 (operation 45dde511): the bot called cerebro_marcar_destino_usd('clasica'), which sets
-- remittance_operations.delivery_method but writes no cerebro_destino_pendiente row; the card then came through
-- cerebro_registrar_beneficiario_auto (always 'cuban_card') and 157's re-type trigger, which only reads the pending
-- row, left it as a CUP card (5,200 GYD priced as 15,600 CUP). Any failure RAISEs; each passing case NOTICEs.
-- Rates are read from crm_tasa_vigente, so the expectations follow staging's rates.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_stage constant uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_ct uuid; v_conv uuid; v_op uuid; v_r record;
  v_tipo text; v_cur text; v_amt numeric; v_dest text; v_n int;
BEGIN
  IF NOT (v_usd > 0 AND v_cup > 0) THEN RAISE EXCEPTION 'setup: both rates are needed (usd %, cup %)', v_usd, v_cup; END IF;
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- ---- a. Clasica: deposit, marcar_destino_usd (no pending row), then the card ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210001', 'test221 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 5200, 'GYD', v_stage, 'test221 a', NULL);
  PERFORM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec221-a');
  IF EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv AND tipo <> 'clasica') THEN
    RAISE EXCEPTION 'case a: unexpected pending row'; END IF;
  SELECT * INTO v_r FROM cerebro_registrar_beneficiario_auto(v_conv, '9760039001240356', '58528291', 'exec221-a2');
  SELECT o.id, o.destination_currency INTO v_op, v_dest FROM remittance_operations o WHERE o.conversation_id = v_conv;
  SELECT b.beneficiary_type, b.currency, b.amount INTO v_tipo, v_cur, v_amt
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo IS DISTINCT FROM 'clasica' OR v_cur IS DISTINCT FROM 'USD' OR v_amt IS DISTINCT FROM floor(5200 / v_usd)
     OR v_dest IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case a: Clasica card should be clasica/USD/% with destination USD, got % / % / % / %',
      floor(5200 / v_usd), v_tipo, v_cur, v_amt, v_dest;
  END IF;
  RAISE NOTICE 'PASS a: marcar_destino_usd clasica then the card -> clasica % USD', v_amt;

  -- ---- a2. Same, but marcar_destino_usd creates the operation itself (no open operation yet) ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210002', 'test221 a2') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec221-a2m');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  UPDATE remittance_operations SET quoted_source_amount = 5200 WHERE id = v_op;
  PERFORM cerebro_registrar_beneficiario_auto(v_conv, '9760039001240356', '58528291', 'exec221-a2c');
  SELECT b.beneficiary_type, b.currency, b.amount INTO v_tipo, v_cur, v_amt
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo IS DISTINCT FROM 'clasica' OR v_cur IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case a2: op created by marcar, card should be clasica/USD, got % / %', v_tipo, v_cur; END IF;
  RAISE NOTICE 'PASS a2: the operation created by marcar_destino_usd also types its card';

  -- ---- b. Tropical ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210003', 'test221 b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 5200, 'GYD', v_stage, 'test221 b', NULL);
  PERFORM cerebro_marcar_destino_usd(v_conv, 'tropical', 'exec221-b');
  PERFORM cerebro_registrar_beneficiario_auto(v_conv, '9227959879614050', '54363811', 'exec221-b2');
  SELECT o.id, o.destination_currency INTO v_op, v_dest FROM remittance_operations o WHERE o.conversation_id = v_conv;
  SELECT b.beneficiary_type, b.currency, b.amount INTO v_tipo, v_cur, v_amt
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo IS DISTINCT FROM 'tropical' OR v_cur IS DISTINCT FROM 'USD' OR v_amt IS DISTINCT FROM floor(5200 / v_usd)
     OR v_dest IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case b: Tropical card should be tropical/USD/%, got % / % / % / %', floor(5200 / v_usd), v_tipo, v_cur, v_amt, v_dest;
  END IF;
  RAISE NOTICE 'PASS b: tropical';

  -- ---- c. The card first, the rail after: the card is re-typed ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210004', 'test221 c') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 5200, 'GYD', v_stage, 'test221 c', NULL);
  PERFORM cerebro_registrar_beneficiario_auto(v_conv, '9760039001240356', '58528291', 'exec221-c1');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  SELECT b.beneficiary_type INTO v_tipo FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo <> 'cuban_card' THEN RAISE EXCEPTION 'case c setup: the card alone should be cuban_card, got %', v_tipo; END IF;
  PERFORM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec221-c2');
  SELECT b.beneficiary_type, b.currency, b.amount INTO v_tipo, v_cur, v_amt
    FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo IS DISTINCT FROM 'clasica' OR v_cur IS DISTINCT FROM 'USD' OR v_amt IS DISTINCT FROM floor(5200 / v_usd) THEN
    RAISE EXCEPTION 'case c: card registered first should be re-typed clasica/USD/%, got % / % / %', floor(5200 / v_usd), v_tipo, v_cur, v_amt;
  END IF;
  RAISE NOTICE 'PASS c: a card registered before marcar_destino_usd is re-typed';

  -- ---- d. reparto_auto source untouched: a mixed CUP + Clasica reparto keeps each share's own rail ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210005', 'test221 d') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 65000, 'GYD', v_stage, 'test221 d', NULL);
  PERFORM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec221-d');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status, currency, amount)
  VALUES (v_op, 'cuban_card', '9227959879614050', '54363811', 1, 1, 'reparto_auto', 'vigente', 'CUP', round(15000 * v_cup))
  RETURNING beneficiary_type INTO v_tipo;
  IF v_tipo <> 'cuban_card' THEN RAISE EXCEPTION 'case d: a reparto_auto CUP card must stay cuban_card, got %', v_tipo; END IF;
  RAISE NOTICE 'PASS d: reparto_auto source untouched';

  -- ---- e. efectivo and zelle operations untouched ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210006', 'test221 e') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 5200, 'GYD', v_stage, 'test221 e', NULL);
  PERFORM cerebro_marcar_destino_usd(v_conv, 'efectivo', 'exec221-e');
  PERFORM cerebro_registrar_beneficiario_auto(v_conv, '9227959879614050', '54363811', 'exec221-e2');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  SELECT b.beneficiary_type INTO v_tipo FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo <> 'cuban_card' OR (SELECT delivery_method FROM remittance_operations WHERE id = v_op) <> 'efectivo_usd'
     OR EXISTS (SELECT 1 FROM cerebro_destino_pendiente WHERE conversation_id = v_conv) THEN
    RAISE EXCEPTION 'case e: efectivo must not type a card nor write a pending row (type %)', v_tipo; END IF;
  -- a zelle operation: delivery_method zelle never types a cuban_card
  UPDATE remittance_operations SET delivery_method = 'zelle' WHERE id = v_op;
  UPDATE remittance_beneficiaries SET status = 'reemplazado' WHERE operation_id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', '9760039001240356', '58528291', 1, 9, 'notes_parse', 'vigente')
  RETURNING beneficiary_type INTO v_tipo;
  IF v_tipo <> 'cuban_card' THEN RAISE EXCEPTION 'case e: a zelle operation must not type a card, got %', v_tipo; END IF;
  RAISE NOTICE 'PASS e: efectivo and zelle untouched';

  -- ---- f. A locked beneficiary is respected when the rail comes after the card ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210007', 'test221 f') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 5200, 'GYD', v_stage, 'test221 f', NULL);
  PERFORM cerebro_registrar_beneficiario_auto(v_conv, '9760039001240356', '58528291', 'exec221-f1');
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('beneficiaries', true) WHERE id = v_op;
  PERFORM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec221-f2');
  SELECT b.beneficiary_type INTO v_tipo FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente';
  IF v_tipo <> 'cuban_card' THEN RAISE EXCEPTION 'case f: a locked beneficiary must not be re-typed, got %', v_tipo; END IF;
  RAISE NOTICE 'PASS f: a locked beneficiary is respected';

  -- ---- g. A recent pending row wins over delivery_method (157 behaviour) ----
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59902210008', 'test221 g') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  PERFORM cerebro_registrar_deposito(v_conv, 5200, 'GYD', v_stage, 'test221 g', NULL);
  PERFORM cerebro_marcar_destino_usd(v_conv, 'clasica', 'exec221-g');
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv, 'tropical', now())
  ON CONFLICT (conversation_id) DO UPDATE SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado;
  SELECT o.id INTO v_op FROM remittance_operations o WHERE o.conversation_id = v_conv;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', '9760039001240356', '58528291', 1, 1, 'notes_parse', 'vigente')
  RETURNING beneficiary_type INTO v_tipo;
  IF v_tipo <> 'tropical' THEN RAISE EXCEPTION 'case g: the pending row (tropical) must win over delivery_method clasica, got %', v_tipo; END IF;
  RAISE NOTICE 'PASS g: the pending row keeps precedence';

  RAISE NOTICE 'ALL PASS (clasica-card-from-delivery-method)';
END $$;
