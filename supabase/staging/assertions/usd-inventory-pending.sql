\set ON_ERROR_STOP on
-- usd-inventory-pending.sql -- self-reverting assertion for 357_usd_inventory_pending.sql
--
-- odd/tasks/usd-card-inventory.md (T2b). An admin resolving a pending Clasica / Tropical chat line (crm_resolve_pending_entry) takes its USD
-- from the cards like the feed does. Account 1: Clasica card (lot 200 USD for 160 USDT = 1.25), Tropical card (lot 50 USD @ 1), rates of the
-- payload usdt_buy_gyd 238 / usdt_sell_gyd 260. Account 2 has no USD card.
--   case 1  pending Clasica of 26,000 GYD: nothing consumed while pending; resolved -> amount 100 USD, 100 consumed from the lot linked to the
--           entry and the operation, invertido = 100 / 1.25 * 238, retorno = facturado - invertido
--   case 2  a second resolve is refused and takes nothing more; deleting the resolved entry gives the USD back
--   case 3  pending Tropical of 78,000 GYD = 300 USD against 50: consumes 50, invertido = (50 / 1 + 250) * 238, an 'inventario_cup' alert names
--           the customer and the 250 missing; the resolve itself never blocks
--   case 4  a rate the entry already recorded wins (usdt_buy_gyd 240 on the entry): invertido uses 240 with the lot cost
--   case 5  account 2 (no card): resolved at today's cost 100 * 238, nothing consumed, nobody alerted
--   case 6  a Mexico operation's pending line never consumes
--   case 7  an inventory failure never aborts the resolve (poisoned lot constraint): resolved at today's cost, error alert, nothing left behind
--
-- Run it as: BEGIN; \i 355; \i 356; \i 357; \i this file; ROLLBACK;  (STAGING only). Ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'.

CREATE FUNCTION pg_temp.up_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.up_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

CREATE FUNCTION pg_temp.up_near(a numeric, b numeric) RETURNS boolean LANGUAGE sql IMMUTABLE AS $f$
  SELECT a IS NOT NULL AND b IS NOT NULL AND abs(a - b) < 0.000000001;
$f$;

CREATE FUNCTION pg_temp.up_try(p_sql text, p_uid uuid) RETURNS text LANGUAGE plpgsql AS $f$
DECLARE v_prev text := coalesce(current_setting('request.jwt.claims', true), '');
BEGIN
  PERFORM pg_temp.up_claims(p_uid);
  BEGIN
    EXECUTE p_sql;
    PERFORM set_config('request.jwt.claims', v_prev, true);
    RETURN 'OK';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', v_prev, true);
    RETURN SQLSTATE || '|' || SQLERRM;
  END;
END $f$;

-- an operation plus its pending line (service, basis in GYD)
CREATE FUNCTION pg_temp.up_pending(p_acct uuid, p_conv uuid, p_service text, p_gyd numeric, p_op_service text DEFAULT 'remesa', p_buy numeric DEFAULT NULL, OUT o_op uuid, OUT o_entry uuid) LANGUAGE plpgsql AS $f$
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acct, p_conv, 'completed', p_op_service, 'GYD', p_gyd, lower(p_service)) RETURNING id INTO o_op;
  INSERT INTO remittance_calculator_entries (account_id, source, status, operation_id, entry_date, customer_name, service, amount, amount_currency,
    basis_gyd, usdt_buy_gyd, missing_inputs, completed_at)
  VALUES (p_acct, 'completed_operation', 'verified_pending', o_op, current_date, 'Pend UP', p_service, p_gyd, 'USD', p_gyd, p_buy,
    ARRAY['usdtBuyGyd', 'usdtSellGyd'], now()) RETURNING id INTO o_entry;
END $f$;

