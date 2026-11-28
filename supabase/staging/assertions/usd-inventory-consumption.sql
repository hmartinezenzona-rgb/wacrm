\set ON_ERROR_STOP on
-- usd-inventory-consumption.sql -- self-reverting assertion for 356_usd_inventory_consumption.sql
--
-- odd/tasks/usd-card-inventory.md (T2). Proves the Clasica / Tropical USD inventory is consumed, costed, returned and enforced.
-- Fixture account 1: rates usdt_buy_gyd 238, usdt_sell_gyd 260 (so 26,000 GYD = 100 USD); Clasica card A (priority 1, lots L1 500 USD for
-- 476.19 USDT = 1.0500115 loaded first, L2 200 USD for 160 USDT = 1.25), Clasica card B (priority 2, monthly limit 50 on purpose: the limit
-- is INFORMATIONAL, lot L3 300 USD @ 1.00), Tropical card T (lot T1 100 USD for 80 USDT = 1.25). Account 2 has NO USD card.
--   case 1   100 USD Clasica send: one consumption (100 from L1) linked to the entry and the operation, invertido = 100 / usd_per_usdt * 238,
--            retorno = facturado - invertido, L1 400 left, the report shows 400 balance / 100 used this month; cost_gyd stays NULL
--   case 2   cancel (revert completed) returns the USD (rows gone, entry void); completing again consumes once
--   case 3   split: 450 USD = 400 from L1 + 50 from L2 (FIFO inside a card); 250 USD = 150 from L2 + 100 from card B although B is over its
--            monthly limit of 50 (informational); each invertido is the exact sum of part / lot rate * 238; usd_planificar / usd_faltante
--   case 4   hard block, 22023 'usd_inventory_insufficient:<SERVICE>:<missing>': crm_cerrar_operacion_manual with the service chosen in the
--            panel (Tropical 150 vs 100 -> TROPICAL:50), crm_entregar_operacion (funded, Clasica 300 vs 200 -> CLASICA:100); status stays
--            ready_to_transfer, nothing consumed; the same operations pass when the balance covers them (Tropical 100 -> invertido 80 * 238)
--   case 5   idempotent: re-feeding a live operation and calling usd_consumir again for the same entry take nothing more
--   case 6   deleting a chat entry (crm_eliminar_entrada_calculadora) returns its USD
--   case 7   manual lines: a USD Clasica line consumes (kind manual, typed figures untouched); a larger one consumes what is left and raises
--            an 'inventario_cup' notification (never blocks); a non-USD line consumes nothing and alerts; deleting returns the USD
--   case 8   shortfall bypassing the block (direct completion): partial = consumed / rate + missing at the buy rate, alert; empty = today's cost
--   case 9   an inventory failure never aborts the feed: poisoned lot constraint -> entry still written at the global cost + error alert
--   case 10  CUP and other services untouched: a CUP operation takes nothing from USD and keeps its global-rate cost
--   case 11  account 2 (no USD card): Clasica op keeps today's cost 100 * 238, no consumption, not blocked at any size; manual line untouched
--   case 12  Mexico operations never touch the USD cards
--   case 13  the panel plan RPC: plan (blocked / not blocked, per service lines, cards), completed (lines + cost), no_inventory, not_usd,
--            unavailable, no_amounts; agent allowed, a stranger 42501
--   case 14  grants: the internal functions are not executable by authenticated / anon; the panel RPC only by authenticated
--
-- Run it as: BEGIN; \i 355; \i 356; \i this file; ROLLBACK;  (STAGING only). It ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.

CREATE FUNCTION pg_temp.uc_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.uc_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

CREATE FUNCTION pg_temp.uc_near(a numeric, b numeric) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT a IS NOT NULL AND b IS NOT NULL AND abs(a - b) < 0.000000001;
$f$;

-- Runs a statement as p_uid; returns 'OK' or '<sqlstate>|<message>'.
CREATE FUNCTION pg_temp.uc_try(p_sql text, p_uid uuid) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.uc_claims(p_uid);
  BEGIN
    EXECUTE p_sql;
    PERFORM pg_temp.uc_claims(NULL);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.uc_claims(NULL);
    RETURN SQLSTATE || '|' || SQLERRM;
  END;
END $f$;

CREATE FUNCTION pg_temp.uc_op(p_acct uuid, p_conv uuid, p_gyd numeric, p_method text DEFAULT NULL, p_service text DEFAULT 'remesa') RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acct, p_conv, 'ready_to_transfer', p_service, 'GYD', p_gyd, p_method) RETURNING id INTO v;
  RETURN v;
END $f$;

-- A recipient of the given rail (complete enough for crm_beneficiarios_completos).
CREATE FUNCTION pg_temp.uc_ben(p_op uuid, p_type text) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, position, status, source)
  VALUES (p_op, p_type, 'PRUEBA USD', '9225000000000001', '53000000', 1, 'vigente', 'manual');
END $f$;

CREATE FUNCTION pg_temp.uc_fund(p_op uuid, p_gyd numeric) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('356' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), p_gyd, 'GYD', 'PRUEBA 356', now(), now(), p_op);
END $f$;

