-- =====================================================================
-- Assertion for migration 182 (production's money rules on the deal-free path).
-- STAGING ONLY. Self-reverting: everything runs in one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Any failure RAISEs its own message instead.
--
-- Production fixed, on the deal path, a remesa paid in parts (170), the target being the quote or the
-- service minimum (171/173), a late MMG email (168/170) and a repeated receipt (178). The deal-free
-- path (160-167, operations created without a deal) must behave the same. Operations here are created
-- the deal-free way (cerebro_crear_operacion, 161) with a structured beneficiary row, deposits go
-- through cerebro_registrar_deposito + cerebro_cruzar_depositos exactly like the Cerebro nodes do,
-- with the id returned by the registrar (an operation id on this path).
-- =====================================================================
CREATE OR REPLACE FUNCTION pg_temp.op_libre(p_tag text, p_benef text) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900182' || p_tag, 'test182' || p_tag)
  RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, zelle_account, position, block_index, source, status)
  VALUES (v_op, CASE p_benef WHEN 'zelle' THEN 'zelle' ELSE 'cuban_card' END,
          CASE p_benef WHEN 'zelle' THEN 'MDBA SOLUTIONS PNC' END,
          CASE p_benef WHEN 'zelle' THEN NULL ELSE '9227959879614050' END,
          CASE p_benef WHEN 'zelle' THEN NULL ELSE '54363811' END,
          CASE p_benef WHEN 'zelle' THEN '8133617809' END, 1, 1, 'manual', 'vigente');
  RETURN v_conv;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.depositar_libre(p_conv uuid, p_monto numeric, p_ref text, p_stage uuid,
                                                   p_comp text DEFAULT NULL, p_correo boolean DEFAULT true) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE v_id uuid;
