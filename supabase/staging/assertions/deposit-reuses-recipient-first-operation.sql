\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 232 (a deposit reuses the open operation that carries no money yet).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Production 2026-10-08 (Edel): the recipient + cash rail were set on a 0 GYD operation A before the receipt; the deposit
-- (29,000) opened a second operation B because the "movido" lookup excluded A (vigente recipient AND saldo > 0, where
-- the saldo reads the conversation's open quote). Rule asserted: an open remesa that holds NO money (quoted_source_amount 0,
-- no receipt row, nothing deposited), is not in incident and has no locked amount IS the deposit's target, whatever the quote.
-- Operations that hold money keep the 160 guard. Ambiguity (two candidates): the latest wins, as before.
-- =====================================================================

CREATE FUNCTION pg_temp.t232_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990232' || lpad(p_n::text, 4, '0'), 'T232 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

-- an operation of the conversation; p_age_min orders them (older = bigger)
CREATE FUNCTION pg_temp.t232_op(p_c record, p_status text, p_svc text, p_amt numeric, p_rail text, p_age_min int, p_recipient boolean)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, service_type,
                                     quoted_source_amount, source_currency, delivery_method, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, NULL, p_status, p_svc, p_amt, 'GYD', p_rail,
          now() - make_interval(mins => p_age_min))
  RETURNING id INTO v_op;
  IF p_recipient THEN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, position, block_index, source, status)
    VALUES (v_op, CASE WHEN p_rail = 'efectivo_usd' THEN 'efectivo_usd' ELSE 'zelle' END, 'Receptor T232', '52123456', 1, 1,
            'notes_parse', 'vigente');
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t232_quote(p_conv uuid, p_amt numeric) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda) VALUES (p_conv, p_amt, 'GYD');
$f$;

