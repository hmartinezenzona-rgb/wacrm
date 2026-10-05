-- =====================================================================
-- Assertion for migration 170 (split deposits: service minimums as the remesa target).
-- Self-reverting: everything runs in one DO block that ends in RAISE EXCEPTION 'ALL PASS',
-- so nothing it writes survives. Any failure RAISEs its own message instead.
--
-- Case 1 replays the real production conversation of Yais (2026-09-28): a 50 USD Zelle
-- (13,000 GYD) paid as 3,000 (vision alert -> incident) and then 10,000.
-- Each deposit is driven exactly like the Cerebro does it: the MMG email is in the ledger,
-- `Registrar deposito auto` calls cerebro_registrar_deposito, then `Cruzar deposito con MMG`
-- calls cerebro_cruzar_depositos with the stages (ok, incidencia, esperado).
-- =====================================================================
-- (2026-10-05) Fixture rebuilt deal-free (161/172/183): a deal no longer creates the operation, so conv_prueba creates it with
-- cerebro_crear_operacion plus a structured beneficiary, and depositar returns the OPERATION id the registrar hands back. The user
-- and account come from whatsapp_config + profiles (not from whatever conversation happens to exist). The receipt COMP id is a 20-hex
-- id like the real ones (156's parser), otherwise the second deposit of a conversation is read as a repeat of the first.
CREATE OR REPLACE FUNCTION pg_temp.conv_prueba(p_tag text, p_benef text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900169' || p_tag, 'test169' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, zelle_account, position, block_index, source, status)
  VALUES (v_op, CASE p_benef WHEN 'zelle' THEN 'zelle' ELSE 'cuban_card' END,
          CASE p_benef WHEN 'zelle' THEN 'MDBA SOLUTIONS PNC' END,
          CASE p_benef WHEN 'zelle' THEN NULL ELSE '9227959879614050' END,
          CASE p_benef WHEN 'zelle' THEN NULL ELSE '54363811' END,
          CASE p_benef WHEN 'zelle' THEN '8133617809' END, 1, 1, 'notes_parse', 'vigente');
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.depositar(p_conv uuid, p_monto numeric, p_ref text, p_stage uuid) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en)
  VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test169', now());
  SELECT r.deal_id INTO v_id
    FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', p_stage,
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref, 'COMP-' || substr(md5(p_ref), 1, 20)) r;  -- real COMP ids are 20 hex chars (156's parser)
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
  RETURN cerebro_resolve_op_id(v_id);
END $$;

DO $$
DECLARE
  c_esp CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  c_inc CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_conv uuid; v_d1 uuid; v_d2 uuid; v_n int; v_op record;
BEGIN
  -- 1. Yais, real order: 3,000 (incident, vision alert) then 10,000 -> ONE op of 13,000, verified.
  v_conv := pg_temp.conv_prueba('01', 'zelle');
  v_d1 := pg_temp.depositar(v_conv, 3000, '10409990016901', c_inc);
  v_d2 := pg_temp.depositar(v_conv, 10000, '10409990016902', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_d1;
  IF v_n <> 1 OR v_d2 IS DISTINCT FROM v_d1 OR v_op.quoted_source_amount <> 13000 OR v_op.status <> 'ready_to_transfer'
     OR (SELECT count(*) FROM depositos_mmg WHERE trans_id IN ('10409990016901', '10409990016902') AND operation_id = v_d1 AND consumido_en IS NOT NULL) <> 2 THEN
    RAISE EXCEPTION 'case 1 (Yais 3,000 + 10,000): % ops, same deal %, amount %, status %',
      v_n, v_d2 IS NOT DISTINCT FROM v_d1, v_op.quoted_source_amount, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 1: Yais 3,000 + 10,000 is one 13,000 remesa, both deposits verified';

  -- 2. Same remesa, other order: 10,000 alone is below the Zelle minimum, so it WAITS; 3,000 completes it.
  v_conv := pg_temp.conv_prueba('02', 'zelle');
  v_d1 := pg_temp.depositar(v_conv, 10000, '10409990016903', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_d1;
  IF v_op.status <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case 2: 10,000 for a Zelle must wait for the rest, got status %', v_op.status;
  END IF;
  v_d2 := pg_temp.depositar(v_conv, 3000, '10409990016904', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_d1;
  IF v_n <> 1 OR v_d2 IS DISTINCT FROM v_d1 OR v_op.quoted_source_amount <> 13000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 2 (10,000 + 3,000): % ops, amount %, status %', v_n, v_op.quoted_source_amount, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 2: 10,000 waits for the Zelle minimum and 3,000 completes it';

  -- 3. CUP card: 3,000 + 2,000 = the 5,000 CUP minimum.
  v_conv := pg_temp.conv_prueba('03', 'cup');
  v_d1 := pg_temp.depositar(v_conv, 3000, '10409990016905', c_esp);
  v_d2 := pg_temp.depositar(v_conv, 2000, '10409990016906', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_d1;
  IF v_n <> 1 OR v_op.quoted_source_amount <> 5000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 3 (CUP 3,000 + 2,000): % ops, amount %, status %', v_n, v_op.quoted_source_amount, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 3: CUP 3,000 + 2,000 is one 5,000 remesa';

  -- 4. Two complete Zelle deposits stay two remesas.
  v_conv := pg_temp.conv_prueba('04', 'zelle');
  v_d1 := pg_temp.depositar(v_conv, 13000, '10409990016907', c_esp);
  v_d2 := pg_temp.depositar(v_conv, 13000, '10409990016908', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status = 'ready_to_transfer';
  IF v_n <> 2 OR v_d2 = v_d1 THEN RAISE EXCEPTION 'case 4: two full Zelle deposits must be two remesas, got % ready', v_n; END IF;
  RAISE NOTICE 'PASS 4: two complete deposits are two remesas';

  -- 5. A deposit is never added to a remesa that is already complete and ready to transfer.
  v_conv := pg_temp.conv_prueba('05', 'cup');
  v_d1 := pg_temp.depositar(v_conv, 5000, '10409990016909', c_esp);
  v_d2 := pg_temp.depositar(v_conv, 3000, '10409990016910', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_d1;
  IF v_d2 = v_d1 OR v_op.quoted_source_amount <> 5000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 5: a ready 5,000 remesa must not absorb a later 3,000, got amount % status %', v_op.quoted_source_amount, v_op.status;
  END IF;
  RAISE NOTICE 'PASS 5: a ready remesa is never changed by a later deposit';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
