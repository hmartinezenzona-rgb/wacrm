-- =====================================================================
-- Assertion for migration 327.
-- 1. The resolver returns the group's actual verified deposit (deposito_grupo_gyd).
-- 2. An implicit quote of another service does not open a second operation; an explicit declaration does.
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- =====================================================================
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid;
  v_a uuid; v_b uuid; v_res jsonb; v_ok boolean; v_n int;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  IF v_user IS NULL THEN RAISE EXCEPTION 'no owner profile to build the fixture'; END IF;

  -- Case 1: a group of 275,000 + 10,000 with a 285,000 deposit.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '599001329', 'test327a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  v_a := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations SET service_type='remesa', status='ready_to_transfer',
         quoted_source_amount=275000, quoted_destination_amount=1100, destination_currency='USD' WHERE id=v_a;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, amount, currency, position, status, source)
  VALUES (v_a, 'zelle', 'PRUEBA A', 'a@example.com', 800, 'USD', 1, 'vigente', 'manual');

  v_b := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations SET service_type='remesa', status='collecting_information',
         quoted_source_amount=10000, quoted_destination_amount=30000, destination_currency='CUP',
         mixed_group_id=v_a WHERE id=v_b;
  UPDATE remittance_operations SET mixed_group_id=v_a WHERE id=v_a;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, card_number, phone, amount, currency, position, status, source)
  VALUES (v_b, 'cuban_card', '9234069999100369', '59564155', 30000, 'CUP', 1, 'vigente', 'manual');

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('99990000329101', 285000, 'GYD', 'test 327', now(), now(), v_a);

  v_res := cerebro_resolver_servicio(v_conv);
  IF (v_res ->> 'deposito_grupo_gyd') IS NULL OR (v_res ->> 'deposito_grupo_gyd')::numeric <> 285000 THEN
    RAISE EXCEPTION 'case 1: deposito_grupo_gyd = %, expected 285000', v_res ->> 'deposito_grupo_gyd';
  END IF;

  -- Case 2: an open uncommitted Zelle operation; an implicit Clasica quote must not open another.
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '5990013291', 'test327b') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  v_a := cerebro_crear_operacion(v_conv);
  UPDATE remittance_operations SET service_type='remesa', status='collecting_information', quoted_source_amount=275000 WHERE id=v_a;
  -- the operation has no money and no receipt: it is uncommitted
  DELETE FROM depositos_mmg WHERE operation_id = v_a;
  DELETE FROM remittance_operation_receipts WHERE operation_id = v_a;

  v_ok := _cerebro_declarar_implicito(v_conv, 'clasica', 'cotizar', 286000);
  IF v_ok THEN RAISE EXCEPTION 'case 2: implicit quote should have been skipped'; END IF;
  SELECT count(*) INTO v_n FROM remittance_operations o
   WHERE o.conversation_id = v_conv AND cerebro_riel_op(o.id) = 'clasica';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 2: implicit quote opened % clasica operation(s)', v_n; END IF;

  -- Case 3: the explicit declaration still works.
  PERFORM cerebro_declarar_servicio(v_conv, 'clasica', 'agent:test327', 286000);
  SELECT count(*) INTO v_n FROM remittance_operations o
   WHERE o.conversation_id = v_conv AND cerebro_riel_op(o.id) = 'clasica';
  IF v_n < 1 THEN RAISE EXCEPTION 'case 3: explicit declaration did not open the clasica operation'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
