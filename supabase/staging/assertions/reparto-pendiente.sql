-- =====================================================================
-- Assertion for migration 325 (reparto_pendiente: the resolver exposes a verified deposit that must be split).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Fixture: conversation with a 31,000 GYD deposit in one open zelle operation (objective 26,000 GYD) and a
-- second open cuban_card operation with a recipient and no money. The remainder is 5,000 GYD.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
  v_a uuid; v_b uuid;
  v_res jsonb; v_rp jsonb; v_partes jsonb;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599001325', 'test325') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- Operation A: holds the verified deposit, Zelle recipient, objective 26,000 GYD.
  v_a := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', status = 'ready_to_transfer',
         quoted_source_amount = 31000, quoted_destination_amount = 119, destination_currency = 'USD'
   WHERE id = v_a;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_a, 'zelle', 'RIGOBERTO SUAREZ', 'test325@example.com', 100, 'USD', 1, 'vigente', 'manual');

  -- Operation B: recipient, no money.
  v_b := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', status = 'collecting_information', quoted_source_amount = 0
   WHERE id = v_b;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, amount, currency, position, status, source)
  VALUES (v_b, 'cuban_card', '9238129973050414', '51085507', 15000, 'CUP', 1, 'vigente', 'manual');

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('99990000325101', 31000, 'GYD', 'test 325', now(), now(), v_a);

  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, pedido, operation_id, fijado_en, cerrado_en)
  VALUES (v_conv, 26000, 'GYD', '100 USD', v_a, now(), NULL)
  ON CONFLICT (conversation_id) DO UPDATE
     SET monto = EXCLUDED.monto, moneda = 'GYD', pedido = EXCLUDED.pedido,
         operation_id = EXCLUDED.operation_id, fijado_en = now(), cerrado_en = NULL;

  -- 1. The unambiguous case: the fact is present with the two parts.
  v_res := cerebro_resolver_servicio(v_conv);
  v_rp := v_res -> 'reparto_pendiente';
  IF v_rp IS NULL THEN RAISE EXCEPTION 'case 1: reparto_pendiente is null; resolver = %', v_res; END IF;
  IF (v_rp ->> 'deposito_gyd')::numeric <> 31000 THEN RAISE EXCEPTION 'case 1: deposito %', v_rp; END IF;
  IF (v_rp ->> 'resto_gyd')::numeric <> 5000 THEN RAISE EXCEPTION 'case 1: resto %', v_rp; END IF;
  v_partes := v_rp -> 'partes';
  IF jsonb_array_length(v_partes) <> 2 THEN RAISE EXCEPTION 'case 1: partes %', v_partes; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_partes) e
                  WHERE e ->> 'servicio' = 'zelle' AND (e ->> 'monto_gyd')::numeric = 26000) THEN
    RAISE EXCEPTION 'case 1: no zelle 26000 in %', v_partes;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_partes) e
                  WHERE e ->> 'servicio' = 'cuban_card' AND (e ->> 'monto_gyd')::numeric = 5000) THEN
    RAISE EXCEPTION 'case 1: no cuban_card 5000 in %', v_partes;
  END IF;

  -- 2. Objective equal to the deposit: nothing to split.
  UPDATE cerebro_objetivo_envio SET monto = 31000 WHERE conversation_id = v_conv;
  v_res := cerebro_resolver_servicio(v_conv);
  IF coalesce(v_res -> 'reparto_pendiente', 'null'::jsonb) <> 'null'::jsonb THEN
    RAISE EXCEPTION 'case 2: expected null, got %', v_res -> 'reparto_pendiente';
  END IF;

  -- 3. The second operation has no recipient: no fact, the bot must ask.
  UPDATE cerebro_objetivo_envio SET monto = 26000 WHERE conversation_id = v_conv;
  UPDATE remittance_beneficiaries SET status = 'reemplazado' WHERE operation_id = v_b;
  v_res := cerebro_resolver_servicio(v_conv);
  IF coalesce(v_res -> 'reparto_pendiente', 'null'::jsonb) <> 'null'::jsonb THEN
    RAISE EXCEPTION 'case 3: expected null without a recipient, got %', v_res -> 'reparto_pendiente';
  END IF;

  -- 4. Remainder below the second service's minimum: no fact.
  UPDATE remittance_beneficiaries SET status = 'vigente' WHERE operation_id = v_b;
  UPDATE cerebro_objetivo_envio SET monto = 30000 WHERE conversation_id = v_conv;
  v_res := cerebro_resolver_servicio(v_conv);
  IF coalesce(v_res -> 'reparto_pendiente', 'null'::jsonb) <> 'null'::jsonb THEN
    RAISE EXCEPTION 'case 4: expected null below the minimum, got %', v_res -> 'reparto_pendiente';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
