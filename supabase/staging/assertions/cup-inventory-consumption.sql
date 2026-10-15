\set ON_ERROR_STOP on
-- Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- cup-inventory-consumption.sql -- self-reverting assertion for 240_cup_inventory_consumption.sql
--
-- STATUS: written without a SQL engine (psql unavailable where it was authored) -- pending staging run (T8). Never run against production.
--
-- Proves the CUP inventory consumption (phase 2). Fixture account 1: cards A (priority 1) and B (priority 2), limit 120,000 each, lot A
-- 500,000 CUP @960, lot B 250,000 CUP @1060; rates: cup_global_rate 2, usdt_buy_gyd 240, usdt_sell_cup 1100 (the GLOBAL, deliberately
-- different from every lot rate). A CUP operation of basis X GYD is 2X CUP.
--   case 1  feed a 50,000 CUP operation: A gives 50,000 (one consumption row linked to the entry), cup_rate = 960, invertido =
--           50,000 / 960 x 240, retorno = facturado - invertido, A.remaining 450,000, used_today A 50,000.
--   case 2  feed 100,000 CUP: 70,000 from A (its limit) + 30,000 from B; cup_rate = 100,000 / (70,000/960 + 30,000/1060) exactly,
--           invertido = (70,000/960 + 30,000/1060) x 240; used_today A 120,000, B 30,000.
--   case 3  a MANUAL 15,000 CUP line (agent): consumes from B (A is at its limit); the typed invertido is untouched and cup_rate stays NULL.
--   case 4  a manual line dated YESTERDAY (Guyana) counts toward yesterday's Cuba day (consumption cuba_day = that date) and not toward today.
--   case 5  insufficient inventory: a 100,000 CUP operation with only 75,000 of room -> consumes 75,000, entry cup_rate = 100,000 /
--           (75,000/1060 + 25,000/1100), an 'inventario_cup' notification per owner/admin names the customer and the 25,000 missing.
--           A further 20,000 operation with every limit used consumes nothing, keeps the global rate 1100 and alerts again.
--   case 6  void: reverting the case-2 operation returns 70,000 to A and 30,000 to B (remaining and used_today follow), its consumption
--           rows are gone, the entry is void; re-completing it consumes again (once, not twice).
--   case 7  idempotent: re-feeding a live operation and calling cup_consumir again for the same entry consume nothing more.
--   case 8  the report lists today's consumptions per card (customer, source, lot rate); deleting the manual line (crm_eliminar_entrada_calculadora)
--           returns its CUP; the rate edit (crm_corregir_tasas_entrada_calculadora) leaves the inventory untouched.
--   case 9  account 2: FIFO across two lots of one card (30,000 @900 loaded first, then 30,000 @1000: 40,000 -> 30,000 + 10,000, exact rate);
--           an inactive card (priority 0, with a lot) is skipped; account 1's activity never touched account 2's lots (isolation).
--   case 10 an inventory failure never aborts the feed: with a poisoned lot constraint the CUP line is still written with the GLOBAL rate and an
--           'inventario_cup' error notification is raised; the failed consumption left nothing behind.
--   case 11 grants: cup_consumir / cup_devolver / cup_alertar are executable by neither authenticated nor anon.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (BEGIN ... \i 239 ... \i 240 ... \i this file ... ROLLBACK), on STAGING only.
-- Never COMMIT. Never run against production. Builds its own fixtures.

SAVEPOINT cup_inventory_consumption;

