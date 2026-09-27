-- =====================================================================
-- Assertion for migration 125 (deal INSERT creates its operation again).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Any failure RAISEs; every passing case prints a NOTICE.
--
-- Uses two existing conversations that have no open deal, no partial
-- beneficiary and are not resellers (picked by the query below), so the
-- deposit branches behave exactly as for a new customer.
-- =====================================================================
DO $$
DECLARE
  c_pipeline   CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_solicitada CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  c_por_verif  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_a uuid; v_b uuid;
  v_deal uuid; v_n int; v_op remittance_operations%ROWTYPE;
  v_ref_hi text;
  r record;
BEGIN
  SELECT array_agg(id ORDER BY created_at) INTO STRICT r FROM (
    SELECT v.id, v.created_at FROM conversations v
     WHERE NOT EXISTS (SELECT 1 FROM deals d WHERE d.conversation_id = v.id AND d.status = 'open')
       AND NOT EXISTS (SELECT 1 FROM cerebro_beneficiario_parcial p WHERE p.conversation_id = v.id)
       AND NOT EXISTS (SELECT 1 FROM cerebro_revendedores rv JOIN contacts c ON c.phone = rv.phone
                        WHERE c.id = v.contact_id)
     ORDER BY v.created_at LIMIT 2) x;
  v_a := (r.array_agg)[1]; v_b := (r.array_agg)[2];
  IF v_a IS NULL OR v_b IS NULL THEN RAISE EXCEPTION 'fixture: need two clean conversations'; END IF;

  -- A TransID above every one received, so cerebro_transid_plausible accepts it.
  SELECT (coalesce(max(trans_id::numeric), 20000000000000) + 7)::text INTO v_ref_hi
    FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$';

  -- 1. Beneficiary-first deal (what 'Registrar beneficiario auto' inserts)
  --    gets its operation and its beneficiary.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id,
                     title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, v.id, c_pipeline, c_solicitada,
         'Remesa +test125', 0, 'GYD',
         'BENEFICIARIO (auto)' || E'\nTarjeta: 9224069996859118' || E'\nCelular: 56430816', 'open'
    FROM conversations v WHERE v.id = v_a
  RETURNING id INTO v_deal;

  SELECT count(*) INTO v_n FROM remittance_operations WHERE deal_id = v_deal;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: expected 1 operation for the new deal, got %', v_n; END IF;
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_deal;
  IF v_op.status <> 'collecting_information' THEN
    RAISE EXCEPTION 'case 1: expected collecting_information, got %', v_op.status;
  END IF;
  SELECT count(*) INTO v_n FROM remittance_beneficiaries
   WHERE operation_id = v_op.id AND status = 'vigente' AND card_number = '9224069996859118';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: expected the beneficiary from the notes, got % rows', v_n; END IF;
  RAISE NOTICE 'PASS 1: beneficiary-first deal gets its operation and beneficiary';

  -- 2. Then the deposit arrives: it lands on that same operation.
  PERFORM * FROM cerebro_registrar_deposito(v_a, 5000, 'GYD', c_por_verif,
            'DEPOSITO: 5,000 GYD - EXITOSA' || E'\nRef: ' || v_ref_hi, 'COMP-test125a');
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_a
     AND created_at > now() - interval '1 minute';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 2: expected still 1 new operation in the chat, got %', v_n; END IF;
  SELECT * INTO v_op FROM remittance_operations WHERE deal_id = v_deal;
  IF v_op.quoted_source_amount IS DISTINCT FROM 5000 OR v_op.status <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case 2: expected 5000 / deposit_verification, got % / %',
      v_op.quoted_source_amount, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 2: the later deposit lands on the beneficiary-first operation';

  -- 3. A recarga detected by cerebro_registrar_deposito keeps service_type 'recarga'
  --    even though the trigger created the row first.
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at)
  VALUES (v_b, 'customer', 'text', 'hola quiero hacer una recarga', now());
  PERFORM * FROM cerebro_registrar_deposito(v_b, 5200, 'GYD', c_por_verif,
            'DEPOSITO: 5,200 GYD - EXITOSA' || E'\nRef: ' || (v_ref_hi::numeric + 1)::text, 'COMP-test125b');
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_b
     AND created_at > now() - interval '1 minute';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 3: expected exactly 1 new operation, got %', v_n; END IF;
  SELECT * INTO v_op FROM remittance_operations WHERE conversation_id = v_b
     AND created_at > now() - interval '1 minute';
  IF v_op.service_type <> 'recarga' THEN
    RAISE EXCEPTION 'case 3: expected service_type recarga, got %', v_op.service_type;
  END IF;
  IF v_op.quoted_source_amount IS DISTINCT FROM 5200 THEN
    RAISE EXCEPTION 'case 3: expected amount 5200, got %', v_op.quoted_source_amount;
  END IF;
  RAISE NOTICE 'PASS 3: recarga stays recarga with one operation';

  -- 4. Deals outside scope get no operation: no conversation.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id,
                     title, value, currency, notes, status)
  SELECT v.user_id, v.account_id, v.contact_id, NULL, c_pipeline, c_solicitada,
         'sin conversacion test125', 0, 'GYD', NULL, 'open'
    FROM conversations v WHERE v.id = v_a
  RETURNING id INTO v_deal;
  SELECT count(*) INTO v_n FROM remittance_operations WHERE deal_id = v_deal;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: a deal without conversation got % operation(s)', v_n; END IF;
  RAISE NOTICE 'PASS 4: deal without conversation gets no operation';
END $$;