CREATE FUNCTION pg_temp.t232_dep(p_conv uuid, p_amt numeric, p_n int) RETURNS record LANGUAGE plpgsql AS $f$
DECLARE v_ref numeric; v_r record; v_comp text := 'COMP-' || substring(md5('t232-' || p_n), 1, 20);
BEGIN
  SELECT COALESCE((SELECT max(trans_id::numeric) FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$'), 20000000000000) + 100 + p_n INTO v_ref;
  SELECT * INTO v_r FROM cerebro_registrar_deposito(p_conv, p_amt, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid,
    'DEPOSITO: ' || p_amt || ' GYD - APROBADA' || chr(10) || 'Via: Agente MMG;' || chr(10) || 'Ref: ' || v_ref::bigint || chr(10) || v_comp, v_comp);
  RETURN v_r;
END $f$;

CREATE FUNCTION pg_temp.t232_open(p_conv uuid) RETURNS int LANGUAGE sql AS $f$
  SELECT count(*)::int FROM remittance_operations WHERE conversation_id = p_conv AND status NOT IN ('completed', 'cancelled');
$f$;

DO $$
DECLARE
  c record; v_a uuid; v_b uuid; v_r record; v_o remittance_operations%ROWTYPE;
BEGIN
  -- ---- E: THE EDEL SEQUENCE ------------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(1);
  v_a := pg_temp.t232_op(c, 'collecting_information', 'remesa', 0, NULL, 120, true);       -- recipient first, 0 GYD
  PERFORM pg_temp.t232_quote(c.conv, 26000);                                                -- open quote, tied to no operation
  UPDATE remittance_operations SET delivery_method = 'efectivo_usd' WHERE id = v_a;         -- marcar_destino_usd('efectivo')
  UPDATE remittance_beneficiaries SET beneficiary_type = 'efectivo_usd' WHERE operation_id = v_a;
  v_r := pg_temp.t232_dep(c.conv, 29000, 1);
  IF (v_r.accion, v_r.deal_id) IS DISTINCT FROM ('movido', v_a) THEN
    RAISE EXCEPTION 'case E: the deposit must reuse the recipient-first operation, got % %', v_r.accion, v_r.deal_id; END IF;
  IF pg_temp.t232_open(c.conv) <> 1 THEN RAISE EXCEPTION 'case E: exactly ONE open operation expected, got %', pg_temp.t232_open(c.conv); END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_a;
  IF v_o.quoted_source_amount <> 29000 OR v_o.delivery_method <> 'efectivo_usd' OR v_o.status <> 'deposit_verification' THEN
    RAISE EXCEPTION 'case E: the operation must carry the deposit and the cash rail: %', to_jsonb(v_o); END IF;
  IF (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_a AND status = 'vigente' AND beneficiary_type = 'efectivo_usd') <> 1 THEN
    RAISE EXCEPTION 'case E: the recipient must stay on the operation'; END IF;
  IF (SELECT operation_id FROM cerebro_objetivo_envio WHERE conversation_id = c.conv) IS DISTINCT FROM v_a THEN
    RAISE EXCEPTION 'case E: the open quote must be tied to the operation'; END IF;
  IF (SELECT count(*) FROM remittance_operation_receipts WHERE operation_id = v_a) <> 1 THEN
    RAISE EXCEPTION 'case E: the receipt must hang from the operation'; END IF;
  RAISE NOTICE 'PASS case E: the Edel sequence ends with one operation carrying deposit, cash rail and recipient';

  -- ---- G1: an operation that already holds money (amount) AND a recipient keeps the guard -------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(2);
  v_a := pg_temp.t232_op(c, 'awaiting_deposit', 'remesa', 40000, 'zelle', 120, true);
  PERFORM pg_temp.t232_quote(c.conv, 52000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 2);
  IF v_r.accion <> 'creado' OR v_r.deal_id = v_a OR pg_temp.t232_open(c.conv) <> 2 THEN
    RAISE EXCEPTION 'case G1: money + recipient + saldo must keep the guard (a new operation), got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case G1: an operation with money and a recipient is not reused';

  -- ---- G2: a receipt row without a comp id counts as money ---------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(3);
  v_a := pg_temp.t232_op(c, 'awaiting_deposit', 'remesa', 0, 'zelle', 120, true);
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, source, block_index)
  VALUES (v_a, c.conv, NULL, 5000, 'GYD', 'bot', 1);
  PERFORM pg_temp.t232_quote(c.conv, 52000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 3);
  IF v_r.accion <> 'creado' OR v_r.deal_id = v_a THEN RAISE EXCEPTION 'case G2: a receipt row is money: got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case G2: an operation with a receipt row is not reused';

  -- ---- G3: two open zero-amount operations: the OLDEST wins (291: the send's anchor, owner rule), the newer one is untouched -------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(4);
  v_a := pg_temp.t232_op(c, 'collecting_information', 'remesa', 0, 'zelle', 300, true);   -- older
  v_b := pg_temp.t232_op(c, 'collecting_information', 'remesa', 0, 'efectivo_usd', 100, true);  -- newer
  PERFORM pg_temp.t232_quote(c.conv, 26000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 4);
  IF v_r.accion <> 'movido' OR v_r.deal_id <> v_a THEN RAISE EXCEPTION 'case G3: the oldest candidate (the anchor) must win, got % %', v_r.accion, v_r.deal_id; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_b) <> 0 OR pg_temp.t232_open(c.conv) <> 2 THEN
    RAISE EXCEPTION 'case G3: the newer operation must stay untouched'; END IF;
  RAISE NOTICE 'PASS case G3: ambiguity is decided by the send anchor (the oldest open operation)';

  -- ---- G4: a zero-amount operation in incident is not widened -----------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(5);
  v_a := pg_temp.t232_op(c, 'incident', 'remesa', 0, 'zelle', 120, true);
  PERFORM pg_temp.t232_quote(c.conv, 26000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 5);
  IF v_r.accion <> 'creado' OR v_r.deal_id = v_a THEN RAISE EXCEPTION 'case G4: an incident operation is not reused: got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case G4: an operation in incident is not reused by the new rule';

  -- ---- G5: a zero-amount operation whose amount is locked is not widened -------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(6);
  v_a := pg_temp.t232_op(c, 'awaiting_deposit', 'remesa', 0, 'zelle', 120, true);
  PERFORM set_config('wacrm.origin', 'admin', true);   -- the lock map is writable only by a human / asserted admin context (096)
  UPDATE remittance_operations SET admin_locked_fields = jsonb_build_object('quoted_source_amount', jsonb_build_object('by', 'human')) WHERE id = v_a;
  PERFORM set_config('wacrm.origin', '', true);
  IF NOT (SELECT admin_locked_fields ? 'quoted_source_amount' FROM remittance_operations WHERE id = v_a) THEN RAISE EXCEPTION 'setup G5: the lock was not stored'; END IF;
  PERFORM pg_temp.t232_quote(c.conv, 26000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 6);
  IF v_r.accion <> 'creado' OR v_r.deal_id = v_a THEN RAISE EXCEPTION 'case G5: a locked amount is not reused: got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case G5: an operation with a locked amount is not reused by the new rule';

  -- ---- U1: no open operation: a deposit creates one (unchanged) ----------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(7);
  v_r := pg_temp.t232_dep(c.conv, 29000, 7);
  IF v_r.accion <> 'creado' OR pg_temp.t232_open(c.conv) <> 1 THEN RAISE EXCEPTION 'case U1: got %', v_r.accion; END IF;
  RAISE NOTICE 'PASS case U1: no open operation -> creado';

  -- ---- U2: recipient, money in the amount, NO open quote (saldo NULL) -> reused as before ----------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(8);
  v_a := pg_temp.t232_op(c, 'awaiting_deposit', 'remesa', 40000, 'zelle', 120, true);
  v_r := pg_temp.t232_dep(c.conv, 29000, 8);
  IF v_r.accion <> 'movido' OR v_r.deal_id <> v_a THEN RAISE EXCEPTION 'case U2 (160 behaviour): got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case U2: recipient + amount but no saldo is still the movido target (160 unchanged)';

  -- ---- U3: no recipient, open quote -> reused as before -------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(9);
  v_a := pg_temp.t232_op(c, 'awaiting_deposit', 'remesa', 0, NULL, 120, false);
  PERFORM pg_temp.t232_quote(c.conv, 26000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 9);
  IF v_r.accion <> 'movido' OR v_r.deal_id <> v_a THEN RAISE EXCEPTION 'case U3: got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case U3: no recipient -> movido (unchanged)';

  -- ---- U4: funded operation waiting for the rest -> sumado (unchanged) ----------------------------------------------------
  SELECT * INTO c FROM pg_temp.t232_conv(10);
  v_a := pg_temp.t232_op(c, 'deposit_verification', 'remesa', 3000, 'zelle', 10, true);
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency, source, block_index)
  VALUES (v_a, c.conv, 'COMP-t232-u4-first', 3000, 'GYD', 'bot', 1);
  PERFORM pg_temp.t232_quote(c.conv, 20000);
  v_r := pg_temp.t232_dep(c.conv, 5000, 10);
  IF v_r.accion <> 'sumado al envio abierto' OR v_r.deal_id <> v_a THEN RAISE EXCEPTION 'case U4: got % %', v_r.accion, v_r.deal_id; END IF;
  RAISE NOTICE 'PASS case U4: a funded operation still takes the next deposit as sumado';

  -- ---- I1: non-remesa zero-amount operation (informational): what a remittance deposit does with an open visa -------------
  SELECT * INTO c FROM pg_temp.t232_conv(11);
  v_a := pg_temp.t232_op(c, 'collecting_information', 'visa', 0, NULL, 120, true);
  PERFORM pg_temp.t232_quote(c.conv, 26000);
  v_r := pg_temp.t232_dep(c.conv, 29000, 11);
  RAISE NOTICE 'INFO case I1 (open zero-amount visa + deposit): % service of the target = %', v_r.accion,
    (SELECT service_type FROM remittance_operations WHERE id = v_r.deal_id);

  RAISE NOTICE 'ALL PASS (deposit-reuses-recipient-first-operation)';
END $$;

ROLLBACK;