CREATE FUNCTION pg_temp.up_balance(p_card uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT coalesce(sum(remaining_usd), 0) FROM usd_lots WHERE card_id = p_card;
$f$;

CREATE FUNCTION pg_temp.up_taken(p_entry uuid) RETURNS numeric LANGUAGE sql AS $f$
  SELECT coalesce(sum(amount_usd), 0) FROM usd_lot_consumptions WHERE calculator_entry_id = p_entry;
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_contact uuid; v_conv uuid; v_contact2 uuid; v_conv2 uuid;
  v_ca usd_cards; v_ct usd_cards; v_l1 usd_lots; v_t1 usd_lots;
  v_rates CONSTANT jsonb := '{"usdt_buy_gyd": 238, "usdt_sell_gyd": 260}'::jsonb;
  v_p record; v_e remittance_calculator_entries; v_res text; v_notif integer;
  v_fail integer := 0;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'up-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_owner2, v_admin2]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'usd pending test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'usd pending account without cards', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'up owner', 'up-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'up admin', 'up-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_owner2, 'up owner2', 'up-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'up admin2', 'up-' || v_admin2 || '@test.invalid', v_acc2, 'admin');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '15550003570', v_acc, 'Cliente UP') RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_contact, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner2, '15550003571', v_acc2, 'Cliente UP2') RETURNING id INTO v_contact2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner2, v_contact2, v_acc2) RETURNING id INTO v_conv2;

  PERFORM pg_temp.up_claims(v_admin);
  v_ca := crm_guardar_tarjeta_usd(v_acc, NULL, 'CLASICA', 'Clasica A', '1111', 1, NULL, NULL);
  v_ct := crm_guardar_tarjeta_usd(v_acc, NULL, 'TROPICAL', 'Tropical A', '3333', 1, NULL, NULL);
  v_l1 := crm_cargar_lote_usd(v_acc, v_ca.id, 200, 160, now() - interval '2 days', 'L1');
  v_t1 := crm_cargar_lote_usd(v_acc, v_ct.id, 50, 50, now() - interval '2 days', 'T1');
  PERFORM pg_temp.up_claims(NULL);

  -- ---- case 1 ---------------------------------------------------------------------------------------------------------------------------
  SELECT * INTO v_p FROM pg_temp.up_pending(v_acc, v_conv, 'CLASICA', 26000);
  v_fail := v_fail + pg_temp.up_chk('1.a pending line consumes nothing', pg_temp.up_taken(v_p.o_entry) = 0 AND pg_temp.up_balance(v_ca.id) = 200);
  v_res := pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''resolve with rates'')', v_p.o_entry, v_rates), v_admin);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_p.o_entry;
  v_fail := v_fail + pg_temp.up_chk('1.resolved: completed, 100 USD', v_res = 'OK' AND v_e.status = 'completed' AND v_e.amount = 100, v_res || ' amount=' || coalesce(v_e.amount::text, 'null'));
  v_fail := v_fail + pg_temp.up_chk('1.100 USD taken from the lot, linked to the entry and the operation',
    pg_temp.up_taken(v_e.id) = 100 AND pg_temp.up_balance(v_ca.id) = 100
    AND (SELECT count(*) = 1 AND min(kind) = 'operacion' AND min(operation_id::text) = v_p.o_op::text FROM usd_lot_consumptions WHERE calculator_entry_id = v_e.id));
  v_fail := v_fail + pg_temp.up_chk('1.invertido = 100 / 1.25 * 238, retorno = facturado - invertido',
    pg_temp.up_near(v_e.invertido_gyd, 100 / 1.25 * 238) AND pg_temp.up_near(v_e.retorno_gyd, v_e.facturado_gyd - v_e.invertido_gyd), format('invertido=%s', v_e.invertido_gyd));

  -- ---- case 2 ---------------------------------------------------------------------------------------------------------------------------
  v_res := pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''second resolve'')', v_p.o_entry, v_rates), v_admin);
  v_fail := v_fail + pg_temp.up_chk('2.a second resolve is refused and takes nothing more', v_res LIKE '22023|%' AND pg_temp.up_taken(v_p.o_entry) = 100 AND pg_temp.up_balance(v_ca.id) = 100, v_res);
  PERFORM pg_temp.up_claims(v_admin);
  PERFORM crm_eliminar_entrada_calculadora(v_p.o_entry);
  PERFORM pg_temp.up_claims(NULL);
  v_fail := v_fail + pg_temp.up_chk('2.deleting the resolved entry gives the USD back', pg_temp.up_balance(v_ca.id) = 200 AND pg_temp.up_taken(v_p.o_entry) = 0);

  -- ---- case 3 ---------------------------------------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_notif FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup';
  SELECT * INTO v_p FROM pg_temp.up_pending(v_acc, v_conv, 'TROPICAL', 78000);
  v_res := pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''resolve with rates'')', v_p.o_entry, v_rates), v_admin);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_p.o_entry;
  v_fail := v_fail + pg_temp.up_chk('3.a resolve over the balance still resolves: 300 USD, 50 consumed',
    v_res = 'OK' AND v_e.status = 'completed' AND v_e.amount = 300 AND pg_temp.up_taken(v_e.id) = 50 AND pg_temp.up_balance(v_ct.id) = 0, v_res);
  v_fail := v_fail + pg_temp.up_chk('3.invertido = (50 / 1 + 250) * 238', pg_temp.up_near(v_e.invertido_gyd, 300 * 238), format('invertido=%s', v_e.invertido_gyd));
  v_fail := v_fail + pg_temp.up_chk('3.alert names the customer and the 250 missing',
    (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_notif
    AND EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup' AND body LIKE '%Pend UP%' AND body LIKE '%250%'));

  -- ---- case 4: the recorded buy rate wins ---------------------------------------------------------------------------------------------------
  SELECT * INTO v_p FROM pg_temp.up_pending(v_acc, v_conv, 'CLASICA', 26000, 'remesa', 240);
  PERFORM pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''resolve with rates'')', v_p.o_entry, v_rates), v_admin);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_p.o_entry;
  v_fail := v_fail + pg_temp.up_chk('4.the entry''s own buy rate (240) wins: invertido = 100 / 1.25 * 240', pg_temp.up_near(v_e.invertido_gyd, 100 / 1.25 * 240) AND v_e.usdt_buy_gyd = 240, format('invertido=%s', v_e.invertido_gyd));

  -- ---- case 5: no card -> today's cost --------------------------------------------------------------------------------------------------------
  SELECT * INTO v_p FROM pg_temp.up_pending(v_acc2, v_conv2, 'CLASICA', 26000);
  v_res := pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''resolve with rates'')', v_p.o_entry, v_rates), v_admin2);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_p.o_entry;
  v_fail := v_fail + pg_temp.up_chk('5.no card: invertido = 100 * 238, nothing consumed, nobody alerted',
    v_res = 'OK' AND v_e.invertido_gyd = 100 * 238 AND NOT EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE account_id = v_acc2)
    AND NOT EXISTS (SELECT 1 FROM notifications WHERE account_id = v_acc2 AND type = 'inventario_cup'), v_res);

  -- ---- case 6: Mexico ---------------------------------------------------------------------------------------------------------------------------
  SELECT * INTO v_p FROM pg_temp.up_pending(v_acc, v_conv, 'CLASICA', 26000, 'mexico');
  PERFORM pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''resolve with rates'')', v_p.o_entry, v_rates), v_admin);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_p.o_entry;
  v_fail := v_fail + pg_temp.up_chk('6.a Mexico line never consumes: today''s cost', v_e.status = 'completed' AND pg_temp.up_taken(v_e.id) = 0 AND v_e.invertido_gyd = 100 * 238);

  -- ---- case 7: failure never aborts the resolve ---------------------------------------------------------------------------------------------------
  SELECT count(*) INTO v_notif FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup';
  SELECT * INTO v_p FROM pg_temp.up_pending(v_acc, v_conv, 'CLASICA', 5200);
  ALTER TABLE usd_lots ADD CONSTRAINT usd_lots_poison_chk CHECK (remaining_usd = amount_usd) NOT VALID;
  v_res := pg_temp.up_try(format('SELECT crm_resolve_pending_entry(%L, %L::jsonb, ''resolve with rates'')', v_p.o_entry, v_rates), v_admin);
  ALTER TABLE usd_lots DROP CONSTRAINT usd_lots_poison_chk;
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_p.o_entry;
  v_fail := v_fail + pg_temp.up_chk('7.poisoned inventory: resolved at today''s cost (20 * 238), nothing left behind, error alert',
    v_res = 'OK' AND v_e.status = 'completed' AND v_e.invertido_gyd = 20 * 238 AND pg_temp.up_taken(v_e.id) = 0
    AND (SELECT count(*) FROM notifications WHERE account_id = v_acc AND type = 'inventario_cup') > v_notif, v_res || ' invertido=' || coalesce(v_e.invertido_gyd::text, 'null'));

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'usd-inventory-pending: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
