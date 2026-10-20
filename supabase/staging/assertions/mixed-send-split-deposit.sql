\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 253 (mixed send: one deposit split across a group of operations).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. Run it wrapped as
--   BEGIN; <this file without its own BEGIN/ROLLBACK/\set>; ROLLBACK;
-- (never plain psql -1: it can COMMIT the fixture).
-- Production 2026-10-20 (conversation f8b7779c): the customer deposited 24,400 GYD for 18,200 (70 USD Clasica) plus 6,200
-- (recarga). The remesa took the whole 24,400 (93 USD) and the cross-check raised a "de mas" incident while the recarga
-- sat empty. Rule asserted: operations of one group (mixed_group_id) share ONE deposit; the group saldo is the sum of the
-- members' quoted_source_amount minus the deposits consumed by any member; crm_repartir_envio redistributes the money
-- (it never creates or loses any), locks the shares like a human correction, and closes the group when the saldo is 0;
-- cerebro_cruzar_depositos readies the siblings when a late deposit settles the group. Ungrouped operations are unchanged.
-- odd/tasks/mixed-send-split-deposit.md (S1).
-- =====================================================================

CREATE FUNCTION pg_temp.t253_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990253' || lpad(p_n::text, 4, '0'), 'T253 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t253_op(p_c record, p_status text, p_svc text, p_rail text, p_amt numeric) RETURNS uuid
LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, status, service_type, delivery_method,
                                     source_currency, quoted_source_amount)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, p_status, p_svc, p_rail, 'GYD', p_amt) RETURNING id INTO v_op;
  RETURN v_op;
END $f$;

