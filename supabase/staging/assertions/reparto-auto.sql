-- =====================================================================
-- Assertion for migration 127 (cerebro_aplicar_reparto).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Fixtures reproduce REAL production repartos, verified against the team's
-- delivery proofs (chat 9e338224, 15-Aug: 143,000 GYD = 550 USD for four
-- people). Any failure RAISEs; each passing case NOTICEs.
-- =====================================================================
DO $$
DECLARE
  c_pipeline CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  c_lista    CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_deal uuid; v_op uuid;
  v_r jsonb; v_n int;
  v_cuatro CONSTANT jsonb := '[
    {"tipo":"zelle","cuenta":"9542184382","nombre":"humberto rey bernal","monto":100,"moneda":"USD"},
    {"tipo":"zelle","cuenta":"8132794817","nombre":"Mayiannelis Ortega","monto":100,"moneda":"USD"},
    {"tipo":"zelle","cuenta":"4633149908","nombre":"Gladys Bellas Gutieres","monto":50,"moneda":"USD"},
    {"tipo":"zelle","cuenta":"9413105654","nombre":"david santillán","monto":300,"moneda":"USD"}]';
BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;

  -- A deal in "Lista para transferir" for 143,000 GYD; 125 creates its operation.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900127001', 'test127') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test127', 143000, 'GYD', 'DEPOSITO: 143,000 GYD', 'open')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal;

  -- 1. The amounts must add up EXACTLY: 100+100 is not 550 → nothing written.
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"9542184382","nombre":"A B","monto":100,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"8132794817","nombre":"C D","monto":100,"moneda":"USD"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op;
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'suma_no_cuadra' OR v_n <> 0 THEN
    RAISE EXCEPTION 'case 1: a sum that does not match must write nothing, got % (% rows)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 1: a reparto whose amounts do not add up to the deposit is refused';

  -- 2. The real four-person reparto: 4 rows with their amounts, lock, audit.
  v_r := cerebro_aplicar_reparto(v_op, v_cuatro);
  IF NOT (v_r->>'aplicado')::boolean THEN RAISE EXCEPTION 'case 2: should apply, got %', v_r; END IF;
  SELECT count(*) INTO v_n FROM remittance_beneficiaries
   WHERE operation_id = v_op AND status = 'vigente' AND beneficiary_type = 'zelle' AND currency = 'USD'
     AND (zelle_account, amount) IN (('9542184382',100),('8132794817',100),('4633149908',50),('9413105654',300));
  IF v_n <> 4 THEN RAISE EXCEPTION 'case 2: expected the 4 beneficiaries with their amounts, got %', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_operations WHERE id = v_op AND admin_locked_fields ? 'beneficiaries') THEN
    RAISE EXCEPTION 'case 2: the reparto must lock beneficiaries against automation';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id = v_op AND action = 'automation_reparto_registered') THEN
    RAISE EXCEPTION 'case 2: the reparto must leave an audit row';
  END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 2: the 4 Zelle beneficiaries should be complete'; END IF;
  RAISE NOTICE 'PASS 2: the real 4-person reparto (100/100/50/300 = 550) is applied, locked and audited';

  -- 3. Idempotent: the same reparto again changes nothing.
  v_r := cerebro_aplicar_reparto(v_op, v_cuatro);
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op;
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'ya_aplicado' OR v_n <> 4 THEN
    RAISE EXCEPTION 'case 3: re-applying must be a no-op, got % (% rows)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 3: re-applying the same reparto is a no-op';

  -- 4. The Cerebro later writes a single beneficiary into the deal notes:
  --    the lock keeps the reparto intact.
  UPDATE deals SET notes = notes || E'\n---\nBENEFICIARIO ZELLE\nNombre: Mayiannelis Ortega\nCuenta Zelle: 8132794817' WHERE id = v_deal;
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF v_n <> 4 THEN RAISE EXCEPTION 'case 4: a later single-beneficiary note must not replace the reparto (% vigentes)', v_n; END IF;
  RAISE NOTICE 'PASS 4: a later automatic single beneficiary cannot undo the reparto';

  -- 5. The Cerebro had already registered ONE of the reparto accounts: it is
  --    replaced by the full reparto (same account, now with its share).
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test127b', 26000, 'GYD',
          E'DEPOSITO: 26,000 GYD\n---\nBENEFICIARIO ZELLE\nNombre: Vanesa Medina\nCuenta Zelle: 6562442588', 'open')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal;
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"6562442588","nombre":"Vanesa Medina","monto":50,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"9413105654","nombre":"david santillán","monto":50,"moneda":"USD"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF NOT (v_r->>'aplicado')::boolean OR v_n <> 2 THEN
    RAISE EXCEPTION 'case 5: should replace the single beneficiary by the 2-way reparto, got % (% vigentes)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 5: an earlier single beneficiary that is part of the reparto is replaced by the reparto';

  -- 6. A DIFFERENT existing beneficiary: never overwritten.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test127c', 26000, 'GYD',
          E'DEPOSITO: 26,000 GYD\n---\nBENEFICIARIO ZELLE\nNombre: Otra Persona\nCuenta Zelle: 3050000009', 'open')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal;
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"6562442588","nombre":"Vanesa Medina","monto":50,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"9413105654","nombre":"david santillán","monto":50,"moneda":"USD"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente' AND zelle_account = '3050000009';
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'otro_beneficiario' OR v_n <> 1 THEN
    RAISE EXCEPTION 'case 6: a different existing beneficiary must be kept, got % (%)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 6: never overwrites a different existing beneficiary';

  -- 7. A single account is not a reparto.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test127d', 26000, 'GYD', 'DEPOSITO: 26,000 GYD', 'open')
  RETURNING id INTO v_deal;
  SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal;
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"6562442588","nombre":"Vanesa Medina","monto":100,"moneda":"USD"}]');
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'no_es_reparto' THEN
    RAISE EXCEPTION 'case 7: one account is not a reparto, got %', v_r;
  END IF;
  RAISE NOTICE 'PASS 7: a single account is refused as reparto';

  -- 8. A closed operation is never touched.
  UPDATE remittance_operations SET status = 'cancelled', cancelled_at = now() WHERE id = v_op;
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"6562442588","nombre":"Vanesa Medina","monto":50,"moneda":"USD"},
                                         {"tipo":"zelle","cuenta":"9413105654","nombre":"david santillán","monto":50,"moneda":"USD"}]');
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'cerrada' THEN
    RAISE EXCEPTION 'case 8: a closed operation must be refused, got %', v_r;
  END IF;
  RAISE NOTICE 'PASS 8: a closed operation is refused';
END $$;
