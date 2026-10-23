\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 255 (the bot splits one customer deposit across services: cerebro_repartir_envio).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Rule asserted: the wrapper parses the model's free text ("clasica 18200, recarga 6200"), finds the conversation's
-- deposit-holding open operation, runs the split WITHOUT any account membership (the bot has no auth.uid()), locks
-- quoted_source_amount on every member, records the bot as the audit actor, answers in Spanish, and turns every business
-- refusal into a Spanish sentence without writing anything. odd/tasks/mixed-send-split-deposit.md (S4a).
-- =====================================================================

CREATE FUNCTION pg_temp.t255_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990255' || lpad(p_n::text, 4, '0'), 'T255 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t255_op(p_c record, p_status text, p_svc text, p_rail text, p_amt numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, p_status, p_svc, p_rail, 'GYD', p_amt) RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t255_dep(p_op uuid, p_amt numeric, p_n int) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_ref text;
BEGIN
  SELECT (COALESCE((SELECT max(trans_id::numeric) FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$'), 20000000000000) + 100 + p_n)::bigint::text
    INTO v_ref;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id, consumido_en)
  VALUES (v_ref, p_amt, 'GYD', 'test255', now(), p_op, now());
  RETURN v_ref;
END $f$;

-- The f8b7779c situation: a remesa holding the whole 24,400 deposit (93 USD, incident) and an empty recarga.
CREATE FUNCTION pg_temp.t255_replay(p_n int) RETURNS TABLE(conv uuid, rem uuid, rec uuid)
LANGUAGE plpgsql AS $f$
DECLARE c record; v_rem uuid; v_rec uuid;
BEGIN
  SELECT * INTO c FROM pg_temp.t255_conv(p_n);
  v_rem := pg_temp.t255_op(c, 'incident', 'remesa', 'clasica', 24400);
  UPDATE remittance_operations SET incident_reason = 'verificado_de_mas' WHERE id = v_rem;
  v_rec := pg_temp.t255_op(c, 'collecting_information', 'recarga', NULL, NULL);
  PERFORM pg_temp.t255_dep(v_rem, 24400, p_n);
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, operation_id) VALUES (c.conv, 18200, 'GYD', v_rem);
  RETURN QUERY SELECT c.conv, v_rem, v_rec;
END $f$;

DO $$
DECLARE
  c record; r record; r2 record; v_t text; v_t2 text; v_o remittance_operations%ROWTYPE; v_rate numeric := crm_tasa_vigente('usd');
  v_p jsonb; v_n int; v_ops int; v_aud int; v_s record; v_op uuid; v_cv uuid;
BEGIN
  IF v_rate IS NULL OR v_rate <= 0 THEN RAISE EXCEPTION 'fixture: no usd rate'; END IF;
  -- the bot has no authenticated user
  PERFORM set_config('request.jwt.claims', '', true);
  IF auth.uid() IS NOT NULL THEN RAISE EXCEPTION 'fixture: auth.uid() must be null for the bot path'; END IF;

  -- ---- 1. THE f8b7779c REPLAY THROUGH THE WRAPPER -------------------------------------------------------------------
  SELECT * INTO r FROM pg_temp.t255_replay(1);
  v_t := cerebro_repartir_envio(r.conv, 'clasica 18200, recarga 6200', 'exec-t255-1');
  IF v_t NOT LIKE 'Reparto hecho:%' THEN RAISE EXCEPTION 'case 1: expected "Reparto hecho", got %', v_t; END IF;
  IF v_t NOT LIKE '%clasica 18,200 GYD (' || floor(18200 / v_rate) || ' USD)%' OR v_t NOT LIKE '%recarga 6,200 GYD%'
     OR v_t NOT LIKE '%24,400 GYD verificado%' OR v_t NOT LIKE '%listo para transferir%' THEN
    RAISE EXCEPTION 'case 1: the summary lacks a part, the USD amount or the group state: %', v_t; END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = r.rem;
  IF v_o.quoted_source_amount <> 18200 OR v_o.quoted_destination_amount IS DISTINCT FROM floor(18200 / v_rate)
     OR v_o.destination_currency IS DISTINCT FROM 'USD' OR v_o.status <> 'ready_to_transfer' OR v_o.incident_reason IS NOT NULL
     OR v_o.mixed_group_id IS DISTINCT FROM r.rem OR NOT (v_o.admin_locked_fields ? 'quoted_source_amount') THEN
    RAISE EXCEPTION 'case 1: remesa must be 18200 -> floor(18200/rate) USD, ready, grouped and locked; got % % % % % %',
      v_o.quoted_source_amount, v_o.quoted_destination_amount, v_o.status, v_o.incident_reason, v_o.mixed_group_id, v_o.admin_locked_fields; END IF;
  IF v_o.admin_locked_fields ? 'quoted_destination_amount' OR v_o.admin_locked_fields ? 'destination_currency' THEN
    RAISE EXCEPTION 'case 1: the calculated destination must stay unlocked: %', v_o.admin_locked_fields; END IF;
  IF v_o.admin_locked_fields -> 'quoted_source_amount' ->> 'by' <> 'automation:cerebro_repartir_envio' THEN
    RAISE EXCEPTION 'case 1: the lock must name the bot: %', v_o.admin_locked_fields; END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = r.rec;
  IF v_o.quoted_source_amount <> 6200 OR v_o.mixed_group_id IS DISTINCT FROM r.rem OR v_o.status <> 'ready_to_transfer'
     OR NOT (v_o.admin_locked_fields ? 'quoted_source_amount') THEN
    RAISE EXCEPTION 'case 1: recarga must be 6200, grouped, ready and locked: % % % %', v_o.quoted_source_amount, v_o.mixed_group_id, v_o.status, v_o.admin_locked_fields; END IF;
  SELECT count(*) INTO v_aud FROM remittance_admin_audit
   WHERE row_id IN (r.rem, r.rec) AND field_name = 'mixed_split' AND action = 'automation_mixed_split'
     AND actor = 'automation:cerebro_repartir_envio';
  IF v_aud <> 2 OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id IN (r.rem, r.rec) AND field_name = 'mixed_split'
                            AND actor <> 'automation:cerebro_repartir_envio') THEN
    RAISE EXCEPTION 'case 1: both audit rows must name the bot (got % of 2)', v_aud; END IF;
  IF coalesce(current_setting('wacrm.origin', true), '') <> '' OR coalesce(current_setting('wacrm.actor', true), '') <> '' THEN
    RAISE EXCEPTION 'case 1: the admin context must be restored after the call'; END IF;
  -- the lock is real: a later automation cannot overwrite a share
  UPDATE remittance_operations SET quoted_source_amount = 99999 WHERE id IN (r.rem, r.rec);
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE id IN (r.rem, r.rec) AND quoted_source_amount = 99999) THEN
    RAISE EXCEPTION 'case 1: an automation write must not overwrite a locked share'; END IF;
  IF NOT EXISTS (SELECT 1 FROM tool_execution_log WHERE tool_name = 'repartir_envio' AND conversation_id = r.conv AND outcome = 'repartido') THEN
    RAISE EXCEPTION 'case 1: one tool_execution_log line expected'; END IF;

  -- ---- 2. "18.200 clasica y 6,200 recarga" PARSES THE SAME ----------------------------------------------------------
  SELECT * INTO r2 FROM pg_temp.t255_replay(2);
  v_t2 := cerebro_repartir_envio(r2.conv, '18.200 clasica y 6,200 recarga', 'exec-t255-2');
  IF v_t2 IS DISTINCT FROM v_t THEN RAISE EXCEPTION 'case 2: same answer expected, got % vs %', v_t2, v_t; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = r2.rem) <> 18200
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = r2.rec) <> 6200 THEN
    RAISE EXCEPTION 'case 2: shares not applied'; END IF;
  -- more spellings, each through the parser alone
  FOR v_p IN SELECT _cerebro_partes_envio_parse(x) FROM unnest(ARRAY[
      'Clásica 18 200 GYD; Recarga 6.200', E'clasica 18200\nrecarga: 6200', 'clasica $18,200, recarga 6,200 gyd']) AS x LOOP
    IF v_p IS DISTINCT FROM '{"ok":true,"partes":[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]}'::jsonb THEN
      RAISE EXCEPTION 'case 2: parser spelling failed: %', v_p; END IF;
  END LOOP;

  -- ---- 3. SUM MISMATCH: Spanish refusal with both numbers, nothing changes ----------------------------------------------
  SELECT * INTO r FROM pg_temp.t255_replay(3);
  v_t := cerebro_repartir_envio(r.conv, 'clasica 18200, recarga 6000', 'exec-t255-3');
  -- (277) the refusal became facts: same two numbers, nothing changed, plus the planned parts and the difference.
  IF v_t NOT LIKE 'REPARTO NO APLICADO%' OR v_t NOT LIKE '%24,200%' OR v_t NOT LIKE '%24,400%' OR v_t NOT LIKE '%No se cambio nada%' THEN
    RAISE EXCEPTION 'case 3: Spanish refusal with both numbers expected, got %', v_t; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE id IN (r.rem, r.rec) AND mixed_group_id IS NOT NULL)
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = r.rem) <> 24400
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = r.rec) IS NOT NULL
     OR (SELECT count(*) FROM remittance_operations WHERE conversation_id = r.conv) <> 2
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id IN (r.rem, r.rec) AND field_name = 'mixed_split') THEN
    RAISE EXCEPTION 'case 3: a refusal must change nothing'; END IF;
  IF coalesce(current_setting('wacrm.origin', true), '') <> '' THEN RAISE EXCEPTION 'case 3: admin context leaked'; END IF;

  -- ---- 4. UNKNOWN SERVICE WORD: "no entendi", nothing changes ------------------------------------------------------------
  SELECT * INTO r FROM pg_temp.t255_replay(4);
  v_t := cerebro_repartir_envio(r.conv, 'clasica 18200, pizza 6200', 'exec-t255-4');
  IF lower(v_t) NOT LIKE 'no entendi%' OR v_t NOT LIKE '%pizza%' OR v_t NOT LIKE '%clasica 18200, recarga 6200%' THEN
    RAISE EXCEPTION 'case 4: "no entendi" naming the part and the format expected, got %', v_t; END IF;
  v_t := cerebro_repartir_envio(r.conv, 'clasica y recarga', 'exec-t255-4b');
  IF lower(v_t) NOT LIKE 'no entendi%' THEN RAISE EXCEPTION 'case 4: a part without amount must not be understood, got %', v_t; END IF;
  v_t := cerebro_repartir_envio(r.conv, '70 usd clasica, recarga 6200', 'exec-t255-4c');
  IF lower(v_t) NOT LIKE 'no entendi%' THEN RAISE EXCEPTION 'case 4: a USD amount is not GYD and must not be understood, got %', v_t; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = r.conv AND mixed_group_id IS NOT NULL)
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = r.rem) <> 24400
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id IN (r.rem, r.rec) AND field_name = 'mixed_split') THEN
    RAISE EXCEPTION 'case 4: an unparsed request must change nothing'; END IF;

  -- ---- 5. NO DEPOSIT: (277) the split is PLANNED, not refused; nothing is split, a closed conversation clears the plan ------------
  SELECT * INTO c FROM pg_temp.t255_conv(5);
  v_t := cerebro_repartir_envio(c.conv, 'clasica 18200, recarga 6200', 'exec-t255-5');
  IF v_t NOT LIKE 'Reparto planeado%' THEN
    RAISE EXCEPTION 'case 5: a plan expected before the deposit, got %', v_t; END IF;
  IF (SELECT count(*) FROM remittance_operations WHERE conversation_id = c.conv) <> 2
     OR EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = c.conv AND (mixed_group_id IS NOT NULL OR coalesce(quoted_source_amount, 0) <> 0)) THEN
    RAISE EXCEPTION 'case 5: two empty, ungrouped part operations expected'; END IF;
  UPDATE remittance_operations SET status = 'cancelled' WHERE conversation_id = c.conv;
  IF EXISTS (SELECT 1 FROM cerebro_reparto_planeado WHERE conversation_id = c.conv) THEN
    RAISE EXCEPTION 'case 5: the plan must go with the last operation'; END IF;

  -- ---- 6. "saldo movil 5000" IS saldo, NOT recarga -----------------------------------------------------------------------
  v_p := _cerebro_partes_envio_parse('saldo movil 5000');
  IF v_p IS DISTINCT FROM '{"ok":true,"partes":[{"servicio":"saldo","monto_gyd":5000}]}'::jsonb THEN
    RAISE EXCEPTION 'case 6: saldo movil must map to saldo: %', v_p; END IF;
  IF _cerebro_partes_envio_parse('Saldo móvil 5000') IS DISTINCT FROM v_p
     OR _cerebro_partes_envio_parse('saldo 5000') IS DISTINCT FROM v_p THEN
    RAISE EXCEPTION 'case 6: saldo spellings'; END IF;
  IF _cerebro_partes_envio_parse('saldo de recarga 3000') -> 'partes' -> 0 ->> 'servicio' <> 'recarga'
     OR _cerebro_partes_envio_parse('tarjeta cup 1000') -> 'partes' -> 0 ->> 'servicio' <> 'cuban_card'
     OR _cerebro_partes_envio_parse('extension de visa 2000') -> 'partes' -> 0 ->> 'servicio' <> 'visa'
     OR _cerebro_partes_envio_parse('efectivo usd 2000') -> 'partes' -> 0 ->> 'servicio' <> 'efectivo_usd'
     OR _cerebro_partes_envio_parse('combos 2000') -> 'partes' -> 0 ->> 'servicio' <> 'combo' THEN
    RAISE EXCEPTION 'case 6: service words'; END IF;
  -- end to end: a saldo operation holding the deposit, split into saldo + recarga
  SELECT * INTO c FROM pg_temp.t255_conv(6);
  v_op := pg_temp.t255_op(c, 'deposit_verification', 'saldo', NULL, 11200);
  PERFORM pg_temp.t255_dep(v_op, 11200, 6);
  v_t := cerebro_repartir_envio(c.conv, 'saldo movil 5000, recarga 6200', 'exec-t255-6');
  IF v_t NOT LIKE 'Reparto hecho:%' OR v_t NOT LIKE '%saldo 5,000 GYD%' OR v_t NOT LIKE '%recarga 6,200 GYD%' THEN
    RAISE EXCEPTION 'case 6: unexpected summary %', v_t; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_op) <> 5000
     OR NOT EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = c.conv AND service_type = 'recarga' AND quoted_source_amount = 6200) THEN
    RAISE EXCEPTION 'case 6: saldo must keep 5000 and a recarga of 6200 must exist'; END IF;

  -- ---- 7. PENDING DEPOSIT: the summary says what is missing --------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t255_conv(7);
  v_op := pg_temp.t255_op(c, 'collecting_information', 'remesa', 'clasica', 24400);
  v_t := cerebro_repartir_envio(c.conv, 'clasica 18200, recarga 6200', 'exec-t255-7');
  IF v_t NOT LIKE 'Reparto hecho:%' OR lower(v_t) NOT LIKE '%todavia no hay deposito verificado%' OR v_t LIKE '%listo para transferir%' THEN
    RAISE EXCEPTION 'case 7: a pending deposit must be reported as pending, got %', v_t; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
