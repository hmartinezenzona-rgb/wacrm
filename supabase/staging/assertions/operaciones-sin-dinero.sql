-- =====================================================================
-- Assertion for migration 326 (sin_dinero: open operations without their part of a verified deposit).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
  v_a uuid; v_b uuid; v_c uuid;
  v_res jsonb; v_sd jsonb;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599001326', 'test326') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- A holds the deposit and the objective.
  v_a := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations SET service_type = 'remesa', status = 'ready_to_transfer',
         quoted_source_amount = 31000 WHERE id = v_a;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('99990000326101', 31000, 'GYD', 'test 326', now(), now(), v_a);
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido, operation_id, fijado_en, cerrado_en)
  VALUES (v_conv, 26000, 'GYD', '100 USD', v_a, now(), NULL)
  ON CONFLICT (conversation_id) DO UPDATE
     SET monto = EXCLUDED.monto, operation_id = EXCLUDED.operation_id, fijado_en = now(), cerrado_en = NULL;

  -- B and C: open, empty, with a recipient, no objective. Three parts: 325 cannot compute them.
  v_b := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations SET service_type = 'remesa', status = 'collecting_information', quoted_source_amount = 0 WHERE id = v_b;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, status, source, position)
  VALUES (v_b, 'cuban_card', '9238129973050414', '51085507', 'vigente', 'manual', 1);

  v_c := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations SET service_type = 'remesa', status = 'collecting_information', quoted_source_amount = 0 WHERE id = v_c;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, status, source, position)
  VALUES (v_c, 'cuban_card', '51085508', 'vigente', 'manual', 1);

  -- 1. Three parts: 325 stays null, 326 lists both empty operations.
  v_res := cerebro_resolver_servicio(v_conv);
  IF coalesce(v_res -> 'reparto_pendiente', 'null'::jsonb) <> 'null'::jsonb THEN
    RAISE EXCEPTION 'case 1: 325 must not fire with three parts, got %', v_res -> 'reparto_pendiente';
  END IF;
  v_sd := v_res -> 'sin_dinero';
  IF v_sd IS NULL OR jsonb_array_length(v_sd) <> 2 THEN
    RAISE EXCEPTION 'case 1: sin_dinero should list 2 operations, got %', v_sd;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_sd) e WHERE (e ->> 'operation_id') = v_b::text) THEN
    RAISE EXCEPTION 'case 1: operation B missing from %', v_sd;
  END IF;

  -- 2. A grouped member is not missing money: the group's deposit covers it.
  UPDATE remittance_operations SET mixed_group_id = v_a WHERE id = v_b;
  v_res := cerebro_resolver_servicio(v_conv);
  v_sd := v_res -> 'sin_dinero';
  IF v_sd IS NULL OR jsonb_array_length(v_sd) <> 1
     OR (v_sd -> 0 ->> 'operation_id') <> v_c::text THEN
    RAISE EXCEPTION 'case 2: only C should remain, got %', v_sd;
  END IF;

  -- 3. No verified deposit in the send: no guard (normal pre-deposit state).
  UPDATE depositos_mmg SET anulado_en = now() WHERE trans_id = '99990000326101';
  v_res := cerebro_resolver_servicio(v_conv);
  IF coalesce(v_res -> 'sin_dinero', 'null'::jsonb) <> 'null'::jsonb THEN
    RAISE EXCEPTION 'case 3: expected null without a deposit, got %', v_res -> 'sin_dinero';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
