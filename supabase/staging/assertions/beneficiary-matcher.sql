-- =====================================================================
-- Assertion for migration 126 (cerebro_resolver_operacion_beneficiario).
-- Self-reverting: run as  BEGIN; \i this file; ROLLBACK;
-- Fixtures reproduce REAL production chats (2026-08/09), with fictitious
-- phones for the customer. Any failure RAISEs; each passing case NOTICEs.
-- =====================================================================
DO $$
DECLARE
  c_estados CONSTANT text[] := ARRAY['collecting_information','deposit_verification','ready_to_transfer','incident'];
  v_user uuid; v_acc uuid;
  v_conv uuid; v_a uuid; v_b uuid; v_r record;
  t0 timestamptz := now() - interval '2 hours';

BEGIN
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;


  ------------------------------------------------------------------
  -- 1. AMOUNT (chat d9e9f333, 24-Sep): 26,000 → "100 zelle" Jose Carlos,
  --    56,000 → "215 Zelle" Liudis. Verified against the team's proofs.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126001', 'test126 monto') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 26000, 'GYD', t0 + interval '45 seconds') RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 56000, 'GYD', t0 + interval '82 seconds') RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', '215 a una tarjeta', t0 - interval '18 minutes'),
    (v_conv, 'customer', 'text', 'Y 100 a otra', t0 - interval '18 minutes'),
    (v_conv, 'customer', 'image', NULL, t0 - interval '2 seconds'),
    (v_conv, 'customer', 'text', '100 zelle', t0 + interval '10 seconds'),
    (v_conv, 'customer', 'text', 'A esta cuenta', t0 + interval '14 seconds'),
    (v_conv, 'customer', 'text', '786 344 7729 Jose Carlos Zayas', t0 + interval '25 seconds'),
    (v_conv, 'customer', 'text', 'Entonces a esta otra cuenta', t0 + interval '39 seconds'),
    (v_conv, 'customer', 'text', 'Liudis Aguilar Rojas (786) 861-3281', t0 + interval '50 seconds'),
    (v_conv, 'customer', 'image', NULL, t0 + interval '56 seconds'),
    (v_conv, 'customer', 'text', '215 Zelle', t0 + interval '62 seconds'),
    (v_conv, 'customer', 'text', 'Liudis Aguilar Rojas (786) 861-3281', t0 + interval '77 seconds');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '7863447729');
  IF v_r.operation_id IS DISTINCT FROM v_a OR v_r.resultado <> 'unica' THEN
    RAISE EXCEPTION 'case 1a: Jose Carlos should go to the 26,000 op (100 USD), got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '7868613281');
  IF v_r.operation_id IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'case 1b: Liudis should go to the 56,000 op (215 USD), got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 1: amount pairs each Zelle with its deposit (Jose Carlos 100, Liudis 215)';

  ------------------------------------------------------------------
  -- 2. PROXIMITY (chat 72240415, 19-Aug): two 13,000 deposits 3 h apart.
  --    Damaris' number 17 s before deposit 1, Daniuska's email 45 s before
  --    deposit 2. Both verified (DB / team proof).
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126002', 'test126 cerca') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 13000, 'GYD', t0 - interval '3 hours') RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 13000, 'GYD', t0) RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', E'+1 (502) 975‑6823\n\nDamaris cambara', t0 - interval '3 hours' - interval '17 seconds'),
    (v_conv, 'customer', 'image', NULL, t0 - interval '3 hours' + interval '36 seconds'),
    (v_conv, 'customer', 'text', 'Daniuskacruz@ iCloud.com', t0 - interval '45 seconds'),
    (v_conv, 'customer', 'image', NULL, t0 - interval '35 seconds');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '5029756823');
  IF v_r.operation_id IS DISTINCT FROM v_a THEN
    RAISE EXCEPTION 'case 2a: Damaris should go to deposit 1, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, 'daniuskacruz@icloud.com');
  IF v_r.operation_id IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'case 2b: Daniuska should go to deposit 2, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 2: proximity pairs each account with the deposit it was sent with';

  ------------------------------------------------------------------
  -- 3. REPARTO (chat 9e338224, 15-Aug): "Son para 4 personas" → never decide.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126003', 'test126 reparto') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 143000, 'GYD', t0) RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 56000, 'GYD', t0 + interval '2 minutes') RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', 'Son para 4 personas le mando las tarjetas en cuanto aga el depósito', t0 - interval '10 minutes'),
    (v_conv, 'customer', 'text', '954 218 4382 humberto rey bernal', t0 + interval '1 minute'),
    (v_conv, 'customer', 'text', 'A esta le pasa 100 zel', t0 + interval '70 seconds');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '9542184382');
  IF v_r.resultado <> 'ambigua' THEN
    RAISE EXCEPTION 'case 3: a reparto must stay ambiguous, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 3: reparto among several people stays ambiguous';

  ------------------------------------------------------------------
  -- 4. NEVER OVER ANOTHER BENEFICIARY: the amount points to an op that
  --    already has a DIFFERENT beneficiary (a correction?) → ambiguous,
  --    even though rule C would otherwise pick the other op.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126004', 'test126 pisar') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 26000, 'GYD', t0) RETURNING id INTO v_a;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, status, position, block_index)
  VALUES (v_a, 'zelle', 'Otra Persona', '3050000001', 'vigente', 1, 1);
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 13000, 'GYD', t0 + interval '30 minutes') RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', 'los 100 zelle a esta', t0 + interval '60 minutes'),
    (v_conv, 'customer', 'text', '3050000002 Nombre Corregido', t0 + interval '61 minutes');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '3050000002');
  IF v_r.resultado <> 'ambigua' THEN
    RAISE EXCEPTION 'case 4: amount points to an op with another beneficiary → must stay ambiguous, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 4: never assigns over another operation''s different beneficiary';

  ------------------------------------------------------------------
  -- 5. RULE C: an abandoned op 2 days old + today's op; account with no
  --    amount and no nearby deposit → today's op.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126005', 'test126 reglac') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'collecting_information', 'remesa', 0, 'GYD', t0 - interval '2 days') RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 20000, 'GYD', t0) RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', E'Yander Flaco\n786 470 4817', t0 + interval '50 minutes');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '7864704817');
  IF v_r.operation_id IS DISTINCT FROM v_b OR v_r.metodo <> 'regla_c' THEN
    RAISE EXCEPTION 'case 5: rule C should pick today''s op, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 5: rule C picks the newest op over an abandoned one';

  ------------------------------------------------------------------
  -- 6. Two recent ops, no amount, no nearby deposit → ambiguous.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126006', 'test126 duda') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 13000, 'GYD', t0) RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 26000, 'GYD', t0 + interval '20 minutes') RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', 'Maria Lopez 3050000003', t0 + interval '70 minutes');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '3050000003');
  IF v_r.resultado <> 'ambigua' THEN
    RAISE EXCEPTION 'case 6: no evidence → must stay ambiguous, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 6: two recent ops with no evidence stay ambiguous';

  ------------------------------------------------------------------
  -- 7. One open op: same answer as cerebro_resolver_operacion.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900126007', 'test126 unica') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 13000, 'GYD', t0) RETURNING id INTO v_a;
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '3050000004');
  IF v_r.operation_id IS DISTINCT FROM v_a OR v_r.resultado <> 'unica' THEN
    RAISE EXCEPTION 'case 7: a single open op must resolve as before, got % / %', v_r.resultado, v_r.operation_id;
  END IF;
  RAISE NOTICE 'PASS 7: a single open op resolves exactly as before';

  ------------------------------------------------------------------
  -- 8. REUSED ACCOUNT WITH AN AMOUNT (chat 1727ef31, migration 133): the same Zelle on 19-Sep
  --    ("125 zelle", 32,500 GYD, already paid but left open) and on 26-Sep ("200 zelle", 52,000
  --    GYD). The data sent on 26-Sep belongs to the 26-Sep remesa (team proof "Envía Yoandis Delis").
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900133008', 'test133 reusada monto') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 32500, 'GYD', t0 - interval '7 days') RETURNING id INTO v_a;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 52000, 'GYD', t0 + interval '1 hour') RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'image', NULL, t0 - interval '7 days'),
    (v_conv, 'customer', 'text', '+1 (502) 539-2681', t0 - interval '7 days' + interval '10 seconds'),
    (v_conv, 'customer', 'text', 'Hola pásame 125 zelle a la cuenta', t0 - interval '7 days' + interval '20 seconds'),
    (v_conv, 'customer', 'text', 'Hola me tomó el puente cerrado tu crees que me puedas pasar 200 zelle hoy aunque sea después de las 5', t0),
    (v_conv, 'customer', 'image', NULL, t0 + interval '1 minute'),
    (v_conv, 'customer', 'text', '+1 (502) 539-2681', t0 + interval '3 minutes'),
    (v_conv, 'customer', 'image', NULL, t0 + interval '1 hour');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '5025392681');
  IF v_r.operation_id IS DISTINCT FROM v_b OR v_r.resultado <> 'unica' THEN
    RAISE EXCEPTION 'case 8: a reused account must go to the NEW remesa (200 USD), got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 8: a reused account goes to the remesa it was sent for now, not to an old one';

  ------------------------------------------------------------------
  -- 9. REUSED ACCOUNT WITHOUT AN AMOUNT (chat de846b30): DTZ sent on 14-Sep (that remesa already
  --    has DTZ) and again on 18-Sep for a new 26,200 deposit. The new remesa must get it.
  ------------------------------------------------------------------
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '59900133009', 'test133 reusada') RETURNING id INTO v_a;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_a) RETURNING id INTO v_conv;
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 39000, 'GYD', t0 - interval '4 days') RETURNING id INTO v_a;
  -- (250) The old remesa's payee row is dated when it was written (14-Sep), before the account was typed again.
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, zelle_account, created_at)
  VALUES (v_a, 'zelle', 'DTZ SOLUTION LLC', '2294563108', t0 - interval '4 days');
  INSERT INTO remittance_operations (account_id, conversation_id, status, service_type, quoted_source_amount, source_currency, created_at)
  VALUES (v_acc, v_conv, 'ready_to_transfer', 'remesa', 26200, 'GYD', t0 + interval '70 minutes') RETURNING id INTO v_b;
  INSERT INTO messages (conversation_id, sender_type, content_type, content_text, created_at) VALUES
    (v_conv, 'customer', 'text', E'Zelle mínimo 50\nDTZ SOLUTION LLC\n\n+1 229 456 3108', t0 - interval '4 days' - interval '1 minute'),
    (v_conv, 'customer', 'text', E'Zelle mínimo 50\nDTZ SOLUTION LLC\n\n+1 229 456 3108', t0),
    (v_conv, 'customer', 'image', NULL, t0 + interval '70 minutes');
  SELECT * INTO v_r FROM cerebro_resolver_operacion_beneficiario(v_conv, c_estados, '2294563108');
  IF v_r.operation_id IS DISTINCT FROM v_b OR v_r.resultado <> 'unica' THEN
    RAISE EXCEPTION 'case 9: a reused account without amount must go to the NEW remesa, got % / % (%)', v_r.resultado, v_r.operation_id, v_r.metodo;
  END IF;
  RAISE NOTICE 'PASS 9: a reused account without amount goes to the new remesa';
END $$;

-- Convention: reaching this point means every case above passed.
DO $$ BEGIN RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'; END $$;