CREATE FUNCTION pg_temp.cic_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.cic_op(p_acct uuid, p_conv uuid, p_gyd numeric) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acct, p_conv, 'ready_to_transfer', 'remesa', 'GYD', p_gyd, 'cuban_card') RETURNING id INTO v;
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.cic_done(p_op uuid, p_actor uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.cic_claims(p_actor);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = p_actor WHERE id = p_op;
  PERFORM pg_temp.cic_claims(NULL);
END $f$;

CREATE FUNCTION pg_temp.cic_revert(p_op uuid, p_actor uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.cic_claims(p_actor);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = p_op;
  PERFORM pg_temp.cic_claims(NULL);
END $f$;

CREATE FUNCTION pg_temp.cic_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

-- numeric equality within 1e-9 (the combined rate is a division)
CREATE FUNCTION pg_temp.cic_near(a numeric, b numeric) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT a IS NOT NULL AND b IS NOT NULL AND abs(a - b) < 0.000000001;
$f$;

CREATE FUNCTION pg_temp.cic_remaining(p_card uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT coalesce(sum(remaining_cup), 0) FROM cup_lots WHERE card_id = p_card;
$f$;

CREATE FUNCTION pg_temp.cic_used(p_card uuid, p_day date) RETURNS numeric LANGUAGE sql AS $f$
  SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE card_id = p_card AND cuba_day = p_day;
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_contact uuid; v_conv uuid; v_contact2 uuid; v_conv2 uuid;
  v_a cup_cards; v_b cup_cards; v_c cup_cards; v_d cup_cards;
  v_la cup_lots; v_lb cup_lots; v_l1 cup_lots; v_l2 cup_lots; v_ld cup_lots; v_lf cup_lots;
  v_op1 uuid; v_op2 uuid; v_op5 uuid; v_op5b uuid; v_opf uuid;
  v_e1 remittance_calculator_entries; v_e2 remittance_calculator_entries; v_e5 remittance_calculator_entries; v_e5b remittance_calculator_entries;
  v_ef remittance_calculator_entries;
  v_man uuid; v_man_y uuid;
  v_today date; v_gy_today date; v_gy_yday date;
  v_usdt numeric; v_n numeric; v_cnt integer; v_before numeric; v_after numeric;
  v_rep jsonb; v_card jsonb; v_r record;
  v_fail integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cic-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_owner2, v_admin2]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup consumption test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup consumption other account', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'cic owner', 'cic-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'cic admin', 'cic-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'cic agent', 'cic-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_owner2, 'cic owner2', 'cic-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'cic admin2', 'cic-' || v_admin2 || '@test.invalid', v_acc2, 'admin');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '15550000240', v_acc, 'Cliente CIC') RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_contact, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner2, '15550000241', v_acc2, 'Cliente CIC2') RETURNING id INTO v_contact2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner2, v_contact2, v_acc2) RETURNING id INTO v_conv2;

  PERFORM pg_temp.cic_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  v_a := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta A', '1111', 1, 120000, NULL);
  v_b := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta B', '2222', 2, 120000, NULL);
  v_la := crm_cargar_lote_cup(v_acc, v_a.id, 500000, 960, 'lote A', NULL);
  v_lb := crm_cargar_lote_cup(v_acc, v_b.id, 250000, 1060, 'lote B', NULL);
  PERFORM pg_temp.cic_claims(v_admin2);
  PERFORM crm_set_calculator_rates(v_acc2, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  v_c := crm_guardar_tarjeta_cup(v_acc2, NULL, 'Tarjeta C', NULL, 1, 120000, NULL);
  v_l1 := crm_cargar_lote_cup(v_acc2, v_c.id, 30000, 900, 'primero', now() - interval '2 days');
  v_l2 := crm_cargar_lote_cup(v_acc2, v_c.id, 30000, 1000, 'segundo', now() - interval '1 day');
  v_d := crm_guardar_tarjeta_cup(v_acc2, NULL, 'Tarjeta D', NULL, 0, 120000, NULL);
  v_ld := crm_cargar_lote_cup(v_acc2, v_d.id, 50000, 800, 'lote D', NULL);
  v_d := crm_guardar_tarjeta_cup(v_acc2, v_d.id, NULL, NULL, NULL, NULL, false);
  PERFORM pg_temp.cic_claims(NULL);

  v_today := cup_cuba_day(now());
  v_gy_today := (now() AT TIME ZONE 'America/Guyana')::date;
  v_gy_yday := v_gy_today - 1;

  -- ---- case 1: 50,000 CUP, all from A ---------------------------------------------------------------------------------------------
  v_op1 := pg_temp.cic_op(v_acc, v_conv, 25000);
  PERFORM pg_temp.cic_done(v_op1, v_agent);
  SELECT * INTO v_e1 FROM remittance_calculator_entries WHERE operation_id = v_op1 AND service = 'CUP';
  v_fail := v_fail + pg_temp.cic_chk('1.entry completed 50,000 CUP', v_e1.status = 'completed' AND v_e1.amount = 50000, format('status=%s amount=%s', v_e1.status, v_e1.amount));
  v_fail := v_fail + pg_temp.cic_chk('1.cup_rate = lot rate 960', pg_temp.cic_near(v_e1.cup_rate, 960), format('cup_rate=%s', v_e1.cup_rate));
  v_fail := v_fail + pg_temp.cic_chk('1.invertido = 50000/960*240', pg_temp.cic_near(v_e1.invertido_gyd, 50000::numeric / 960 * 240), format('invertido=%s', v_e1.invertido_gyd));
  v_fail := v_fail + pg_temp.cic_chk('1.retorno = facturado - invertido', pg_temp.cic_near(v_e1.retorno_gyd, v_e1.facturado_gyd - v_e1.invertido_gyd));
  SELECT count(*), coalesce(sum(amount_cup), 0) INTO v_cnt, v_n FROM cup_lot_consumptions WHERE calculator_entry_id = v_e1.id AND lot_id = v_la.id AND operation_id = v_op1;
  v_fail := v_fail + pg_temp.cic_chk('1.one consumption of 50,000 from lot A linked to the entry', v_cnt = 1 AND v_n = 50000, format('rows=%s sum=%s', v_cnt, v_n));
  v_fail := v_fail + pg_temp.cic_chk('1.A remaining 450,000, used today 50,000', pg_temp.cic_remaining(v_a.id) = 450000 AND pg_temp.cic_used(v_a.id, v_today) = 50000);
  v_fail := v_fail + pg_temp.cic_chk('1.B untouched', pg_temp.cic_remaining(v_b.id) = 250000 AND pg_temp.cic_used(v_b.id, v_today) = 0);

  -- ---- case 2: 100,000 CUP splits 70,000 A + 30,000 B ----------------------------------------------------------------------------
  v_op2 := pg_temp.cic_op(v_acc, v_conv, 50000);
  PERFORM pg_temp.cic_done(v_op2, v_agent);
  SELECT * INTO v_e2 FROM remittance_calculator_entries WHERE operation_id = v_op2 AND service = 'CUP';
  v_usdt := 70000::numeric / 960 + 30000::numeric / 1060;
  v_fail := v_fail + pg_temp.cic_chk('2.amount 100,000', v_e2.amount = 100000, format('amount=%s', v_e2.amount));
  v_fail := v_fail + pg_temp.cic_chk('2.combined cup_rate exact', pg_temp.cic_near(v_e2.cup_rate, 100000 / v_usdt), format('cup_rate=%s expected=%s', v_e2.cup_rate, 100000 / v_usdt));
  v_fail := v_fail + pg_temp.cic_chk('2.invertido = (70000/960 + 30000/1060) * 240', pg_temp.cic_near(v_e2.invertido_gyd, v_usdt * 240), format('invertido=%s', v_e2.invertido_gyd));
  v_fail := v_fail + pg_temp.cic_chk('2.70,000 from A and 30,000 from B',
    (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE calculator_entry_id = v_e2.id AND card_id = v_a.id) = 70000
    AND (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE calculator_entry_id = v_e2.id AND card_id = v_b.id) = 30000);
  v_fail := v_fail + pg_temp.cic_chk('2.used today A 120,000 / B 30,000', pg_temp.cic_used(v_a.id, v_today) = 120000 AND pg_temp.cic_used(v_b.id, v_today) = 30000);
  v_fail := v_fail + pg_temp.cic_chk('2.remaining A 380,000 / B 220,000', pg_temp.cic_remaining(v_a.id) = 380000 AND pg_temp.cic_remaining(v_b.id) = 220000);

  -- ---- case 3: manual 15,000 CUP line -> from B, the typed figures stay -------------------------------------------------------------
  PERFORM pg_temp.cic_claims(v_agent);
  PERFORM crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual CIC', 'service', 'CUP', 'currency', 'CUP', 'amount', 15000, 'facturado_gyd', 5000, 'invertido_gyd', 3750,
    'retorno_gyd', 1250, 'date', v_gy_today::text, 'raw_line', '• Manual CIC 15,000 cup (240/960)')));
  PERFORM pg_temp.cic_claims(NULL);
  SELECT id INTO v_man FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Manual CIC';
  v_fail := v_fail + pg_temp.cic_chk('3.manual line took 15,000 from B (A is at its limit)',
    (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE calculator_entry_id = v_man AND card_id = v_b.id AND cuba_day = v_today) = 15000
    AND (SELECT count(*) FROM cup_lot_consumptions WHERE calculator_entry_id = v_man) = 1);
  v_fail := v_fail + pg_temp.cic_chk('3.typed figures untouched, no cup_rate invented',
    (SELECT invertido_gyd = 3750 AND facturado_gyd = 5000 AND retorno_gyd = 1250 AND cup_rate IS NULL FROM remittance_calculator_entries WHERE id = v_man));
  v_fail := v_fail + pg_temp.cic_chk('3.B used today 45,000', pg_temp.cic_used(v_b.id, v_today) = 45000);

  -- ---- case 4: manual line dated yesterday counts yesterday -----------------------------------------------------------------------------
  PERFORM pg_temp.cic_claims(v_agent);
  PERFORM crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual Ayer CIC', 'service', 'CUP', 'currency', 'CUP', 'amount', 10000, 'facturado_gyd', 3000, 'invertido_gyd', 2500,
    'retorno_gyd', 500, 'date', v_gy_yday::text)));
  PERFORM pg_temp.cic_claims(NULL);
  SELECT id INTO v_man_y FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Manual Ayer CIC';
  v_fail := v_fail + pg_temp.cic_chk('4.yesterday line consumed 10,000 on yesterday''s day',
    (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE calculator_entry_id = v_man_y AND cuba_day = v_gy_yday) = 10000);
  v_fail := v_fail + pg_temp.cic_chk('4.today''s used amounts did not move', pg_temp.cic_used(v_a.id, v_today) = 120000 AND pg_temp.cic_used(v_b.id, v_today) = 45000);

  -- ---- case 5: insufficient inventory ---------------------------------------------------------------------------------------------------
  v_op5 := pg_temp.cic_op(v_acc, v_conv, 50000);   -- 100,000 CUP; A has no room today, B has 120,000 - 45,000 = 75,000
  PERFORM pg_temp.cic_done(v_op5, v_agent);
  SELECT * INTO v_e5 FROM remittance_calculator_entries WHERE operation_id = v_op5 AND service = 'CUP';
  v_usdt := 75000::numeric / 1060 + 25000::numeric / 1100;
  v_fail := v_fail + pg_temp.cic_chk('5.partial: 75,000 consumed', (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE calculator_entry_id = v_e5.id) = 75000);
  v_fail := v_fail + pg_temp.cic_chk('5.the rest at the global rate: cup_rate = 100000 / (75000/1060 + 25000/1100)',
    pg_temp.cic_near(v_e5.cup_rate, 100000 / v_usdt) AND pg_temp.cic_near(v_e5.invertido_gyd, v_usdt * 240), format('cup_rate=%s invertido=%s', v_e5.cup_rate, v_e5.invertido_gyd));
  SELECT count(*) INTO v_cnt FROM notifications
   WHERE account_id = v_acc AND type = 'inventario_cup' AND body LIKE '%Cliente CIC%' AND body LIKE '%25,000%' AND user_id IN (v_owner, v_admin);
  v_fail := v_fail + pg_temp.cic_chk('5.alert for owner and admin (not the agent) naming the customer and 25,000', v_cnt = 2, format('count=%s', v_cnt));
  v_fail := v_fail + pg_temp.cic_chk('5.the agent got no inventory alert', NOT EXISTS (SELECT 1 FROM notifications WHERE user_id = v_agent AND type = 'inventario_cup'));
  v_op5b := pg_temp.cic_op(v_acc, v_conv, 10000);  -- 20,000 CUP with every limit used
  v_before := (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup');
  PERFORM pg_temp.cic_done(v_op5b, v_agent);
  SELECT * INTO v_e5b FROM remittance_calculator_entries WHERE operation_id = v_op5b AND service = 'CUP';
  v_fail := v_fail + pg_temp.cic_chk('5.nothing available: no consumption, global rate 1100, line still completed',
    v_e5b.status = 'completed' AND pg_temp.cic_near(v_e5b.cup_rate, 1100)
    AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE calculator_entry_id = v_e5b.id OR operation_id = v_op5b), format('rate=%s', v_e5b.cup_rate));
  v_fail := v_fail + pg_temp.cic_chk('5.another alert was raised', (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_before);

  -- ---- case 7 (before the void so the numbers are known): idempotence -----------------------------------------------------------------
  SELECT count(*) INTO v_cnt FROM cup_lot_consumptions WHERE account_id = v_acc;
  v_before := pg_temp.cic_remaining(v_a.id) + pg_temp.cic_remaining(v_b.id);
  PERFORM calculator_feed_operation(v_op2);
  v_fail := v_fail + pg_temp.cic_chk('7.re-feed of a live operation consumes nothing more',
    (SELECT count(*) FROM cup_lot_consumptions WHERE account_id = v_acc) = v_cnt AND pg_temp.cic_remaining(v_a.id) + pg_temp.cic_remaining(v_b.id) = v_before);
  SELECT * INTO v_r FROM cup_consumir(v_acc, 100000, v_e2.id, v_op2, now(), v_today);
  v_fail := v_fail + pg_temp.cic_chk('7.cup_consumir again for the same entry reports the existing 100,000 and writes nothing',
    v_r.consumed_cup = 100000 AND v_r.missing_cup = 0 AND pg_temp.cic_near(v_r.effective_rate, 100000 / (70000::numeric / 960 + 30000::numeric / 1060))
    AND (SELECT count(*) FROM cup_lot_consumptions WHERE account_id = v_acc) = v_cnt);

  -- ---- case 8: the report, the rate edit, deleting the manual line -----------------------------------------------------------------------
  PERFORM pg_temp.cic_claims(v_admin);
  v_rep := crm_inventario_cup(v_acc);
  PERFORM pg_temp.cic_claims(NULL);
  SELECT c INTO v_card FROM jsonb_array_elements(v_rep -> 'cards') c WHERE c ->> 'name' = 'Tarjeta B';
  v_fail := v_fail + pg_temp.cic_chk('8.report: B used today 120,000 (30,000 + 15,000 + 75,000) and no limit left',
    (v_card ->> 'used_today_cup')::numeric = 120000 AND (v_card ->> 'remaining_limit_today_cup')::numeric = 0, v_card::text);
  v_fail := v_fail + pg_temp.cic_chk('8.report: B lists its consumptions today with customer, source and lot rate',
    jsonb_array_length(v_card -> 'consumptions_today') = 3
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_card -> 'consumptions_today') m WHERE m ->> 'source' = 'manual' AND m ->> 'customer_name' = 'Manual CIC'
                  AND (m ->> 'amount_cup')::numeric = 15000 AND (m ->> 'lot_rate_cup_per_usdt')::numeric = 1060)
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_card -> 'consumptions_today') m WHERE m ->> 'source' = 'completed_operation' AND m ->> 'operation_id' = v_op2::text),
    v_card ->> 'consumptions_today');
  SELECT c INTO v_card FROM jsonb_array_elements(v_rep -> 'cards') c WHERE c ->> 'name' = 'Tarjeta A';
  v_fail := v_fail + pg_temp.cic_chk('8.report: the lot of A shows the remaining balance', EXISTS (
    SELECT 1 FROM jsonb_array_elements(v_card -> 'lots') l WHERE (l ->> 'remaining_cup')::numeric = 380000 AND (l ->> 'editable')::boolean = false));

  v_cnt := (SELECT count(*) FROM cup_lot_consumptions WHERE account_id = v_acc);
  v_before := pg_temp.cic_remaining(v_a.id) + pg_temp.cic_remaining(v_b.id);
  PERFORM pg_temp.cic_claims(v_admin);
  PERFORM crm_corregir_tasas_entrada_calculadora(v_e1.id, NULL, 1000);
  PERFORM pg_temp.cic_claims(NULL);
  v_fail := v_fail + pg_temp.cic_chk('8.a manual rate edit leaves the inventory untouched',
    (SELECT count(*) FROM cup_lot_consumptions WHERE account_id = v_acc) = v_cnt AND pg_temp.cic_remaining(v_a.id) + pg_temp.cic_remaining(v_b.id) = v_before);

  PERFORM pg_temp.cic_claims(v_admin);
  PERFORM crm_eliminar_entrada_calculadora(v_man);
  PERFORM pg_temp.cic_claims(NULL);
  v_fail := v_fail + pg_temp.cic_chk('8.deleting the manual line returns its 15,000 to B',
    pg_temp.cic_remaining(v_b.id) = 250000 - 30000 - 75000 + 15000 AND pg_temp.cic_used(v_b.id, v_today) = 105000
    AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE calculator_entry_id = v_man), format('B remaining=%s', pg_temp.cic_remaining(v_b.id)));
  PERFORM pg_temp.cic_claims(v_admin);
  PERFORM crm_eliminar_entrada_calculadora(v_man_y);
  PERFORM pg_temp.cic_claims(NULL);
  v_fail := v_fail + pg_temp.cic_chk('8.deleting the yesterday line returns its 10,000 to A', pg_temp.cic_used(v_a.id, v_gy_yday) = 0);

  -- ---- case 6: void returns the CUP; re-completing consumes once --------------------------------------------------------------------------
  v_before := pg_temp.cic_remaining(v_a.id);
  v_n := pg_temp.cic_remaining(v_b.id);
  PERFORM pg_temp.cic_revert(v_op2, v_agent);
  v_fail := v_fail + pg_temp.cic_chk('6.void: entry void, consumption rows gone',
    (SELECT status FROM remittance_calculator_entries WHERE id = v_e2.id) = 'void'
    AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE calculator_entry_id = v_e2.id OR operation_id = v_op2));
  v_fail := v_fail + pg_temp.cic_chk('6.void: 70,000 back to A and 30,000 back to B',
    pg_temp.cic_remaining(v_a.id) = v_before + 70000 AND pg_temp.cic_remaining(v_b.id) = v_n + 30000,
    format('A=%s (was %s) B=%s (was %s)', pg_temp.cic_remaining(v_a.id), v_before, pg_temp.cic_remaining(v_b.id), v_n));
  v_fail := v_fail + pg_temp.cic_chk('6.void: used today follows (A 50,000 left from case 1)', pg_temp.cic_used(v_a.id, v_today) = 50000);
  v_fail := v_fail + pg_temp.cic_chk('6.void: no lot above its amount', NOT EXISTS (SELECT 1 FROM cup_lots WHERE remaining_cup > amount_cup));
  PERFORM pg_temp.cic_done(v_op2, v_agent);
  v_fail := v_fail + pg_temp.cic_chk('6.re-completed: consumed once (100,000 in total, entry revived)',
    (SELECT status FROM remittance_calculator_entries WHERE id = v_e2.id) = 'completed'
    AND (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE calculator_entry_id = v_e2.id) = 100000);

  -- ---- case 9: account 2 (FIFO, inactive card, isolation) -----------------------------------------------------------------------------------
  SELECT * INTO v_r FROM cup_consumir(v_acc2, 40000, NULL, NULL, now(), v_today);
  v_fail := v_fail + pg_temp.cic_chk('9.FIFO: 30,000 from the older lot then 10,000 from the newer, exact rate',
    v_r.consumed_cup = 40000 AND v_r.missing_cup = 0
    AND pg_temp.cic_near(v_r.effective_rate, 40000 / (30000::numeric / 900 + 10000::numeric / 1000))
    AND (SELECT remaining_cup FROM cup_lots WHERE id = v_l1.id) = 0 AND (SELECT remaining_cup FROM cup_lots WHERE id = v_l2.id) = 20000,
    format('rate=%s', v_r.effective_rate));
  v_fail := v_fail + pg_temp.cic_chk('9.the inactive card (priority 0) was skipped', (SELECT remaining_cup FROM cup_lots WHERE id = v_ld.id) = 50000
    AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE card_id = v_d.id));
  SELECT * INTO v_r FROM cup_consumir(v_acc2, 100000, NULL, NULL, now(), v_today);
  v_fail := v_fail + pg_temp.cic_chk('9.more than is available: takes the 20,000 left, reports 80,000 missing', v_r.consumed_cup = 20000 AND v_r.missing_cup = 80000);
  v_fail := v_fail + pg_temp.cic_chk('9.isolation: account 1''s activity never touched account 2''s lots (and vice versa)',
    pg_temp.cic_remaining(v_a.id) + pg_temp.cic_remaining(v_b.id) = (500000 + 250000) - (SELECT sum(amount_cup) FROM cup_lot_consumptions WHERE account_id = v_acc)
    AND NOT EXISTS (SELECT 1 FROM cup_lot_consumptions k JOIN cup_lots l ON l.id = k.lot_id WHERE k.account_id <> l.account_id));
  -- refill account 2's card C for case 10
  PERFORM pg_temp.cic_claims(v_admin2);
  v_lf := crm_cargar_lote_cup(v_acc2, v_c.id, 200000, 950, 'lote F', NULL);
  PERFORM pg_temp.cic_claims(NULL);

  -- ---- case 10: an inventory failure never aborts the feed --------------------------------------------------------------------------------------
  ALTER TABLE cup_lots ADD CONSTRAINT zz_cic_poison CHECK (remaining_cup >= 1e12) NOT VALID;   -- every UPDATE of a lot now fails
  v_opf := pg_temp.cic_op(v_acc2, v_conv2, 25000);
  PERFORM pg_temp.cic_done(v_opf, v_admin2);
  ALTER TABLE cup_lots DROP CONSTRAINT zz_cic_poison;
  SELECT * INTO v_ef FROM remittance_calculator_entries WHERE operation_id = v_opf AND service = 'CUP';
  v_fail := v_fail + pg_temp.cic_chk('10.the line was written with the GLOBAL rate despite the failure',
    v_ef.id IS NOT NULL AND v_ef.status = 'completed' AND pg_temp.cic_near(v_ef.cup_rate, 1100), format('status=%s rate=%s', v_ef.status, v_ef.cup_rate));
  v_fail := v_fail + pg_temp.cic_chk('10.the operation stayed completed', (SELECT status FROM remittance_operations WHERE id = v_opf) = 'completed');
  v_fail := v_fail + pg_temp.cic_chk('10.nothing was left behind by the failed consumption',
    NOT EXISTS (SELECT 1 FROM cup_lot_consumptions WHERE operation_id = v_opf) AND (SELECT remaining_cup FROM cup_lots WHERE id = v_lf.id) = 200000);
  v_fail := v_fail + pg_temp.cic_chk('10.an error notification was raised',
    EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc2 AND type = 'inventario_cup' AND title = 'Error en el inventario CUP'));

  -- ---- case 11: grants ---------------------------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cic_chk('11.internal functions are not executable by authenticated / anon',
    NOT has_function_privilege('authenticated', 'public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cup_devolver(uuid, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cup_devolver(uuid, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cup_alertar(uuid, uuid, text, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cup_alertar(uuid, uuid, text, text)', 'EXECUTE'));

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'cup-inventory-consumption: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE NOTICE 'cup-inventory-consumption: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT cup_inventory_consumption;
