-- =====================================================================
-- Assertion for migration 169 (reparto with a USD card rail).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Case 1 reproduces the production reparto a29ef5e8 (2026-10-01): 65,000 GYD
-- = 15,000 GYD to an MN card (45,000 CUP) + 50,000 GYD to a Clasica card
-- (192 USD at 260). Any failure RAISEs; each passing case NOTICEs.
-- Rates are read from crm_tasa_vigente, so the fixture amounts follow them.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
  v_usd numeric := crm_tasa_vigente('usd');
  v_cup numeric := crm_tasa_vigente('gyd');
  v_r jsonb; v_n int; v_tipo text;
  v_mixto jsonb;
  v_todo_cup jsonb;
BEGIN
  IF NOT (v_usd > 0 AND v_cup > 0) THEN RAISE EXCEPTION 'setup: both rates are needed (usd %, cup %)', v_usd, v_cup; END IF;
  v_mixto := jsonb_build_array(
    jsonb_build_object('tipo', 'cuban_card', 'cuenta', '9227959879614050', 'celular', '54363811', 'monto', round(15000 * v_cup), 'moneda', 'CUP'),
    jsonb_build_object('tipo', 'clasica', 'cuenta', '9760039001240356', 'celular', '58528291', 'monto', floor(50000 / v_usd), 'moneda', 'USD'));
  v_todo_cup := jsonb_build_array(
    jsonb_build_object('tipo', 'cuban_card', 'cuenta', '9227959879614050', 'celular', '54363811', 'monto', round(15000 * v_cup), 'moneda', 'CUP'),
    jsonb_build_object('tipo', 'cuban_card', 'cuenta', '9760039001240356', 'celular', '58528291', 'monto', round(50000 * v_cup), 'moneda', 'CUP'));

  -- Own contact and conversation, user and account from whatsapp_config + profiles: staging may have no
  -- conversation free of an open operation (or none at all after a test-contact reset).
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59901690001', 'test169 usd rail')
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- 1. The customer named "clasica" (157's pending destination) and the reparto carries one CUP card
  --    and one Clasica card: applied, each row with its own type and currency.
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv, 'clasica', now())
  ON CONFLICT (conversation_id) DO UPDATE SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 65000) RETURNING id INTO v_op;
  v_r := cerebro_aplicar_reparto(v_op, v_mixto);
  IF NOT (v_r->>'aplicado')::boolean THEN RAISE EXCEPTION 'case 1: CUP card + Clasica should apply, got %', v_r; END IF;
  SELECT count(*) INTO v_n FROM remittance_beneficiaries
   WHERE operation_id = v_op AND status = 'vigente'
     AND ((card_number = '9227959879614050' AND beneficiary_type = 'cuban_card' AND currency = 'CUP' AND amount = round(15000 * v_cup))
       OR (card_number = '9760039001240356' AND beneficiary_type = 'clasica' AND currency = 'USD' AND amount = floor(50000 / v_usd)));
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'case 1: wrong rows: %', (SELECT jsonb_agg(to_jsonb(b)) FROM remittance_beneficiaries b WHERE b.operation_id = v_op AND b.status = 'vigente');
  END IF;
  RAISE NOTICE 'PASS 1: the MN card stays a CUP card and the Clasica card is stored in USD';

  -- 2. Fail closed: "clasica" was named but every share is a CUP card (the production shape) →
  --    refused, nothing written, nothing locked.
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
  INSERT INTO cerebro_destino_pendiente (conversation_id, tipo, actualizado) VALUES (v_conv, 'clasica', now())
  ON CONFLICT (conversation_id) DO UPDATE SET tipo = EXCLUDED.tipo, actualizado = EXCLUDED.actualizado;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 65000) RETURNING id INTO v_op;
  v_r := cerebro_aplicar_reparto(v_op, v_todo_cup);
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op;
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'destino_sin_asignar' OR v_n <> 0
     OR (SELECT admin_locked_fields ? 'beneficiaries' FROM remittance_operations WHERE id = v_op) THEN
    RAISE EXCEPTION 'case 2: an all-CUP reparto under a pending clasica must be refused, got % (%)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 2: a named Clasica with no Clasica share is refused, not stored in CUP';

  -- 3. 157's trigger still re-types a card that does NOT come from a reparto.
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, position, block_index, source, status)
  VALUES (v_op, 'cuban_card', '9760039001240356', '58528291', 1, 1, 'notes_parse', 'vigente')
  RETURNING beneficiary_type INTO v_tipo;
  IF v_tipo <> 'clasica' THEN RAISE EXCEPTION 'case 3: a single card under a pending clasica must still become clasica, got %', v_tipo; END IF;
  RAISE NOTICE 'PASS 3: the single-beneficiary path of 157 is unchanged';

  -- 4. Type and currency must agree: a Clasica share in CUP is refused.
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_op;
  DELETE FROM cerebro_destino_pendiente WHERE conversation_id = v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount)
  VALUES (v_acc, v_conv, v_ct, 'ready_to_transfer', 'remesa', 'GYD', 65000) RETURNING id INTO v_op;
  v_r := cerebro_aplicar_reparto(v_op, jsonb_set(v_todo_cup, '{1,tipo}', '"clasica"'));
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op;
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'formato' OR v_n <> 0 THEN
    RAISE EXCEPTION 'case 4: a clasica share in CUP must be refused, got % (%)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 4: a Clasica share quoted in CUP is refused';

  -- 5. Regression: with no USD rail named, two CUP cards apply exactly as before.
  v_r := cerebro_aplicar_reparto(v_op, v_todo_cup);
  SELECT count(*) INTO v_n FROM remittance_beneficiaries
   WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'cuban_card' AND currency = 'CUP';
  IF NOT (v_r->>'aplicado')::boolean OR v_n <> 2 THEN RAISE EXCEPTION 'case 5: a plain CUP reparto should apply, got % (%)', v_r, v_n; END IF;
  RAISE NOTICE 'PASS 5: a plain two-card CUP reparto is unchanged';
END $$;

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