-- a consumed receipt tied to an operation
CREATE FUNCTION pg_temp.t253_dep(p_op uuid, p_amt numeric, p_n int, p_consumed boolean) RETURNS text
LANGUAGE plpgsql AS $f$
DECLARE v_ref text;
BEGIN
  SELECT (COALESCE((SELECT max(trans_id::numeric) FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$'), 20000000000000) + 100 + p_n)::bigint::text
    INTO v_ref;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, operation_id, consumido_en)
  VALUES (v_ref, p_amt, 'GYD', 'test253', now(), CASE WHEN p_consumed THEN p_op END, CASE WHEN p_consumed THEN now() END);
  RETURN v_ref;
END $f$;

-- runs a statement, returns the SQLSTATE it raised (or 'ok'); the failed statement is rolled back by its sub-transaction
CREATE FUNCTION pg_temp.t253_err(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN EXECUTE p_sql; RETURN 'ok';
EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ': ' || SQLERRM; END $f$;

CREATE FUNCTION pg_temp.t253_as(p_user uuid) RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
$f$;

DO $$
DECLARE
  c record; v_rem uuid; v_rec uuid; v_new uuid; v_r jsonb; v_o remittance_operations%ROWTYPE; v_s record;
  v_rate numeric := crm_tasa_vigente('usd'); v_e text; v_ref text; v_x record; v_old numeric; v_obj_open int;
  v_grp uuid; v_audits int; v_ops int; v_c2 record; v_rem2 uuid; v_cr record;
BEGIN
  IF v_rate IS NULL OR v_rate <= 0 THEN RAISE EXCEPTION 'fixture: no usd rate'; END IF;

  -- ---- 1. THE f8b7779c REPLAY -----------------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t253_conv(1);
  v_rem := pg_temp.t253_op(c, 'incident', 'remesa', 'clasica', 24400);
  UPDATE remittance_operations SET incident_reason = 'verificado_de_mas' WHERE id = v_rem;
  v_rec := pg_temp.t253_op(c, 'collecting_information', 'recarga', NULL, NULL);
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, phone, position, block_index, source, status)
  VALUES (v_rec, 'recarga', '5926001234', 1, 1, 'manual', 'vigente');
  PERFORM pg_temp.t253_dep(v_rem, 24400, 1, true);
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda, operation_id) VALUES (c.conv, 18200, 'GYD', v_rem);

  SELECT * INTO v_s FROM cerebro_saldo_operacion(v_rem);
  IF v_s.saldo IS DISTINCT FROM -6200 THEN RAISE EXCEPTION 'case 1: before the split the saldo must be -6200, got %', v_s.saldo; END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_rem;
  IF v_o.quoted_destination_amount IS DISTINCT FROM floor(24400 / v_rate) THEN
    RAISE EXCEPTION 'case 1: fixture remesa should carry the 93 USD error, got %', v_o.quoted_destination_amount; END IF;

  PERFORM pg_temp.t253_as(c.usr);   -- the bot wrote the fixture; the operator splits it
  v_r := crm_repartir_envio(v_rem, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]'::jsonb);

  SELECT * INTO v_o FROM remittance_operations WHERE id = v_rem;
  IF v_o.quoted_source_amount <> 18200 OR v_o.quoted_destination_amount IS DISTINCT FROM floor(18200 / v_rate)
     OR v_o.destination_currency IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'case 1: remesa must be 18200 GYD -> floor(18200/rate) USD, got % -> % %', v_o.quoted_source_amount, v_o.quoted_destination_amount, v_o.destination_currency; END IF;
  IF v_o.mixed_group_id IS DISTINCT FROM v_rem OR v_o.status <> 'ready_to_transfer' OR v_o.incident_reason IS NOT NULL
     OR NOT (v_o.admin_locked_fields ? 'quoted_source_amount') THEN
    RAISE EXCEPTION 'case 1: remesa must be grouped on itself, ready, without incident and locked, got % % % %', v_o.mixed_group_id, v_o.status, v_o.incident_reason, v_o.admin_locked_fields; END IF;
  IF v_o.admin_locked_fields ? 'quoted_destination_amount' OR v_o.admin_locked_fields ? 'destination_currency' THEN
    RAISE EXCEPTION 'case 1: the calculated destination must stay unlocked, got %', v_o.admin_locked_fields; END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE id = v_rec;
  IF v_o.quoted_source_amount <> 6200 OR v_o.mixed_group_id IS DISTINCT FROM v_rem OR v_o.status <> 'ready_to_transfer'
     OR NOT (v_o.admin_locked_fields ? 'quoted_source_amount') THEN
    RAISE EXCEPTION 'case 1: recarga must be 6200, grouped, ready and locked, got % % % %', v_o.quoted_source_amount, v_o.mixed_group_id, v_o.status, v_o.admin_locked_fields; END IF;
  FOR v_x IN SELECT * FROM unnest(ARRAY[v_rem, v_rec]) AS m(id) LOOP
    SELECT * INTO v_s FROM cerebro_saldo_operacion(v_x.id);
    IF (v_s.objetivo, v_s.depositado, v_s.saldo, v_s.moneda) IS DISTINCT FROM (24400::numeric, 24400::numeric, 0::numeric, 'GYD') THEN
      RAISE EXCEPTION 'case 1: group saldo of % must be 24400/24400/0/GYD, got %/%/%/%', v_x.id, v_s.objetivo, v_s.depositado, v_s.saldo, v_s.moneda; END IF;
  END LOOP;
  SELECT count(*) INTO v_obj_open FROM cerebro_objetivo_envio WHERE conversation_id = c.conv AND cerrado_en IS NULL;
  IF v_obj_open <> 0 THEN RAISE EXCEPTION 'case 1: the conversation objective must be closed'; END IF;
  SELECT count(*) INTO v_audits FROM remittance_admin_audit
   WHERE row_id IN (v_rem, v_rec) AND action = 'human_correction' AND field_name = 'mixed_split';
  IF v_audits <> 2 THEN RAISE EXCEPTION 'case 1: one audit row per changed operation expected, got %', v_audits; END IF;
  IF (SELECT before ->> 'quoted_source_amount' FROM remittance_admin_audit WHERE row_id = v_rem AND field_name = 'mixed_split') <> '24400'
     OR (SELECT after ->> 'quoted_source_amount' FROM remittance_admin_audit WHERE row_id = v_rem AND field_name = 'mixed_split') <> '18200' THEN
    RAISE EXCEPTION 'case 1: the audit must carry before/after amounts'; END IF;
  IF (v_r ->> 'grupo')::uuid <> v_rem OR (v_r ->> 'depositado')::numeric <> 24400 OR (v_r ->> 'saldo')::numeric <> 0
     OR jsonb_array_length(v_r -> 'partes') <> 2 THEN
    RAISE EXCEPTION 'case 1: unexpected result %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 'partes') p WHERE (p ->> 'creada')::boolean) THEN
    RAISE EXCEPTION 'case 1: both operations existed, none is created: %', v_r; END IF;
  -- the lock is real: automation cannot overwrite a share
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE remittance_operations SET quoted_source_amount = 99999 WHERE id = v_rem;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_rem) <> 18200 THEN
    RAISE EXCEPTION 'case 1: an automation write must not overwrite a locked share'; END IF;

  -- ---- 2. A WRONG SUM IS REFUSED, NOTHING CHANGES -----------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t253_conv(2);
  v_rem := pg_temp.t253_op(c, 'incident', 'remesa', 'clasica', 24400);
  v_rec := pg_temp.t253_op(c, 'collecting_information', 'recarga', NULL, NULL);
  PERFORM pg_temp.t253_as(c.usr);
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6000}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: a wrong sum must raise 22023, got %', v_e; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE id IN (v_rem, v_rec) AND mixed_group_id IS NOT NULL)
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_rem) <> 24400
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_rec) IS NOT NULL
     OR EXISTS (SELECT 1 FROM remittance_admin_audit WHERE row_id IN (v_rem, v_rec) AND field_name = 'mixed_split') THEN
    RAISE EXCEPTION 'case 2: a refused split must change nothing'; END IF;
  -- other refusals
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"clasica","monto_gyd":24400}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: one part must raise 22023, got %', v_e; END IF;
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"clasica","monto_gyd":12200},{"servicio":"clasica","monto_gyd":12200}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: repeated services must raise 22023, got %', v_e; END IF;
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"clasica","monto_gyd":24400},{"servicio":"recarga","monto_gyd":0}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: a zero part must raise 22023, got %', v_e; END IF;
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"zelle","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: parts without the anchor service must raise 22023, got %', v_e; END IF;
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"nope","monto_gyd":6200}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: an unknown service must raise 22023, got %', v_e; END IF;
  -- a zero total cannot be split
  v_rem2 := pg_temp.t253_op(c, 'collecting_information', 'remesa', 'zelle', 0);
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"zelle","monto_gyd":1},{"servicio":"recarga","monto_gyd":1}]'::jsonb)$q$, v_rem2));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: a zero total must raise 22023, got %', v_e; END IF;
  -- a closed anchor cannot be split
  UPDATE remittance_operations SET status = 'completed' WHERE id = v_rem2;
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"zelle","monto_gyd":1},{"servicio":"recarga","monto_gyd":1}]'::jsonb)$q$, v_rem2));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 2: a completed anchor must raise 22023, got %', v_e; END IF;

  -- ---- 3. NO RECARGA YET: ONE IS CREATED AND GROUPED --------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t253_conv(3);
  v_rem := pg_temp.t253_op(c, 'incident', 'remesa', 'clasica', 24400);
  PERFORM pg_temp.t253_dep(v_rem, 24400, 3, true);
  PERFORM pg_temp.t253_as(c.usr);
  v_r := crm_repartir_envio(v_rem, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]'::jsonb);
  SELECT count(*) INTO v_ops FROM remittance_operations WHERE conversation_id = c.conv;
  IF v_ops <> 2 THEN RAISE EXCEPTION 'case 3: exactly one operation must be created, conversation has %', v_ops; END IF;
  SELECT * INTO v_o FROM remittance_operations WHERE conversation_id = c.conv AND id <> v_rem;
  IF v_o.service_type <> 'recarga' OR v_o.quoted_source_amount <> 6200 OR v_o.mixed_group_id IS DISTINCT FROM v_rem
     OR v_o.contact_id IS DISTINCT FROM c.contact OR v_o.account_id <> c.acc OR v_o.source_currency <> 'GYD'
     OR v_o.status <> 'ready_to_transfer' OR NOT (v_o.admin_locked_fields ? 'quoted_source_amount') THEN
    RAISE EXCEPTION 'case 3: the created recarga is wrong: % % % % % %', v_o.service_type, v_o.quoted_source_amount, v_o.mixed_group_id, v_o.contact_id, v_o.status, v_o.admin_locked_fields; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r -> 'partes') p
                  WHERE p ->> 'servicio' = 'recarga' AND (p ->> 'creada')::boolean AND (p ->> 'operation_id')::uuid = v_o.id) THEN
    RAISE EXCEPTION 'case 3: the result must flag the created part: %', v_r; END IF;
  -- a created remesa-rail part also gets its rail and a calculated destination
  SELECT * INTO c FROM pg_temp.t253_conv(4);
  v_rem := pg_temp.t253_op(c, 'collecting_information', 'recarga', NULL, 24400);
  PERFORM pg_temp.t253_as(c.usr);
  v_r := crm_repartir_envio(v_rem, '[{"servicio":"recarga","monto_gyd":6200},{"servicio":"clasica","monto_gyd":18200}]'::jsonb);
  SELECT * INTO v_o FROM remittance_operations WHERE conversation_id = c.conv AND id <> v_rem;
  IF v_o.service_type <> 'remesa' OR v_o.delivery_method <> 'clasica' OR v_o.quoted_destination_amount IS DISTINCT FROM floor(18200 / v_rate)
     OR v_o.destination_currency IS DISTINCT FROM 'USD' OR v_o.admin_locked_fields ? 'quoted_destination_amount' THEN
    RAISE EXCEPTION 'case 3b: the created clasica is wrong: % % % % %', v_o.service_type, v_o.delivery_method, v_o.quoted_destination_amount, v_o.destination_currency, v_o.admin_locked_fields; END IF;
  -- re-split through a MEMBER (the clasica): the group is found, the total is the group total
  v_r := crm_repartir_envio(v_o.id, '[{"servicio":"recarga","monto_gyd":14400},{"servicio":"clasica","monto_gyd":10000}]'::jsonb);
  IF (v_r ->> 'grupo')::uuid <> v_rem THEN RAISE EXCEPTION 'case 3c: the group must stay anchored on %, got %', v_rem, v_r; END IF;
  IF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_rem) <> 14400
     OR (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_o.id) <> 10000
     OR (SELECT quoted_destination_amount FROM remittance_operations WHERE id = v_o.id) IS DISTINCT FROM floor(10000 / v_rate) THEN
    RAISE EXCEPTION 'case 3c: a re-split must move the money between the same members'; END IF;
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"recarga","monto_gyd":14400},{"servicio":"zelle","monto_gyd":10000}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '22023:%' THEN RAISE EXCEPTION 'case 3c: a group member without a part must raise 22023, got %', v_e; END IF;

  -- ---- 4. UNGROUPED: THE OLD FORMULA, EXACTLY ---------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t253_conv(5);
  v_rem := pg_temp.t253_op(c, 'deposit_verification', 'remesa', 'zelle', 30000);
  PERFORM pg_temp.t253_dep(v_rem, 12000, 5, true);
  PERFORM pg_temp.t253_dep(v_rem, 99999, 6, false);              -- not consumed: ignored
  INSERT INTO cerebro_objetivo_envio (conversation_id, monto, moneda) VALUES (c.conv, 28600, 'GYD');   -- untied objective
  SELECT * INTO v_s FROM cerebro_saldo_operacion(v_rem);
  IF (v_s.objetivo, v_s.depositado, v_s.saldo, v_s.moneda) IS DISTINCT FROM (28600::numeric, 12000::numeric, 16600::numeric, 'GYD') THEN
    RAISE EXCEPTION 'case 4: ungrouped saldo must be the old objective - deposits, got %/%/%/%', v_s.objetivo, v_s.depositado, v_s.saldo, v_s.moneda; END IF;
  UPDATE cerebro_objetivo_envio SET cerrado_en = now() WHERE conversation_id = c.conv;
  SELECT * INTO v_s FROM cerebro_saldo_operacion(v_rem);
  IF v_s.objetivo IS NOT NULL OR v_s.saldo IS NOT NULL OR v_s.depositado <> 12000 OR v_s.moneda <> 'GYD' THEN
    RAISE EXCEPTION 'case 4: with no open objective the ungrouped saldo is NULL, got %/%/%/%', v_s.objetivo, v_s.depositado, v_s.saldo, v_s.moneda; END IF;
  IF EXISTS (SELECT 1 FROM remittance_operations WHERE conversation_id = c.conv AND mixed_group_id IS NOT NULL) THEN
    RAISE EXCEPTION 'case 4: nothing is grouped by default'; END IF;

  -- ---- 5. NOT A MEMBER OF THE ACCOUNT -----------------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t253_conv(6);
  v_rem := pg_temp.t253_op(c, 'incident', 'remesa', 'clasica', 24400);
  PERFORM pg_temp.t253_as(gen_random_uuid());
  v_e := pg_temp.t253_err(format($q$SELECT crm_repartir_envio(%L, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]'::jsonb)$q$, v_rem));
  IF v_e NOT LIKE '42501:%' THEN RAISE EXCEPTION 'case 5: a non-member must get 42501, got %', v_e; END IF;
  IF (SELECT count(*) FROM remittance_operations WHERE conversation_id = c.conv) <> 1 THEN
    RAISE EXCEPTION 'case 5: a refused call must create nothing'; END IF;

  -- ---- 6. A LATE DEPOSIT SETTLES THE GROUP: THE SIBLINGS GET THE SAME STATUS --------------------------------------------
  SELECT * INTO c FROM pg_temp.t253_conv(7);
  v_rem := pg_temp.t253_op(c, 'deposit_verification', 'remesa', 'clasica', 24400);
  v_rec := pg_temp.t253_op(c, 'collecting_information', 'recarga', NULL, NULL);
  PERFORM pg_temp.t253_as(c.usr);
  v_r := crm_repartir_envio(v_rem, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]'::jsonb);
  IF (SELECT status FROM remittance_operations WHERE id = v_rem) <> 'deposit_verification'
     OR (SELECT status FROM remittance_operations WHERE id = v_rec) <> 'collecting_information' THEN
    RAISE EXCEPTION 'case 6: without a deposit the split must not move any status'; END IF;
  SELECT * INTO v_s FROM cerebro_saldo_operacion(v_rec);
  IF v_s.saldo IS DISTINCT FROM 24400 THEN RAISE EXCEPTION 'case 6: unpaid group saldo must be 24400, got %', v_s.saldo; END IF;
  v_ref := pg_temp.t253_dep(NULL, 24400, 7, false);
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_rem, ARRAY[v_ref], ARRAY[24400::numeric],
      'f5cf87f8-b570-4d71-b6ea-a3cafd458c63'::uuid, 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid, '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid, false);
  IF v_cr.resultado <> 'verificado' OR v_cr.saldo IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'case 6: the crossing must verify the group, got % saldo %', v_cr.resultado, v_cr.saldo; END IF;
  IF (SELECT status FROM remittance_operations WHERE id = v_rem) <> 'ready_to_transfer'
     OR (SELECT status FROM remittance_operations WHERE id = v_rec) <> 'ready_to_transfer' THEN
    RAISE EXCEPTION 'case 6: anchor and sibling must both be ready, got % / %',
      (SELECT status FROM remittance_operations WHERE id = v_rem), (SELECT status FROM remittance_operations WHERE id = v_rec); END IF;
  -- an incomplete group leaves the sibling alone
  SELECT * INTO c FROM pg_temp.t253_conv(8);
  v_rem := pg_temp.t253_op(c, 'deposit_verification', 'remesa', 'clasica', 24400);
  v_rec := pg_temp.t253_op(c, 'collecting_information', 'recarga', NULL, NULL);
  PERFORM pg_temp.t253_as(c.usr);
  PERFORM crm_repartir_envio(v_rem, '[{"servicio":"clasica","monto_gyd":18200},{"servicio":"recarga","monto_gyd":6200}]'::jsonb);
  v_ref := pg_temp.t253_dep(NULL, 18200, 8, false);
  SELECT * INTO v_cr FROM cerebro_cruzar_depositos(v_rem, ARRAY[v_ref], ARRAY[18200::numeric],
      'f5cf87f8-b570-4d71-b6ea-a3cafd458c63'::uuid, 'da7b3e24-9222-4150-8be8-d7f7378e16aa'::uuid, '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid, false);
  IF v_cr.resultado <> 'verificado_incompleto' OR (SELECT status FROM remittance_operations WHERE id = v_rec) <> 'collecting_information' THEN
    RAISE EXCEPTION 'case 6b: a partial payment must leave the sibling untouched, got % / %', v_cr.resultado, (SELECT status FROM remittance_operations WHERE id = v_rec); END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
ROLLBACK;
