\set ON_ERROR_STOP on
BEGIN;
-- =====================================================================
-- Assertion for migration 391 (cerebro_registrar_deposito: the movido branch skips an operation that holds no money and is
-- stale or whose rail does not fit the deposit).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs. The staging script strips BEGIN/ROLLBACK/\set and wraps it.
-- Production incident 2026-11-24: a 12,400 GYD deposit (two recargas) joined an unfunded operation opened ~19 h earlier that held
-- only a Zelle recipient (Zelle minimum above 12,400). Rule asserted (an open operation is NOT a deposit target when it holds no
-- money AND it is older than completar_ventana_horas). A rail-minimum test is deliberately NOT part of the rule: a first partial
-- deposit below the rail minimum must still reach its recipient-first op (split-deposit-minimums case 1).
--   A  stale unfunded Zelle-recipient op + 12,400 deposit      -> not attached, the op stays untouched
--   A2 stale unfunded Zelle-recipient op + 29,000 deposit      -> not attached (age alone excludes it)
--   B  fresh unfunded Zelle-recipient op + 12,400 deposit      -> movido (partial deposit below the minimum waits for the rest)
--   C  fresh unfunded Zelle-recipient op + 29,000 deposit      -> movido (recipient-first op still takes a compatible deposit)
--   C2 op 5 h old (inside the window) + 29,000 deposit         -> movido
--   D  stale op that already holds money, no recipient         -> movido (only money-less operations are skipped)
--   E  stale unfunded op + fresh compatible op                 -> the fresh one takes the deposit
-- =====================================================================

CREATE FUNCTION pg_temp.t391_conv(p_n int) RETURNS TABLE(acc uuid, usr uuid, contact uuid, conv uuid)
LANGUAGE plpgsql AS $f$
DECLARE v_user uuid; v_acc uuid; v_ct uuid; v_cv uuid;
BEGIN
  SELECT p.user_id, p.account_id INTO v_user, v_acc
    FROM whatsapp_config w JOIN profiles p ON p.account_id = w.account_id
   ORDER BY (p.account_role = 'owner') DESC LIMIT 1;
  INSERT INTO contacts (id, user_id, phone, name, account_id)
    VALUES (gen_random_uuid(), v_user, '5990391' || lpad(p_n::text, 4, '0'), 'T391 ' || p_n, v_acc) RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id)
    VALUES (gen_random_uuid(), v_user, v_ct, v_acc) RETURNING id INTO v_cv;
  RETURN QUERY SELECT v_acc, v_user, v_ct, v_cv;
END $f$;

CREATE FUNCTION pg_temp.t391_op(p_c record, p_status text, p_amt numeric, p_rail text, p_age_min int, p_recipient boolean)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, contact_id, deal_id, status, service_type,
                                     quoted_source_amount, source_currency, delivery_method, created_at)
  VALUES (gen_random_uuid(), p_c.acc, p_c.conv, p_c.contact, NULL, p_status, 'remesa', p_amt, 'GYD', p_rail,
          now() - make_interval(mins => p_age_min))
  RETURNING id INTO v_op;
  IF p_recipient THEN
    INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, phone, position, block_index, source, status)
    VALUES (v_op, 'zelle', 'Receptor T391', '52123456', 1, 1, 'notes_parse', 'vigente');
  END IF;
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t391_dep(p_conv uuid, p_amt numeric, p_n int) RETURNS record LANGUAGE plpgsql AS $f$
DECLARE v_ref numeric; v_r record; v_comp text := 'COMP-' || substring(md5('t391-' || p_n), 1, 20);
BEGIN
  SELECT COALESCE((SELECT max(trans_id::numeric) FROM depositos_mmg WHERE trans_id ~ '^[0-9]+$'), 20000000000000) + 100 + p_n INTO v_ref;
  SELECT * INTO v_r FROM cerebro_registrar_deposito(p_conv, p_amt, 'GYD', '3cf01654-cd27-47c1-ac92-62abf5435751'::uuid,
    'DEPOSITO: ' || p_amt || ' GYD - APROBADA' || chr(10) || 'Via: Agente MMG;' || chr(10) || 'Ref: ' || v_ref::bigint || chr(10) || v_comp, v_comp);
  RETURN v_r;
END $f$;

DO $$
DECLARE
  c record; v_a uuid; v_b uuid; v_r record; v_fail int := 0; v_min numeric; v_vent int;
  v_old int; v_fresh int := 120;