CREATE FUNCTION pg_temp.uc_done(p_op uuid, p_actor uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.uc_claims(p_actor);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = p_actor WHERE id = p_op;
  PERFORM pg_temp.uc_claims(NULL);
END $f$;

CREATE FUNCTION pg_temp.uc_revert(p_op uuid, p_actor uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.uc_claims(p_actor);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = p_op;
  PERFORM pg_temp.uc_claims(NULL);
END $f$;

CREATE FUNCTION pg_temp.uc_balance(p_card uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT coalesce(sum(remaining_usd), 0) FROM usd_lots WHERE card_id = p_card;
$f$;

CREATE FUNCTION pg_temp.uc_taken(p_entry uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE calculator_entry_id = p_entry;
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid(); v_stranger uuid := gen_random_uuid();
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_contact uuid; v_conv uuid; v_contact2 uuid; v_conv2 uuid;
  v_ca usd_cards; v_cb usd_cards; v_ct usd_cards;
  v_l1 usd_lots; v_l2 usd_lots; v_l3 usd_lots; v_t1 usd_lots; v_t2 usd_lots;
  v_op1 uuid; v_op2 uuid; v_op3 uuid; v_op4 uuid; v_opb1 uuid; v_opb2 uuid; v_opb3 uuid; v_opb4 uuid; v_opb5 uuid;
  v_ops1 uuid; v_ops2 uuid; v_ops3 uuid; v_opp uuid; v_opp2 uuid; v_opc uuid; v_opcup uuid; v_opmx uuid; v_opn1 uuid; v_opn2 uuid; v_opcan uuid; v_opna uuid;
  v_e1 remittance_calculator_entries; v_e2 remittance_calculator_entries; v_e3 remittance_calculator_entries; v_e4 remittance_calculator_entries;
  v_ee remittance_calculator_entries; v_en remittance_calculator_entries; v_ecup remittance_calculator_entries; v_emx remittance_calculator_entries;
  v_man1 uuid; v_man2 uuid; v_man3 uuid; v_mann uuid;
  v_month date; v_gy_today date; v_r1 numeric; v_cnt integer; v_n numeric; v_msg text; v_rep jsonb; v_plan jsonb; v_row record; v_res text; v_notif integer;
  v_fail integer := 0;
BEGIN
  v_month := usd_cuba_month(now());
  v_gy_today := (now() AT TIME ZONE 'America/Guyana')::date;

  -- ---- fixtures ---------------------------------------------------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'uc-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_owner2, v_admin2, v_stranger]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'usd consumption test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'usd consumption account without cards', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'uc owner', 'uc-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'uc admin', 'uc-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'uc agent', 'uc-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_owner2, 'uc owner2', 'uc-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'uc admin2', 'uc-' || v_admin2 || '@test.invalid', v_acc2, 'admin');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '15550003560', v_acc, 'Cliente UC') RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_contact, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner2, '15550003561', v_acc2, 'Cliente UC2') RETURNING id INTO v_contact2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner2, v_contact2, v_acc2) RETURNING id INTO v_conv2;

  PERFORM pg_temp.uc_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 238, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  PERFORM pg_temp.uc_claims(v_admin2);
  PERFORM crm_set_calculator_rates(v_acc2, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 238, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  PERFORM pg_temp.uc_claims(v_admin);
  v_ca := crm_guardar_tarjeta_usd(v_acc, NULL, 'CLASICA', 'Clasica A', '1111', 1, NULL, NULL);
  v_cb := crm_guardar_tarjeta_usd(v_acc, NULL, 'CLASICA', 'Clasica B', '2222', 2, 50, NULL);
  v_ct := crm_guardar_tarjeta_usd(v_acc, NULL, 'TROPICAL', 'Tropical A', '3333', 1, NULL, NULL);
  v_l1 := crm_cargar_lote_usd(v_acc, v_ca.id, 500, 476.19, now() - interval '3 days', 'L1');
  v_l3 := crm_cargar_lote_usd(v_acc, v_cb.id, 300, 300, now() - interval '3 days', 'L3');
  v_t1 := crm_cargar_lote_usd(v_acc, v_ct.id, 100, 80, now() - interval '3 days', 'T1');
  PERFORM pg_temp.uc_claims(NULL);
  v_r1 := 500::numeric / 476.19;

  -- ---- case 1: 100 USD Clasica send from L1 -------------------------------------------------------------------------------------------
  v_op1 := pg_temp.uc_op(v_acc, v_conv, 26000, 'clasica');
  PERFORM pg_temp.uc_done(v_op1, v_agent);
  SELECT * INTO v_e1 FROM remittance_calculator_entries WHERE operation_id = v_op1 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('1.entry: 100 USD completed', v_e1.amount = 100 AND v_e1.amount_currency = 'USD' AND v_e1.status = 'completed',
    format('amount=%s cur=%s status=%s', v_e1.amount, v_e1.amount_currency, v_e1.status));
  v_fail := v_fail + pg_temp.uc_chk('1.invertido = 100 / usd_per_usdt * usdt_buy_gyd', pg_temp.uc_near(v_e1.invertido_gyd, 100 / v_r1 * 238),
    format('invertido=%s expected=%s', v_e1.invertido_gyd, 100 / v_r1 * 238));
  v_fail := v_fail + pg_temp.uc_chk('1.facturado is the deposit, retorno = facturado - invertido', v_e1.facturado_gyd = 26000 AND pg_temp.uc_near(v_e1.retorno_gyd, 26000 - v_e1.invertido_gyd));
  v_fail := v_fail + pg_temp.uc_chk('1.cost_gyd stays NULL (as before)', v_e1.cost_gyd IS NULL);
  SELECT count(*), coalesce(sum(amount_usd), 0) INTO v_cnt, v_n FROM usd_lot_consumptions
   WHERE calculator_entry_id = v_e1.id AND operation_id = v_op1 AND lot_id = v_l1.id AND kind = 'operacion' AND cuba_month = v_month;
  v_fail := v_fail + pg_temp.uc_chk('1.one consumption of 100 from L1 linked to entry and operation, this Cuba month', v_cnt = 1 AND v_n = 100, format('rows=%s sum=%s', v_cnt, v_n));
  v_fail := v_fail + pg_temp.uc_chk('1.L1 400 left, B and Tropical untouched', pg_temp.uc_balance(v_ca.id) = 400 AND pg_temp.uc_balance(v_cb.id) = 300 AND pg_temp.uc_balance(v_ct.id) = 100);
  PERFORM pg_temp.uc_claims(v_admin);
  v_rep := crm_inventario_usd(v_acc);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('1.report: Clasica balance 700 and 100 / 5,000 used on card A',
    (v_rep -> 'totals' -> 'CLASICA' ->> 'balance_usd')::numeric = 700
    AND (SELECT (c ->> 'used_this_month_usd')::numeric = 100 AND (c ->> 'balance_usd')::numeric = 400 AND (c ->> 'monthly_limit_usd')::numeric = 5000
          FROM jsonb_array_elements(v_rep -> 'cards') c WHERE c ->> 'id' = v_ca.id::text), v_rep::text);

  -- ---- case 2: cancel returns the USD, completing again takes it once ----------------------------------------------------------------
  PERFORM pg_temp.uc_revert(v_op1, v_agent);
  v_fail := v_fail + pg_temp.uc_chk('2.cancel: entry void, consumption rows gone, L1 back to 500',
    (SELECT status FROM remittance_calculator_entries WHERE id = v_e1.id) = 'void'
    AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE operation_id = v_op1 OR calculator_entry_id = v_e1.id)
    AND pg_temp.uc_balance(v_ca.id) = 500);
  PERFORM pg_temp.uc_done(v_op1, v_agent);
  v_fail := v_fail + pg_temp.uc_chk('2.completing again consumes 100 once (L1 400, one row)',
    pg_temp.uc_balance(v_ca.id) = 400 AND (SELECT count(*) FROM usd_lot_consumptions WHERE operation_id = v_op1) = 1);
  SELECT * INTO v_e1 FROM remittance_calculator_entries WHERE operation_id = v_op1 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('2.the revived entry is live with the lot cost', v_e1.status = 'completed' AND pg_temp.uc_near(v_e1.invertido_gyd, 100 / v_r1 * 238));

  -- ---- case 3: FIFO inside a card, split across cards, the limit is informational ------------------------------------------------------
  PERFORM pg_temp.uc_claims(v_admin);
  v_l2 := crm_cargar_lote_usd(v_acc, v_ca.id, 200, 160, now() - interval '1 day', 'L2');
  PERFORM pg_temp.uc_claims(NULL);
  v_op2 := pg_temp.uc_op(v_acc, v_conv, 117000, 'clasica');
  PERFORM pg_temp.uc_done(v_op2, v_agent);
  SELECT * INTO v_e2 FROM remittance_calculator_entries WHERE operation_id = v_op2 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('3.450 USD = 400 from L1 + 50 from L2',
    (SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE calculator_entry_id = v_e2.id AND lot_id = v_l1.id) = 400
    AND (SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE calculator_entry_id = v_e2.id AND lot_id = v_l2.id) = 50);
  v_fail := v_fail + pg_temp.uc_chk('3.invertido = (400 / r1 + 50 / 1.25) * 238', pg_temp.uc_near(v_e2.invertido_gyd, (400 / v_r1 + 50 / 1.25) * 238),
    format('invertido=%s', v_e2.invertido_gyd));
  v_op3 := pg_temp.uc_op(v_acc, v_conv, 65000, 'clasica');
  PERFORM pg_temp.uc_done(v_op3, v_agent);
  SELECT * INTO v_e3 FROM remittance_calculator_entries WHERE operation_id = v_op3 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('3.250 USD = 150 from L2 (card A) + 100 from card B although B is past its monthly limit of 50',
    (SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE calculator_entry_id = v_e3.id AND lot_id = v_l2.id) = 150
    AND (SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE calculator_entry_id = v_e3.id AND lot_id = v_l3.id) = 100);
  v_fail := v_fail + pg_temp.uc_chk('3.invertido = (150 / 1.25 + 100 / 1) * 238', pg_temp.uc_near(v_e3.invertido_gyd, (150 / 1.25 + 100) * 238), format('invertido=%s', v_e3.invertido_gyd));
  v_fail := v_fail + pg_temp.uc_chk('3.balances A 0 / B 200', pg_temp.uc_balance(v_ca.id) = 0 AND pg_temp.uc_balance(v_cb.id) = 200);
  SELECT coalesce(jsonb_agg(jsonb_build_object('c', p.card_id, 'l', p.lot_id, 'a', p.amount_usd, 'r', p.usd_per_usdt) ORDER BY p.seq), '[]'::jsonb) INTO v_plan
    FROM usd_planificar(v_acc, 'CLASICA', 250, now()) p;
  v_fail := v_fail + pg_temp.uc_chk('3.usd_planificar(250) plans only what exists: one row, 200 from L3 @ 1',
    jsonb_array_length(v_plan) = 1 AND (v_plan -> 0 ->> 'a')::numeric = 200 AND (v_plan -> 0 ->> 'l') = v_l3.id::text AND (v_plan -> 0 ->> 'r')::numeric = 1, v_plan::text);
  v_fail := v_fail + pg_temp.uc_chk('3.usd_faltante(250) = 50 and usd_faltante(150) = 0, the plan is read-only',
    usd_faltante(v_acc, 'CLASICA', 250, now()) = 50 AND usd_faltante(v_acc, 'CLASICA', 150, now()) = 0 AND pg_temp.uc_balance(v_cb.id) = 200);
  v_fail := v_fail + pg_temp.uc_chk('3.the plan of an unknown or inactive service is empty', NOT EXISTS (SELECT 1 FROM usd_planificar(v_acc, 'ZELLE', 10, now())));

  -- ---- case 4: hard block ---------------------------------------------------------------------------------------------------------------
  -- 4a: manual close choosing Tropical in the panel (no recipient): 150 USD vs 100
  v_opb1 := pg_temp.uc_op(v_acc, v_conv, 39000, NULL);
  v_res := pg_temp.uc_try(format('SELECT crm_cerrar_operacion_manual(%L, NULL, false, ''tropical'')', v_opb1), v_admin);
  v_fail := v_fail + pg_temp.uc_chk('4a.manual close: Tropical 150 vs 100 -> 22023 usd_inventory_insufficient:TROPICAL:50',
    v_res LIKE '22023|usd_inventory_insufficient:TROPICAL:50%', v_res);
  v_fail := v_fail + pg_temp.uc_chk('4a.the operation stays ready_to_transfer, nothing was consumed',
    (SELECT status FROM remittance_operations WHERE id = v_opb1) = 'ready_to_transfer' AND pg_temp.uc_balance(v_ct.id) = 100
    AND NOT EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE operation_id = v_opb1));
  -- 4b: delivery with a Clasica recipient, funded: 300 USD vs 200
  v_opb2 := pg_temp.uc_op(v_acc, v_conv, 78000, 'clasica');
  PERFORM pg_temp.uc_ben(v_opb2, 'clasica');
  PERFORM pg_temp.uc_fund(v_opb2, 78000);
  v_res := pg_temp.uc_try(format('SELECT crm_entregar_operacion(%L, ''{"mode":"skip_proof"}''::jsonb, true, NULL)', v_opb2), v_agent);
  v_fail := v_fail + pg_temp.uc_chk('4b.delivery: Clasica 300 vs 200 -> 22023 usd_inventory_insufficient:CLASICA:100',
    v_res LIKE '22023|usd_inventory_insufficient:CLASICA:100%', v_res);
  v_fail := v_fail + pg_temp.uc_chk('4b.refused: ready_to_transfer, no entry, balance intact',
    (SELECT status FROM remittance_operations WHERE id = v_opb2) = 'ready_to_transfer' AND pg_temp.uc_balance(v_cb.id) = 200
    AND NOT EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE operation_id = v_opb2));
  -- the older funds/recipient checks still win (they run first): an unfunded operation keeps its funding refusal
  v_opb3 := pg_temp.uc_op(v_acc, v_conv, 78000, 'clasica');
  PERFORM pg_temp.uc_ben(v_opb3, 'clasica');
  v_res := pg_temp.uc_try(format('SELECT crm_entregar_operacion(%L, ''{"mode":"skip_proof"}''::jsonb, true, NULL)', v_opb3), v_agent);
  v_fail := v_fail + pg_temp.uc_chk('4c.an unfunded operation still gets the funding refusal first', v_res LIKE '22023|%verified funding%', v_res);
  -- 4d: the plan RPC says the same (blocked, missing) before anything is attempted
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_opb2);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('4d.panel plan: state plan, blocked, CLASICA needs 300, plans 200, missing 100',
    v_plan ->> 'state' = 'plan' AND (v_plan ->> 'blocked')::boolean
    AND (SELECT (s ->> 'needed_usd')::numeric = 300 AND (s ->> 'planned_usd')::numeric = 200 AND (s ->> 'missing_usd')::numeric = 100 AND (s ->> 'blocked')::boolean
          FROM jsonb_array_elements(v_plan -> 'services') s WHERE s ->> 'service' = 'CLASICA'), v_plan::text);
  -- 4e: the same operations pass when the balance covers them
  v_opb4 := pg_temp.uc_op(v_acc, v_conv, 26000, 'tropical');
  PERFORM pg_temp.uc_ben(v_opb4, 'tropical');
  PERFORM pg_temp.uc_fund(v_opb4, 26000);
  v_res := pg_temp.uc_try(format('SELECT crm_entregar_operacion(%L, ''{"mode":"skip_proof"}''::jsonb, true, NULL)', v_opb4), v_agent);
  v_fail := v_fail + pg_temp.uc_chk('4e.Tropical 100 vs 100 delivers', v_res = 'OK', v_res);
  SELECT * INTO v_e4 FROM remittance_calculator_entries WHERE operation_id = v_opb4 AND service = 'TROPICAL';
  v_fail := v_fail + pg_temp.uc_chk('4e.Tropical entry: invertido = 100 / 1.25 * 238 = 80 * 238, T1 empty, 100 consumed',
    pg_temp.uc_near(v_e4.invertido_gyd, 80 * 238) AND pg_temp.uc_balance(v_ct.id) = 0 AND pg_temp.uc_taken(v_e4.id) = 100, format('invertido=%s', v_e4.invertido_gyd));
  v_opb5 := pg_temp.uc_op(v_acc, v_conv, 39000, NULL);
  v_res := pg_temp.uc_try(format('SELECT crm_cerrar_operacion_manual(%L, NULL, false, ''tropical'')', v_opb5), v_admin);
  v_fail := v_fail + pg_temp.uc_chk('4f.Tropical is now empty: a 150 manual close says TROPICAL:150', v_res LIKE '22023|usd_inventory_insufficient:TROPICAL:150%', v_res);
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_opb5;
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_opb2;
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_opb3;
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_opb1;
  -- a Clasica manual close that fits passes (admin, 20 USD from card B)
  v_opb1 := pg_temp.uc_op(v_acc, v_conv, 5200, NULL);
  v_res := pg_temp.uc_try(format('SELECT crm_cerrar_operacion_manual(%L, NULL, false, ''clasica'')', v_opb1), v_admin);
  v_fail := v_fail + pg_temp.uc_chk('4g.a manual close that fits passes and takes 20 USD from card B', v_res = 'OK' AND pg_temp.uc_balance(v_cb.id) = 180, v_res || ' bal=' || pg_temp.uc_balance(v_cb.id));

  -- ---- case 5: idempotent -------------------------------------------------------------------------------------------------------------
  PERFORM calculator_feed_operation(v_op2);
  SELECT count(*) INTO v_cnt FROM usd_lot_consumptions WHERE calculator_entry_id = v_e2.id;
  SELECT * INTO v_row FROM usd_consumir(v_acc, 'CLASICA', 450, v_e2.id, v_op2, now(), 'operacion');
  v_fail := v_fail + pg_temp.uc_chk('5.re-feeding and calling usd_consumir again take nothing more (reported as already taken)',
    v_cnt = 2 AND (SELECT count(*) FROM usd_lot_consumptions WHERE calculator_entry_id = v_e2.id) = 2 AND v_row.consumed_usd = 450 AND v_row.missing_usd = 0
    AND pg_temp.uc_balance(v_cb.id) = 180, format('rows=%s consumed=%s', v_cnt, v_row.consumed_usd));
  v_fail := v_fail + pg_temp.uc_chk('5.invested_usdt of the repeat call = 400 / r1 + 50 / 1.25', pg_temp.uc_near(v_row.invested_usdt, 400 / v_r1 + 50 / 1.25));

  -- ---- case 6: deleting a chat entry returns the USD ------------------------------------------------------------------------------------
  v_op4 := pg_temp.uc_op(v_acc, v_conv, 5200, 'clasica');
  PERFORM pg_temp.uc_done(v_op4, v_agent);
  SELECT * INTO v_ee FROM remittance_calculator_entries WHERE operation_id = v_op4 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('6.a 20 USD send took 20 from card B (160 left)', pg_temp.uc_balance(v_cb.id) = 160 AND pg_temp.uc_taken(v_ee.id) = 20);
  PERFORM pg_temp.uc_claims(v_admin);
  PERFORM crm_eliminar_entrada_calculadora(v_ee.id);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('6.deleting the entry gives the 20 USD back and removes its rows',
    pg_temp.uc_balance(v_cb.id) = 180 AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE calculator_entry_id = v_ee.id));

  -- ---- case 7: manual lines ------------------------------------------------------------------------------------------------------------
  PERFORM pg_temp.uc_claims(v_agent);
  PERFORM crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual USD', 'service', 'CLASICA', 'currency', 'USD', 'amount', 30, 'facturado_gyd', 7800, 'invertido_gyd', 7000,
    'retorno_gyd', 800, 'date', v_gy_today::text)));
  PERFORM pg_temp.uc_claims(NULL);
  SELECT id INTO v_man1 FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Manual USD';
  v_fail := v_fail + pg_temp.uc_chk('7.manual Clasica USD line took 30 from card B as kind manual, linked to the entry',
    (SELECT count(*) = 1 AND sum(amount_usd) = 30 AND min(kind) = 'manual' AND min(card_id::text) = v_cb.id::text FROM usd_lot_consumptions WHERE calculator_entry_id = v_man1)
    AND pg_temp.uc_balance(v_cb.id) = 150);
  v_fail := v_fail + pg_temp.uc_chk('7.the typed figures are untouched',
    (SELECT invertido_gyd = 7000 AND facturado_gyd = 7800 AND retorno_gyd = 800 FROM remittance_calculator_entries WHERE id = v_man1));
  SELECT count(*) INTO v_notif FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup';
  PERFORM pg_temp.uc_claims(v_agent);
  PERFORM crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual Grande', 'service', 'CLASICA', 'currency', 'USD', 'amount', 500, 'facturado_gyd', 130000, 'invertido_gyd', 119000,
    'retorno_gyd', 11000, 'date', v_gy_today::text)));
  PERFORM pg_temp.uc_claims(NULL);
  SELECT id INTO v_man2 FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Manual Grande';
  v_fail := v_fail + pg_temp.uc_chk('7.a manual line larger than the balance is registered, consumes the 150 left and never blocks',
    v_man2 IS NOT NULL AND pg_temp.uc_taken(v_man2) = 150 AND pg_temp.uc_balance(v_cb.id) = 0);
  v_fail := v_fail + pg_temp.uc_chk('7.the shortfall (350) raises a notification naming the customer',
    (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_notif
    AND EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup' AND body LIKE '%Manual Grande%' AND body LIKE '%350%'));
  SELECT count(*) INTO v_notif FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup';
  PERFORM pg_temp.uc_claims(v_agent);
  PERFORM crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual GYD', 'service', 'CLASICA', 'currency', 'GYD', 'amount', 5000, 'facturado_gyd', 5000, 'invertido_gyd', 4000,
    'retorno_gyd', 1000, 'date', v_gy_today::text)));
  PERFORM pg_temp.uc_claims(NULL);
  SELECT id INTO v_man3 FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Manual GYD';
  v_fail := v_fail + pg_temp.uc_chk('7.a non-USD Clasica line is registered, takes nothing and alerts',
    v_man3 IS NOT NULL AND pg_temp.uc_taken(v_man3) = 0 AND (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_notif);
  PERFORM pg_temp.uc_claims(v_admin);
  PERFORM crm_eliminar_entrada_calculadora(v_man1);
  PERFORM crm_eliminar_entrada_calculadora(v_man2);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('7.deleting the manual lines returns their USD (card B back to 180)', pg_temp.uc_balance(v_cb.id) = 180 AND pg_temp.uc_taken(v_man1) = 0 AND pg_temp.uc_taken(v_man2) = 0);

  -- ---- case 8: shortfall that bypassed the block ------------------------------------------------------------------------------------------
  PERFORM pg_temp.uc_claims(v_admin);
  v_t2 := crm_cargar_lote_usd(v_acc, v_ct.id, 10, 8, now(), 'T2');
  PERFORM pg_temp.uc_claims(NULL);
  v_ops1 := pg_temp.uc_op(v_acc, v_conv, 6500, 'tropical');   -- 25 USD, only 10 on the card
  SELECT count(*) INTO v_notif FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup';
  PERFORM pg_temp.uc_done(v_ops1, v_agent);
  SELECT * INTO v_en FROM remittance_calculator_entries WHERE operation_id = v_ops1 AND service = 'TROPICAL';
  v_fail := v_fail + pg_temp.uc_chk('8.partial: 10 consumed, invertido = (10 / 1.25 + 15) * 238, retorno consistent',
    pg_temp.uc_taken(v_en.id) = 10 AND pg_temp.uc_near(v_en.invertido_gyd, (10 / 1.25 + 15) * 238) AND pg_temp.uc_near(v_en.retorno_gyd, v_en.facturado_gyd - v_en.invertido_gyd),
    format('taken=%s invertido=%s', pg_temp.uc_taken(v_en.id), v_en.invertido_gyd));
  v_fail := v_fail + pg_temp.uc_chk('8.partial: an alert names the customer and the 15 missing',
    (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_notif
    AND EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup' AND body LIKE '%Cliente UC%' AND body LIKE '%15%'));
  v_ops2 := pg_temp.uc_op(v_acc, v_conv, 5200, 'tropical');   -- 20 USD, card empty
  PERFORM pg_temp.uc_done(v_ops2, v_agent);
  SELECT * INTO v_en FROM remittance_calculator_entries WHERE operation_id = v_ops2 AND service = 'TROPICAL';
  v_fail := v_fail + pg_temp.uc_chk('8.empty: nothing consumed, invertido = today''s 20 * 238',
    pg_temp.uc_taken(v_en.id) = 0 AND pg_temp.uc_near(v_en.invertido_gyd, 20 * 238) AND v_en.status = 'completed');

  -- ---- case 9: an inventory failure never aborts the feed ----------------------------------------------------------------------------
  ALTER TABLE usd_lots ADD CONSTRAINT usd_lots_poison_chk CHECK (remaining_usd = amount_usd) NOT VALID;
  v_ops3 := pg_temp.uc_op(v_acc, v_conv, 5200, 'clasica');
  SELECT count(*) INTO v_notif FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup';
  PERFORM pg_temp.uc_done(v_ops3, v_agent);
  ALTER TABLE usd_lots DROP CONSTRAINT usd_lots_poison_chk;
  SELECT * INTO v_en FROM remittance_calculator_entries WHERE operation_id = v_ops3 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('9.poisoned inventory: the entry is still written at today''s cost (20 * 238), status completed',
    v_en.id IS NOT NULL AND v_en.status = 'completed' AND pg_temp.uc_near(v_en.invertido_gyd, 20 * 238)
    AND (SELECT status FROM remittance_operations WHERE id = v_ops3) = 'completed', format('invertido=%s', v_en.invertido_gyd));
  v_fail := v_fail + pg_temp.uc_chk('9.poisoned inventory: nothing left behind, an error alert raised',
    pg_temp.uc_taken(v_en.id) = 0 AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE operation_id = v_ops3)
    AND (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_notif);

  -- ---- case 10: CUP untouched ------------------------------------------------------------------------------------------------------------
  v_opcup := pg_temp.uc_op(v_acc, v_conv, 20000, 'cuban_card');
  SELECT coalesce(sum(amount_usd), 0) INTO v_n FROM usd_lot_consumptions WHERE account_id = v_acc;
  PERFORM pg_temp.uc_done(v_opcup, v_agent);
  SELECT * INTO v_ecup FROM remittance_calculator_entries WHERE operation_id = v_opcup AND service = 'CUP';
  v_fail := v_fail + pg_temp.uc_chk('10.a CUP operation keeps the global-rate cost (40,000 / 1100 * 238) and takes nothing from the USD cards',
    v_ecup.amount = 40000 AND pg_temp.uc_near(v_ecup.invertido_gyd, 40000::numeric / 1100 * 238)
    AND (SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE account_id = v_acc) = v_n, format('invertido=%s', v_ecup.invertido_gyd));

  -- ---- case 11: an account without USD cards behaves as before --------------------------------------------------------------------------
  v_opn1 := pg_temp.uc_op(v_acc2, v_conv2, 26000, 'clasica');
  PERFORM pg_temp.uc_done(v_opn1, v_owner2);
  SELECT * INTO v_en FROM remittance_calculator_entries WHERE operation_id = v_opn1 AND service = 'CLASICA';
  v_fail := v_fail + pg_temp.uc_chk('11.no card: invertido = 100 * 238 exactly as before, no consumption, nobody alerted',
    v_en.amount = 100 AND v_en.invertido_gyd = 100 * 238 AND v_en.retorno_gyd = 26000 - 100 * 238
    AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE account_id = v_acc2) AND NOT EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc2 AND type = 'inventario_cup'),
    format('invertido=%s', v_en.invertido_gyd));
  v_opn2 := pg_temp.uc_op(v_acc2, v_conv2, 2600000, NULL);
  v_res := pg_temp.uc_try(format('SELECT crm_cerrar_operacion_manual(%L, NULL, false, ''tropical'')', v_opn2), v_admin2);
  v_fail := v_fail + pg_temp.uc_chk('11.no card: a 10,000 USD Tropical close is not blocked', v_res = 'OK', v_res);
  PERFORM pg_temp.uc_claims(v_admin2);
  PERFORM crm_registrar_entradas_manuales(v_acc2, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual sin tarjeta', 'service', 'TROPICAL', 'currency', 'USD', 'amount', 40, 'facturado_gyd', 10400, 'invertido_gyd', 9500,
    'retorno_gyd', 900, 'date', v_gy_today::text)));
  PERFORM pg_temp.uc_claims(NULL);
  SELECT id INTO v_mann FROM remittance_calculator_entries WHERE account_id = v_acc2 AND source = 'manual';
  v_fail := v_fail + pg_temp.uc_chk('11.no card: the manual line is stored as typed and consumes / alerts nothing',
    v_mann IS NOT NULL AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE account_id = v_acc2)
    AND NOT EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc2 AND type = 'inventario_cup'));
  PERFORM pg_temp.uc_claims(v_admin2);
  v_plan := crm_inventario_usd_operacion(v_opn1);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('11.panel plan for a completed op without cards: state not_usd or no_inventory, never a plan',
    v_plan ->> 'state' IN ('no_inventory', 'not_usd'), v_plan::text);

  -- ---- case 12: Mexico never touches the USD cards ------------------------------------------------------------------------------------------------
  SELECT coalesce(sum(amount_usd), 0) INTO v_n FROM usd_lot_consumptions WHERE account_id = v_acc;
  v_opmx := pg_temp.uc_op(v_acc, v_conv, 26000, 'mexico', 'mexico');
  PERFORM pg_temp.uc_done(v_opmx, v_agent);
  SELECT * INTO v_emx FROM remittance_calculator_entries WHERE operation_id = v_opmx;
  v_fail := v_fail + pg_temp.uc_chk('12.a Mexico operation (priced as CLASICA) takes nothing from the USD cards and keeps today''s cost',
    v_emx.service = 'CLASICA' AND v_emx.invertido_gyd = 100 * 238
    AND (SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE account_id = v_acc) = v_n, format('service=%s invertido=%s', v_emx.service, v_emx.invertido_gyd));
  v_opmx := pg_temp.uc_op(v_acc, v_conv, 2600000, NULL, 'mexico');
  v_res := pg_temp.uc_try(format('SELECT crm_cerrar_operacion_manual(%L)', v_opmx), v_admin);
  v_fail := v_fail + pg_temp.uc_chk('12.a Mexico operation is never blocked by the USD balance', v_res = 'OK', v_res);

  -- ---- case 13: panel plan RPC ----------------------------------------------------------------------------------------------------------------------
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_op1);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('13.completed: consumed 100, the line shows card, lot and lot rate, cost = the entry invertido',
    v_plan ->> 'state' = 'completed' AND (v_plan ->> 'consumed_usd')::numeric = 100 AND jsonb_array_length(v_plan -> 'lines') = 1
    AND (v_plan -> 'lines' -> 0 ->> 'card_name') = 'Clasica A' AND (v_plan -> 'lines' -> 0 ->> 'lot_id') = v_l1.id::text
    AND pg_temp.uc_near((v_plan -> 'lines' -> 0 ->> 'usd_per_usdt')::numeric, v_r1) AND pg_temp.uc_near((v_plan ->> 'cost_gyd')::numeric, v_e1.invertido_gyd)
    AND pg_temp.uc_near((v_plan ->> 'invested_usdt')::numeric, 100 / v_r1), v_plan::text);
  v_opp2 := pg_temp.uc_op(v_acc, v_conv, 78000, 'clasica');   -- 300 USD, 180 left on card B
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_opp2);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('13.plan over the balance: blocked, planned 180, missing 120, both active cards listed',
    v_plan ->> 'state' = 'plan' AND (v_plan ->> 'blocked')::boolean AND jsonb_array_length(v_plan -> 'services') = 1
    AND (v_plan -> 'services' -> 0 ->> 'planned_usd')::numeric = 180 AND (v_plan -> 'services' -> 0 ->> 'missing_usd')::numeric = 120
    AND jsonb_array_length(v_plan -> 'services' -> 0 -> 'cards') = 2, v_plan::text);
  v_opp := pg_temp.uc_op(v_acc, v_conv, 13000, 'clasica');   -- 50 USD
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_opp);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('13.plan that fits: not blocked, one line of 50 from card B, nothing consumed by planning',
    v_plan ->> 'state' = 'plan' AND NOT (v_plan ->> 'blocked')::boolean AND (v_plan -> 'services' -> 0 ->> 'missing_usd')::numeric = 0
    AND (v_plan -> 'services' -> 0 -> 'lines' -> 0 ->> 'amount_usd')::numeric = 50 AND pg_temp.uc_balance(v_cb.id) = 180, v_plan::text);
  v_opc := pg_temp.uc_op(v_acc, v_conv, 20000, 'cuban_card');
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_opc);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('13.a CUP operation is not_usd', v_plan ->> 'state' = 'not_usd', v_plan::text);
  v_opcan := pg_temp.uc_op(v_acc, v_conv, 13000, 'clasica');
  UPDATE remittance_operations SET status = 'cancelled' WHERE id = v_opcan;
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_opcan);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('13.a cancelled operation is unavailable', v_plan ->> 'state' = 'unavailable', v_plan::text);
  v_opna := pg_temp.uc_op(v_acc, v_conv, NULL, 'clasica');
  PERFORM pg_temp.uc_claims(v_agent);
  v_plan := crm_inventario_usd_operacion(v_opna);
  PERFORM pg_temp.uc_claims(NULL);
  v_fail := v_fail + pg_temp.uc_chk('13.a Clasica operation without amount is no_amounts', v_plan ->> 'state' = 'no_amounts', v_plan::text);
  v_fail := v_fail + pg_temp.uc_chk('13.a stranger is refused (42501)', pg_temp.uc_try(format('SELECT crm_inventario_usd_operacion(%L)', v_opp), v_stranger) LIKE '42501|%');
  v_fail := v_fail + pg_temp.uc_chk('13.an unknown operation is P0002', pg_temp.uc_try(format('SELECT crm_inventario_usd_operacion(%L)', gen_random_uuid()), v_agent) LIKE 'P0002|%');

  -- ---- case 14: grants ----------------------------------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.uc_chk('14.internal functions are not executable by authenticated / anon',
    NOT has_function_privilege('authenticated', 'public.usd_planificar(uuid, text, numeric, timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.usd_planificar(uuid, text, numeric, timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.usd_consumir(uuid, text, numeric, uuid, uuid, timestamptz, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.usd_consumir(uuid, text, numeric, uuid, uuid, timestamptz, text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.usd_devolver(uuid, uuid, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.usd_devolver(uuid, uuid, text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.usd_alertar(uuid, uuid, text, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.usd_alertar(uuid, uuid, text, text)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.usd_faltante(uuid, text, numeric, timestamptz)', 'EXECUTE'));
  v_fail := v_fail + pg_temp.uc_chk('14.the panel RPC is executable by authenticated, not by anon',
    has_function_privilege('authenticated', 'public.crm_inventario_usd_operacion(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_inventario_usd_operacion(uuid)', 'EXECUTE'));

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'usd-inventory-consumption: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
