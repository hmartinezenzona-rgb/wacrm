-- =====================================================================
-- Assertion for migration 333 (the resolver exposes the funding case).
-- Self-reverting: one DO block ending in RAISE EXCEPTION 'ALL PASS'.
-- Cases:
--   1. a healthy case is visible in the resolver with its amounts.
--   2. an incident case exposes the status and the conflict note.
--   3. a conversation without a case exposes no expediente.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid;
  v_res jsonb;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- Case 1: healthy.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599333001', 'test333a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'zelle', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 100, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_op, 'zelle', 'PRUEBA 333 A', 'a333@example.com', 100, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('33300000000001', 26000, 'GYD', 'PRUEBA 333', now(), now(), v_op);
  PERFORM funding_reconciliar(v_conv, 'test333');

  v_res := cerebro_resolver_servicio(v_conv);
  IF v_res -> 'expediente' IS NULL OR v_res -> 'expediente' = 'null'::jsonb THEN
    RAISE EXCEPTION 'case 1: the resolver did not expose the case';
  END IF;
  IF v_res -> 'expediente' ->> 'estado' IS DISTINCT FROM 'allocating' THEN
    RAISE EXCEPTION 'case 1: expediente state %, expected allocating', v_res -> 'expediente' ->> 'estado';
  END IF;
  IF (v_res -> 'expediente' ->> 'depositado')::numeric <> 26000
     OR (v_res -> 'expediente' ->> 'asignado')::numeric <> 26000
     OR (v_res -> 'expediente' ->> 'disponible')::numeric <> 0 THEN
    RAISE EXCEPTION 'case 1: expediente amounts are %/%/%',
      v_res -> 'expediente' ->> 'depositado', v_res -> 'expediente' ->> 'asignado', v_res -> 'expediente' ->> 'disponible';
  END IF;

  -- Case 2: incident.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599333002', 'test333b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations
     SET service_type = 'remesa', delivery_method = 'clasica', status = 'ready_to_transfer',
         quoted_source_amount = 26000, quoted_destination_amount = 50, destination_currency = 'USD'
   WHERE id = v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, status, source)
  VALUES (v_op, 'cuban_card', 'PRUEBA 333 B', '9234123456789012', '5355512301', 50, 'USD', 1, 'vigente', 'manual');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('33300000000002', 26000, 'GYD', 'PRUEBA 333', now(), now(), v_op);
  PERFORM funding_reconciliar(v_conv, 'test333');

  v_res := cerebro_resolver_servicio(v_conv);
  IF v_res -> 'expediente' ->> 'estado' IS DISTINCT FROM 'incident' THEN
    RAISE EXCEPTION 'case 2: expediente state %, expected incident', v_res -> 'expediente' ->> 'estado';
  END IF;
  IF COALESCE(v_res -> 'expediente' ->> 'nota', '') NOT LIKE '%conflicto%' THEN
    RAISE EXCEPTION 'case 2: the expediente note is %, expected the conflict', v_res -> 'expediente' ->> 'nota';
  END IF;

  -- Case 3: no case.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599333003', 'test333c') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_op := cerebro_crear_operacion(v_conv);
  v_res := cerebro_resolver_servicio(v_conv);
  IF v_res ->> 'expediente' IS NOT NULL THEN
    RAISE EXCEPTION 'case 3: a conversation without a case exposed an expediente';
  END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