BEGIN
  IF p_correo THEN
    INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en)
    VALUES (p_ref, p_monto, 'GYD', 'Osmany', 'test182', now()) ON CONFLICT DO NOTHING;
  END IF;
  SELECT r.deal_id INTO v_id
    FROM cerebro_registrar_deposito(p_conv, p_monto, 'GYD', p_stage,
           'DEPOSITO: ' || to_char(p_monto, 'FM999,999') || ' GYD - EXITOSA' || chr(10) || 'Ref: ' || p_ref,
           coalesce(p_comp, 'COMP-' || substr(md5(p_ref), 1, 20))) r;  -- real COMP ids are 20 hex chars (156's parser)
  PERFORM cerebro_cruzar_depositos(v_id, ARRAY[p_ref], ARRAY[p_monto],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', 'da7b3e24-9222-4150-8be8-d7f7378e16aa', '3cf01654-cd27-47c1-ac92-62abf5435751');
  RETURN cerebro_resolve_op_id(v_id);
END $$;

CREATE OR REPLACE FUNCTION pg_temp.bot_dice(p_conv uuid, p_texto text) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, ai_generated)
  VALUES (p_conv, 'agent', 'text', p_texto, true);
$$;

DO $$
DECLARE
  c_esp CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  c_inc CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_conv uuid; v_o1 uuid; v_o2 uuid; v_n int; v_op record; v_obj record; v_cr record; v_reg record;
BEGIN
  -- 1. Yais (170): 3,000 (vision alert -> incident) then 10,000 for a 50 USD Zelle -> ONE operation of 13,000, ready.
  v_conv := pg_temp.op_libre('01', 'zelle');
  v_o1 := pg_temp.depositar_libre(v_conv, 3000, '10409990018201', c_inc);
  v_o2 := pg_temp.depositar_libre(v_conv, 10000, '10409990018202', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_n <> 1 OR v_o2 IS DISTINCT FROM v_o1 OR v_op.quoted_source_amount <> 13000 OR v_op.status <> 'ready_to_transfer'
     OR (SELECT count(*) FROM depositos_mmg WHERE trans_id IN ('10409990018201', '10409990018202') AND operation_id = v_o1 AND consumido_en IS NOT NULL) <> 2 THEN
    RAISE EXCEPTION 'case 1 (Yais 3,000 + 10,000): % ops, same op %, amount %, status %', v_n, v_o2 IS NOT DISTINCT FROM v_o1, v_op.quoted_source_amount, v_op.status;
  END IF;

  -- 2. 10,000 alone is below the Zelle minimum: it WAITS (target = minimo Zelle); 3,000 completes it.
  v_conv := pg_temp.op_libre('02', 'zelle');
  v_o1 := pg_temp.depositar_libre(v_conv, 10000, '10409990018203', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_op.status <> 'deposit_verification' OR v_obj.monto IS DISTINCT FROM 13000 OR v_obj.pedido IS DISTINCT FROM 'minimo Zelle' THEN
    RAISE EXCEPTION 'case 2a: 10,000 for a Zelle must wait on the minimum, got % / % / %', v_op.status, v_obj.monto, v_obj.pedido;
  END IF;
  v_o2 := pg_temp.depositar_libre(v_conv, 3000, '10409990018204', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_o2 IS DISTINCT FROM v_o1 OR v_op.quoted_source_amount <> 13000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 2b (10,000 + 3,000): same op %, amount %, status %', v_o2 IS NOT DISTINCT FROM v_o1, v_op.quoted_source_amount, v_op.status;
  END IF;

  -- 3. CUP card: 3,000 + 2,000 = the 5,000 CUP minimum.
  v_conv := pg_temp.op_libre('03', 'cup');
  v_o1 := pg_temp.depositar_libre(v_conv, 3000, '10409990018205', c_esp);
  v_o2 := pg_temp.depositar_libre(v_conv, 2000, '10409990018206', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_o2 IS DISTINCT FROM v_o1 OR v_op.quoted_source_amount <> 5000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 3 (CUP 3,000 + 2,000): amount %, status %', v_op.quoted_source_amount, v_op.status;
  END IF;

  -- 4. Two complete Zelle deposits stay two remesas.
  v_conv := pg_temp.op_libre('04', 'zelle');
  v_o1 := pg_temp.depositar_libre(v_conv, 13000, '10409990018207', c_esp);
  v_o2 := pg_temp.depositar_libre(v_conv, 13000, '10409990018208', c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status = 'ready_to_transfer';
  IF v_n <> 2 OR v_o2 = v_o1 THEN RAISE EXCEPTION 'case 4: two full Zelle deposits must be two remesas, got % ready', v_n; END IF;

  -- 5. A deposit is never added to a remesa that is ready to transfer.
  v_conv := pg_temp.op_libre('05', 'cup');
  v_o1 := pg_temp.depositar_libre(v_conv, 5000, '10409990018209', c_esp);
  v_o2 := pg_temp.depositar_libre(v_conv, 3000, '10409990018210', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_o2 = v_o1 OR v_op.quoted_source_amount <> 5000 OR v_op.status <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 5: a ready 5,000 remesa must not absorb a later 3,000, got amount % status %', v_op.quoted_source_amount, v_op.status;
  END IF;

  -- 6. The quote is the target (171/173): "100 USD" = 26,000 quoted, 13,000 arrives -> waits on 'cotizacion'.
  v_conv := pg_temp.op_libre('06', 'zelle');
  PERFORM pg_temp.bot_dice(v_conv, 'Por *100 USD* por Zelle necesita depositar *26,000 GYD*.');
  v_o1 := pg_temp.depositar_libre(v_conv, 13000, '10409990018211', c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_op.status <> 'deposit_verification' OR v_obj.monto IS DISTINCT FROM 26000 OR v_obj.pedido IS DISTINCT FROM 'cotizacion'
     OR v_obj.operation_id IS DISTINCT FROM v_o1 THEN
    RAISE EXCEPTION 'case 6: quoted 26,000 must be the target of the operation, got % / % / % / op %', v_op.status, v_obj.monto, v_obj.pedido, v_obj.operation_id;
  END IF;

  -- 7. Repeated receipt (178): the same Ref resent (another image) on a ready remesa changes nothing.
  v_conv := pg_temp.op_libre('07', 'cup');
  v_o1 := pg_temp.depositar_libre(v_conv, 5000, '10409990018212', c_esp);
  SELECT * INTO v_reg FROM cerebro_registrar_deposito(v_conv, 5000, 'GYD', c_esp,
         'DEPOSITO: 5,000 GYD - EXITOSA' || chr(10) || 'Ref: 10409990018212', 'COMP-' || substr(md5('reenvio-07'), 1, 20)) r;
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_reg.deal_id, ARRAY['10409990018212'], ARRAY[5000]::numeric[],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', c_inc, c_esp);
  SELECT count(*) INTO v_n FROM remittance_operations WHERE conversation_id = v_conv AND status <> 'cancelled';
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_n <> 1 OR cerebro_resolve_op_id(v_reg.deal_id) IS DISTINCT FROM v_o1 OR v_op.status <> 'ready_to_transfer'
     OR v_op.quoted_source_amount <> 5000 OR v_cr.resultado <> 'verificado' THEN
    RAISE EXCEPTION 'case 7 (resent receipt): % ops, same op %, status %, amount %, cross %, accion %',
      v_n, cerebro_resolve_op_id(v_reg.deal_id) IS NOT DISTINCT FROM v_o1, v_op.status, v_op.quoted_source_amount, v_cr.resultado, v_reg.accion;
  END IF;

  -- 8. ... and on a remesa waiting for the rest, resending the 10,000 is NOT the rest.
  v_conv := pg_temp.op_libre('08', 'zelle');
  v_o1 := pg_temp.depositar_libre(v_conv, 10000, '10409990018213', c_esp);
  SELECT * INTO v_reg FROM cerebro_registrar_deposito(v_conv, 10000, 'GYD', c_esp,
         'DEPOSITO: 10,000 GYD - EXITOSA' || chr(10) || 'Ref: 10409990018213', 'COMP-' || substr(md5('reenvio-08'), 1, 20)) r;
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_reg.deal_id, ARRAY['10409990018213'], ARRAY[10000]::numeric[],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', c_inc, c_esp);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_op.status <> 'deposit_verification' OR v_op.quoted_source_amount <> 10000 OR v_cr.resultado <> 'verificado_incompleto' THEN
    RAISE EXCEPTION 'case 8 (resent part payment): status %, amount %, cross %, accion %', v_op.status, v_op.quoted_source_amount, v_cr.resultado, v_reg.accion;
  END IF;

  -- 9. The same Ref twice inside one burst crosses once.
  v_conv := pg_temp.op_libre('09', 'cup');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en)
  VALUES ('10409990018214', 5000, 'GYD', 'Osmany', 'test182', now());
  SELECT * INTO v_reg FROM cerebro_registrar_deposito(v_conv, 5000, 'GYD', c_esp,
         'DEPOSITO: 5,000 GYD - EXITOSA' || chr(10) || 'Ref: 10409990018214', 'COMP-' || substr(md5('rafaga-09'), 1, 20)) r;
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_reg.deal_id, ARRAY['10409990018214', '10409990018214'], ARRAY[5000, 5000]::numeric[],
            'f5cf87f8-b570-4d71-b6ea-a3cafd458c63', c_inc, c_esp);
  IF v_cr.resultado <> 'verificado' THEN RAISE EXCEPTION 'case 9 (same Ref twice in one burst): %', v_cr.resultado; END IF;

  -- 10. Late MMG email (168/170): the receipt arrives first, the email later; the re-cross verifies it.
  v_conv := pg_temp.op_libre('10', 'cup');
  v_o1 := pg_temp.depositar_libre(v_conv, 5000, '10409990018215', c_esp, NULL, false);
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_op.status <> 'deposit_verification' THEN RAISE EXCEPTION 'case 10a: no email yet must wait, got %', v_op.status; END IF;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en)
  VALUES ('10409990018215', 5000, 'GYD', 'Osmany', 'test182', now());
  -- The re-cross waits until the operation has been quiet for 90 s; a touch trigger stamps
  -- updated_at = now() on every UPDATE, so the age is set with triggers off for this one row.
  SET LOCAL session_replication_role = replica;
  UPDATE remittance_operations SET updated_at = now() - interval '5 minutes' WHERE id = v_o1;
  SET LOCAL session_replication_role = origin;
  PERFORM cerebro_recruzar_depositos_tardios();
  SELECT * INTO v_op FROM remittance_operations WHERE id = v_o1;
  IF v_op.status <> 'ready_to_transfer' THEN RAISE EXCEPTION 'case 10b: the late email must verify the deposit, got %', v_op.status; END IF;

  -- 11. Nothing on this path created a deal.
  IF EXISTS (SELECT 1 FROM deals d JOIN conversations v ON v.id = d.conversation_id
              JOIN contacts c ON c.id = v.contact_id WHERE c.phone LIKE '59900182%') THEN
    RAISE EXCEPTION 'case 11: the deal-free path created a deal';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