BEGIN
  v_vent := COALESCE(NULLIF(cerebro_config_get('completar_ventana_horas'), '')::int, 6);
  v_old := (v_vent + 13) * 60;   -- well past the window (19 h with the default 6 h)

  -- ---- A: stale unfunded Zelle-recipient op + a deposit below the Zelle minimum ----------------------------------------------
  SELECT * INTO c FROM pg_temp.t391_conv(1);
  v_a := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', v_old, true);
  v_min := cerebro_minimo_gyd(v_a);
  IF v_min IS NULL OR v_min <= 12400 THEN RAISE EXCEPTION 'setup: the Zelle minimum must be above 12400, got %', v_min; END IF;
  v_r := pg_temp.t391_dep(c.conv, 12400, 1);
  IF v_r.deal_id = v_a OR v_r.accion = 'movido' THEN
    RAISE WARNING 'FAIL A: a stale unfunded Zelle op took the 12400 deposit (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSIF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_a) <> 0
        OR EXISTS (SELECT 1 FROM remittance_operation_receipts WHERE operation_id = v_a) THEN
    RAISE WARNING 'FAIL A: the stale op was modified'; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS A: stale Zelle op not used by the 12400 deposit (%)', v_r.accion; END IF;

  -- ---- A2: the same stale op, a deposit above the minimum: the age alone excludes it ------------------------------------------
  SELECT * INTO c FROM pg_temp.t391_conv(2);
  v_a := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', v_old, true);
  v_r := pg_temp.t391_dep(c.conv, 29000, 2);
  IF v_r.deal_id = v_a OR v_r.accion = 'movido' THEN
    RAISE WARNING 'FAIL A2: a stale unfunded op took a deposit (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS A2: stale unfunded op not used even by a compatible amount (%)', v_r.accion; END IF;

  -- ---- B: fresh unfunded Zelle-recipient op + a partial deposit below the Zelle minimum: still the target (waits for the rest) -
  SELECT * INTO c FROM pg_temp.t391_conv(3);
  v_a := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', v_fresh, true);
  v_r := pg_temp.t391_dep(c.conv, 12400, 3);
  IF v_r.accion IS DISTINCT FROM 'movido' OR v_r.deal_id IS DISTINCT FROM v_a THEN
    RAISE WARNING 'FAIL B: a fresh recipient-first op must take a partial deposit (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS B: fresh Zelle op takes a partial deposit below its minimum'; END IF;

  -- ---- C: fresh unfunded Zelle-recipient op + a compatible deposit: still the target (232 behaviour) ---------------------------
  SELECT * INTO c FROM pg_temp.t391_conv(4);
  v_a := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', v_fresh, true);
  v_r := pg_temp.t391_dep(c.conv, 29000, 4);
  IF v_r.accion IS DISTINCT FROM 'movido' OR v_r.deal_id IS DISTINCT FROM v_a THEN
    RAISE WARNING 'FAIL C: the fresh recipient-first op must take the deposit (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS C: fresh compatible recipient-first op takes the deposit'; END IF;

  -- ---- C2: inside the window (5 h with the default 6 h) ------------------------------------------------------------------------
  SELECT * INTO c FROM pg_temp.t391_conv(5);
  v_a := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', (v_vent - 1) * 60, true);
  v_r := pg_temp.t391_dep(c.conv, 29000, 5);
  IF v_r.accion IS DISTINCT FROM 'movido' OR v_r.deal_id IS DISTINCT FROM v_a THEN
    RAISE WARNING 'FAIL C2: an op inside the window must take the deposit (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS C2: op inside the window takes the deposit'; END IF;

  -- ---- D: a stale op that already holds money (amount, no recipient) is not a money-less op: unchanged ---------------------------
  SELECT * INTO c FROM pg_temp.t391_conv(6);
  v_a := pg_temp.t391_op(c, 'awaiting_deposit', 40000, 'zelle', v_old, false);
  v_r := pg_temp.t391_dep(c.conv, 12400, 6);
  IF v_r.accion IS DISTINCT FROM 'movido' OR v_r.deal_id IS DISTINCT FROM v_a THEN
    RAISE WARNING 'FAIL D: an op that holds money keeps its behaviour (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS D: stale op holding money is unchanged'; END IF;

  -- ---- E: stale unfunded op + a fresh compatible op: the fresh one takes the deposit --------------------------------------------
  SELECT * INTO c FROM pg_temp.t391_conv(7);
  v_a := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', v_old, true);
  v_b := pg_temp.t391_op(c, 'collecting_information', 0, 'zelle', v_fresh, true);
  v_r := pg_temp.t391_dep(c.conv, 29000, 7);
  IF v_r.accion IS DISTINCT FROM 'movido' OR v_r.deal_id IS DISTINCT FROM v_b THEN
    RAISE WARNING 'FAIL E: the fresh op must take the deposit, not the stale one (% %)', v_r.accion, v_r.deal_id; v_fail := v_fail + 1;
  ELSIF (SELECT quoted_source_amount FROM remittance_operations WHERE id = v_a) <> 0 THEN
    RAISE WARNING 'FAIL E: the stale op was modified'; v_fail := v_fail + 1;
  ELSE RAISE NOTICE 'PASS E: fresh op wins over the stale one'; END IF;

  IF v_fail > 0 THEN RAISE EXCEPTION '% expectation(s) failed', v_fail; END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
