-- =====================================================================
-- Assertion for migration 384 (the deposit objective follows a corrected amount).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.
-- Run it wrapped by infra/db/staging-migracion.sh.
-- Synthetic fixtures only: contacts 'PRUEBA384 a'..'f', phones 5990384001..5990384006.
--
-- 320 seeds the objective from the operation only when no objective is open, so a correction made while the
-- objective already belongs to the same operation left it behind (staging, 2026-11-17: operation 83988f69
-- corrected 24400 -> 29000, objective stayed 24400 and the card contradicted itself). 384 adds a third branch
-- that only follows a corrected amount for the open objective of THIS operation. Cases:
--   a  owner corrects through crm_corregir_operacion an awaiting_deposit operation whose open objective
--      belongs to it: the objective follows, stays open and the operation keeps the new amount
--   b  a direct UPDATE of quoted_source_amount (the trigger path, e.g. a service recalculation) also makes the
--      objective follow
--   c  a conversation-level objective (operation_id NULL) is left untouched by a later correction
--   d  another operation's open objective is left untouched: two open operations in one conversation,
--      correcting the second one keeps the first one's objective
--   e  a completed operation keeps its old objective value (the 383 closed-edit path only edits the operation,
--      the objective is already closed)
--   f  an operation with a consumed deposit is left untouched
-- Every case also checks that no extra objective row appeared (the table holds one row per conversation).
-- =====================================================================
\set ON_ERROR_STOP on
DO $$
DECLARE
  v_user uuid; v_acc uuid; v_ct uuid; v_conv uuid; v_op uuid; v_op2 uuid; v_obj cerebro_objetivo_envio; v_n int;
BEGIN
  SELECT p.user_id, w.account_id INTO v_user, v_acc FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);

  -- a. owner corrects an awaiting_deposit operation whose open objective belongs to it
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990384001', 'PRUEBA384 a') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 24400, 'zelle') RETURNING id INTO v_op;
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.operation_id IS DISTINCT FROM v_op OR v_obj.monto IS DISTINCT FROM 24400 OR v_obj.cerrado_en IS NOT NULL THEN
    RAISE EXCEPTION 'case a: setup: the objective was not seeded from the operation: %', to_jsonb(v_obj); END IF;
  PERFORM crm_corregir_operacion(v_op, '{"quoted_source_amount": 29000}'::jsonb);
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.monto IS DISTINCT FROM 29000 THEN
    RAISE EXCEPTION 'case a: the objective did not follow the corrected amount: %', v_obj.monto; END IF;
  IF v_obj.cerrado_en IS NOT NULL THEN RAISE EXCEPTION 'case a: the objective must stay open'; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 29000 THEN
    RAISE EXCEPTION 'case a: the operation amount was not corrected'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case a: expected one objective row, found %', v_n; END IF;

  -- b. a direct UPDATE of quoted_source_amount (the trigger path) also makes the objective follow
  UPDATE remittance_operations SET quoted_source_amount = 31000 WHERE id = v_op;
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.monto IS DISTINCT FROM 31000 THEN
    RAISE EXCEPTION 'case b: the objective did not follow a direct amount update: %', v_obj.monto; END IF;
  IF v_obj.cerrado_en IS NOT NULL THEN RAISE EXCEPTION 'case b: the objective must stay open'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case b: expected one objective row, found %', v_n; END IF;

  -- c. a conversation-level objective (operation_id NULL) is left untouched
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990384002', 'PRUEBA384 c') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 24400, 'zelle') RETURNING id INTO v_op;
  UPDATE cerebro_objetivo_envio SET operation_id = NULL, monto = 20000, pedido = 'PRUEBA384 c' WHERE conversation_id = v_conv;
  PERFORM crm_corregir_operacion(v_op, '{"quoted_source_amount": 32000}'::jsonb);
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.monto IS DISTINCT FROM 20000 THEN
    RAISE EXCEPTION 'case c: a conversation-level objective must not follow: %', v_obj.monto; END IF;
  IF v_obj.operation_id IS NOT NULL THEN RAISE EXCEPTION 'case c: the objective must stay conversation-level'; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 32000 THEN
    RAISE EXCEPTION 'case c: the operation amount was not corrected'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case c: expected one objective row, found %', v_n; END IF;

  -- d. another operation's open objective is left untouched
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990384003', 'PRUEBA384 d') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 24400, 'zelle') RETURNING id INTO v_op;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 25000, 'zelle') RETURNING id INTO v_op2;
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.operation_id IS DISTINCT FROM v_op OR v_obj.monto IS DISTINCT FROM 24400 THEN
    RAISE EXCEPTION 'case d: setup: the objective does not belong to the first operation: %', to_jsonb(v_obj); END IF;
  PERFORM crm_corregir_operacion(v_op2, '{"quoted_source_amount": 26000}'::jsonb);
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.monto IS DISTINCT FROM 24400 OR v_obj.operation_id IS DISTINCT FROM v_op THEN
    RAISE EXCEPTION 'case d: another operation''s objective must not follow: %', to_jsonb(v_obj); END IF;
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case d: expected one objective row, found %', v_n; END IF;

  -- e. a completed operation keeps its old objective value
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990384004', 'PRUEBA384 e') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 24400, 'zelle') RETURNING id INTO v_op;
  PERFORM set_config('wacrm.origin', 'admin', true);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM set_config('wacrm.origin', '', true);
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.cerrado_en IS NULL THEN RAISE EXCEPTION 'case e: setup: the objective was not closed with the operation'; END IF;
  PERFORM crm_corregir_operacion(v_op, '{"quoted_source_amount": 30000}'::jsonb);
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.monto IS DISTINCT FROM 24400 THEN
    RAISE EXCEPTION 'case e: a closed operation must not move the objective: %', v_obj.monto; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 30000 THEN
    RAISE EXCEPTION 'case e: the closed operation edit was not applied'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case e: expected one objective row, found %', v_n; END IF;

  -- f. an operation with a consumed deposit is left untouched
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '5990384005', 'PRUEBA384 f') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (v_acc, v_conv, v_ct, 'awaiting_deposit', 'remesa', 'GYD', 24400, 'zelle') RETURNING id INTO v_op;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id, consumido_en)
  VALUES ('PRUEBA384-5990384005', 24400, 'GYD', 'PRUEBA 5990384005', now(), v_op, now());
  PERFORM crm_corregir_operacion(v_op, '{"quoted_source_amount": 33000}'::jsonb);
  SELECT * INTO v_obj FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_obj.monto IS DISTINCT FROM 24400 THEN
    RAISE EXCEPTION 'case f: an operation with a consumed deposit must not move the objective: %', v_obj.monto; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 33000 THEN
    RAISE EXCEPTION 'case f: the operation amount was not corrected'; END IF;
  SELECT count(*) INTO v_n FROM cerebro_objetivo_envio WHERE conversation_id = v_conv;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case f: expected one objective row, found %', v_n; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
