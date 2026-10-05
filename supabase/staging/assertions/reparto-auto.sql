-- =====================================================================
-- Assertion for migration 127 (cerebro_aplicar_reparto).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- (2026-10-05) Fixture rebuilt: each operation comes from cerebro_crear_operacion (a deal no longer creates one since 161/172/183) with the
-- deal linked to it; the user and account come from whatsapp_config + profiles instead of `FROM conversations LIMIT 1`.
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
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;

  -- A deal in "Lista para transferir" for 143,000 GYD; 125 creates its operation.
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900127001', 'test127') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test127', 143000, 'GYD', 'DEPOSITO: 143,000 GYD', 'open')
  RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 143000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists

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
  v_op := cerebro_crear_operacion(v_conv, 26000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
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
  v_op := cerebro_crear_operacion(v_conv, 26000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
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
  v_op := cerebro_crear_operacion(v_conv, 26000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
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
  -- 9. MIXED (migration 129): 2 cards x 5,000 GYD (15,000 CUP at 3) + 55 USD Zelle = 24,300 GYD exact
  --    (chat 67c1aa23, 11-Aug, the reparto the bot confirmed to the customer).
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test129a', 24300, 'GYD', 'DEPOSITO: 24,300 GYD', 'open')
  RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 24300, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"cuban_card","cuenta":"9238129972337028","celular":"51292073","monto":15000,"moneda":"CUP"},
                                         {"tipo":"cuban_card","cuenta":"9238959871823862","celular":"51292073","monto":15000,"moneda":"CUP"},
                                         {"tipo":"zelle","cuenta":"3059631942","nombre":"Richel Moreno Ramos","monto":55,"moneda":"USD"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente';
  IF NOT (v_r->>'aplicado')::boolean OR v_n <> 3 THEN RAISE EXCEPTION 'case 9: mixed exact reparto should apply, got % (%)', v_r, v_n; END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 9: the mixed reparto should be complete'; END IF;
  RAISE NOTICE 'PASS 9: a mixed cards + Zelle reparto that covers the deposit exactly is applied';

  -- 10. MIXED with the Zelle rounded down (chat 1c49bcb0 shape): 226 USD + 10,000 + 5,000 GYD
  --     (30,000 + 15,000 CUP) = 73,760 of a 74,000 deposit: 240 GYD left, less than 1 USD → applied.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test129b', 74000, 'GYD', 'DEPOSITO: 74,000 GYD', 'open')
  RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 74000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"naranjoraciel@gmail.com","nombre":"Raciel Díaz","monto":226,"moneda":"USD"},
                                         {"tipo":"cuban_card","cuenta":"9224069994566921","celular":"51265782","monto":30000,"moneda":"CUP"},
                                         {"tipo":"cuban_card","cuenta":"9224069996547903","celular":"58192752","monto":15000,"moneda":"CUP"}]');
  IF NOT (v_r->>'aplicado')::boolean THEN RAISE EXCEPTION 'case 10: less than 1 USD left over should be accepted, got %', v_r; END IF;
  RAISE NOTICE 'PASS 10: a mixed reparto leaving less than 1 USD (Zelle rounded down) is applied';

  -- 11. MIXED that leaves 1 USD or more uncovered → refused, nothing written.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test129c', 74000, 'GYD', 'DEPOSITO: 74,000 GYD', 'open')
  RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 74000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"zelle","cuenta":"naranjoraciel@gmail.com","nombre":"Raciel Díaz","monto":225,"moneda":"USD"},
                                         {"tipo":"cuban_card","cuenta":"9224069994566921","celular":"51265782","monto":30000,"moneda":"CUP"},
                                         {"tipo":"cuban_card","cuenta":"9224069996547903","celular":"58192752","monto":15000,"moneda":"CUP"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op;
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'suma_no_cuadra' OR v_n <> 0 THEN
    RAISE EXCEPTION 'case 11: a mixed reparto leaving 500 GYD uncovered must be refused, got % (%)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 11: a mixed reparto that does not cover the deposit is refused';

  -- 12. NEW CUBAN MOBILES (migration 130): ETECSA gives new lines numbers that start with 63
  --     (since 2023-12-30). Real phone 63691728 (chat 54454232, 21-Aug), rejected by the old rule.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test130a', 40000, 'GYD', 'DEPOSITO: 40,000 GYD', 'open')
  RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 40000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"cuban_card","cuenta":"9224959876682574","celular":"63691728","monto":60000,"moneda":"CUP"},
                                         {"tipo":"cuban_card","cuenta":"9204959875209704","celular":"+53 5474 3463","monto":60000,"moneda":"CUP"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente'
     AND phone IN ('63691728', '54743463');
  IF NOT (v_r->>'aplicado')::boolean OR v_n <> 2 THEN RAISE EXCEPTION 'case 12: a 63xxxxxx mobile must be accepted, got % (%)', v_r, v_n; END IF;
  IF NOT crm_beneficiarios_completos(v_op) THEN RAISE EXCEPTION 'case 12: a card with a 63xxxxxx mobile should be complete'; END IF;
  RAISE NOTICE 'PASS 12: a new Cuban mobile starting with 63 is accepted';

  -- 13. Any other 6-prefix is still not a Cuban mobile → refused, nothing written.
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, notes, status)
  VALUES (v_user, v_acc, v_ct, v_conv, c_pipeline, c_lista, 'test130b', 40000, 'GYD', 'DEPOSITO: 40,000 GYD', 'open')
  RETURNING id INTO v_deal;
  v_op := cerebro_crear_operacion(v_conv, 40000, 'GYD', c_lista);
  UPDATE remittance_operations SET deal_id = v_deal WHERE id = v_op;
  UPDATE deals SET notes = notes WHERE id = v_deal;  -- re-fire the notes sync now that the operation exists
  v_r := cerebro_aplicar_reparto(v_op, '[{"tipo":"cuban_card","cuenta":"9224959876682574","celular":"64691728","monto":60000,"moneda":"CUP"},
                                         {"tipo":"cuban_card","cuenta":"9204959875209704","celular":"54743463","monto":60000,"moneda":"CUP"}]');
  SELECT count(*) INTO v_n FROM remittance_beneficiaries WHERE operation_id = v_op;
  IF (v_r->>'aplicado')::boolean OR v_r->>'motivo' <> 'formato' OR v_n <> 0 THEN
    RAISE EXCEPTION 'case 13: a 64xxxxxx number must be refused, got % (%)', v_r, v_n;
  END IF;
  RAISE NOTICE 'PASS 13: other numbers starting with 6 are still refused';
END $$;
