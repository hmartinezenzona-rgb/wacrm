\set ON_ERROR_STOP on
-- Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- cup-inventory-panel.sql -- self-reverting assertion for 241_cup_inventory_panel.sql
--
-- STATUS: written without a SQL engine (psql unavailable where it was authored) -- pending staging run (T12). Never run against production.
--
-- Proves the delivery-panel plan (phase 3) and that the shared allocator did not change cup_consumir. Fixture account 1: cards A (priority 1)
-- and B (priority 2), limit 120,000 each, lot A 500,000 CUP @960, lot B 250,000 CUP @1060; rates cup_global_rate 2 (a 50,000 GYD operation
-- is 100,000 CUP). Account 2: no card at first.
--   case 1  plan writes nothing and is segmented per beneficiary: X 100,000 + Y 50,000 -> A has 120,000 of room, so X = [A 100,000] and Y
--           straddles = [A 20,000, B 30,000] (two lines); total / planned / missing; estimate = true; lots and consumptions untouched.
--   case 2  plan equals what cup_consumir then takes: cup_consumir for the same 150,000 consumes exactly the planned (lot, amount) pairs.
--   case 3  the panel reads again after A is at its limit: a 40,000 operation plans B 40,000 @1060; completing it (real feed path) consumes
--           exactly that, and the completed read returns the consumption (card name, last4, lot rate, amount), cup_rate 1060, estimate false.
--   case 4  shortfall: 200,000 with only 50,000 of room on B and A at its limit -> planned 50,000, missing 150,000, the last beneficiary(ies)
--           carry missing_cup.
--   case 5  states: a Zelle-only operation -> not_cup; an account without active card -> no_inventory; CUP beneficiaries without an amount ->
--           no_amounts; a cancelled operation -> unavailable.
--   case 6  refusals: another account's admin, a viewer of the same account, an unauthenticated caller -> 42501; unknown operation -> P0002;
--           an agent of the account is allowed.
--   case 7  FIFO inside a card and equivalence on account 2: lots 30,000 @900 (older) and 30,000 @1000; the plan for 40,000 is
--           [30,000 @900, 10,000 @1000] and cup_consumir's parts are the same list; a card with priority 0 / inactive is never planned.
--   case 8  grants: cup_planificar is executable by neither authenticated nor anon; the RPC by authenticated but not anon.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (BEGIN ... \i 239 ... \i 240 ... \i 241 ... \i this file ... ROLLBACK),
-- on STAGING only. Never COMMIT. Never run against production. Builds its own fixtures. The 240 assertion must also still pass after 241.

SAVEPOINT cup_inventory_panel;

CREATE FUNCTION pg_temp.cip_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.cip_op(p_acct uuid, p_conv uuid, p_gyd numeric, p_status text DEFAULT 'ready_to_transfer') RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acct, p_conv, p_status, 'remesa', 'GYD', p_gyd, 'cuban_card') RETURNING id INTO v;
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.cip_ben(p_op uuid, p_pos integer, p_name text, p_amount numeric, p_type text DEFAULT 'cuban_card') RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, amount, currency, position, block_index)
  VALUES (p_op, p_type, p_name, p_amount, CASE WHEN p_amount IS NULL THEN NULL WHEN p_type = 'zelle' THEN 'USD' ELSE 'CUP' END, p_pos, p_pos)
  RETURNING id INTO v;
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.cip_done(p_op uuid, p_actor uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.cip_claims(p_actor);
  UPDATE remittance_operations SET status = 'completed', completed_at = now(), delivery_mode = 'proof_sent', delivered_by = p_actor WHERE id = p_op;
  PERFORM pg_temp.cip_claims(NULL);
END $f$;

CREATE FUNCTION pg_temp.cip_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

CREATE FUNCTION pg_temp.cip_expect_state(p_sql text, p_state text, p_uid uuid) RETURNS boolean LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.cip_claims(p_uid);
  BEGIN
    EXECUTE p_sql;
    PERFORM pg_temp.cip_claims(NULL);
    RETURN false;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.cip_claims(NULL);
    RETURN SQLSTATE = p_state;
  END;
END $f$;

-- The panel read as a given user.
CREATE FUNCTION pg_temp.cip_panel(p_op uuid, p_uid uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.cip_claims(p_uid);
  v := crm_inventario_cup_operacion(p_op);
  PERFORM pg_temp.cip_claims(NULL);
  RETURN v;
END $f$;

CREATE FUNCTION pg_temp.cip_counts() RETURNS text LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM cup_lot_consumptions)::text || '/' || (SELECT coalesce(sum(remaining_cup), 0) FROM cup_lots)::text;
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid(); v_viewer uuid := gen_random_uuid();
  v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_contact uuid; v_conv uuid; v_contact2 uuid; v_conv2 uuid;
  v_a cup_cards; v_b cup_cards; v_c cup_cards; v_d cup_cards;
  v_la cup_lots; v_lb cup_lots; v_l1 cup_lots; v_l2 cup_lots; v_ld cup_lots;
  v_op1 uuid; v_op3 uuid; v_op4 uuid; v_opz uuid; v_opn uuid; v_opx uuid; v_op7 uuid; v_op2a uuid;
  v_bx uuid; v_by uuid;
  v_today date; v_before text; v_plan jsonb; v_done jsonb; v_cons record; v_ok boolean;
  v_fail integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cip-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_viewer, v_owner2, v_admin2]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup panel test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup panel other account', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'cip owner', 'cip-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'cip admin', 'cip-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'cip agent', 'cip-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_viewer, 'cip viewer', 'cip-' || v_viewer || '@test.invalid', v_acc, 'viewer'),
    (gen_random_uuid(), v_owner2, 'cip owner2', 'cip-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'cip admin2', 'cip-' || v_admin2 || '@test.invalid', v_acc2, 'admin');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '15550000250', v_acc, 'Cliente CIP') RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_contact, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner2, '15550000251', v_acc2, 'Cliente CIP2') RETURNING id INTO v_contact2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner2, v_contact2, v_acc2) RETURNING id INTO v_conv2;

  PERFORM pg_temp.cip_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  v_a := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta A', '1111', 1, 120000, NULL);
  v_b := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta B', '2222', 2, 120000, NULL);
  v_la := crm_cargar_lote_cup(v_acc, v_a.id, 500000, 960, 'lote A', NULL);
  v_lb := crm_cargar_lote_cup(v_acc, v_b.id, 250000, 1060, 'lote B', NULL);
  PERFORM pg_temp.cip_claims(v_admin2);
  PERFORM crm_set_calculator_rates(v_acc2, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  PERFORM pg_temp.cip_claims(NULL);
  v_today := cup_cuba_day(now());

  -- ---- case 1: the plan, per beneficiary, writes nothing ----------------------------------------------------------------------------------
  v_op1 := pg_temp.cip_op(v_acc, v_conv, 75000);
  v_bx := pg_temp.cip_ben(v_op1, 1, 'Beneficiario X', 100000);
  v_by := pg_temp.cip_ben(v_op1, 2, 'Beneficiario Y', 50000);
  v_before := pg_temp.cip_counts();
  v_plan := pg_temp.cip_panel(v_op1, v_agent);
  v_fail := v_fail + pg_temp.cip_chk('1.state plan, estimate, totals', v_plan->>'state' = 'plan' AND (v_plan->>'estimate')::boolean
    AND (v_plan->>'total_cup')::numeric = 150000 AND (v_plan->>'planned_cup')::numeric = 150000 AND (v_plan->>'missing_cup')::numeric = 0
    AND (v_plan->>'cuba_day')::date = v_today, v_plan::text);
  v_fail := v_fail + pg_temp.cip_chk('1.X is one line: A 100,000',
    jsonb_array_length(v_plan->'beneficiaries'->0->'lines') = 1
    AND v_plan->'beneficiaries'->0->>'beneficiary_id' = v_bx::text
    AND v_plan->'beneficiaries'->0->'lines'->0->>'card_name' = 'Tarjeta A' AND v_plan->'beneficiaries'->0->'lines'->0->>'last4' = '1111'
    AND (v_plan->'beneficiaries'->0->'lines'->0->>'amount_cup')::numeric = 100000
    AND (v_plan->'beneficiaries'->0->'lines'->0->>'lot_rate')::numeric = 960, v_plan::text);
  v_fail := v_fail + pg_temp.cip_chk('1.Y straddles: A 20,000 then B 30,000 (two lines), no missing',
    v_plan->'beneficiaries'->1->>'beneficiary_id' = v_by::text AND jsonb_array_length(v_plan->'beneficiaries'->1->'lines') = 2
    AND v_plan->'beneficiaries'->1->'lines'->0->>'card_name' = 'Tarjeta A' AND (v_plan->'beneficiaries'->1->'lines'->0->>'amount_cup')::numeric = 20000
    AND v_plan->'beneficiaries'->1->'lines'->1->>'card_name' = 'Tarjeta B' AND (v_plan->'beneficiaries'->1->'lines'->1->>'amount_cup')::numeric = 30000
    AND (v_plan->'beneficiaries'->1->>'missing_cup')::numeric = 0, v_plan::text);
  v_fail := v_fail + pg_temp.cip_chk('1.effective rate = 150000 / (120000/960 + 30000/1060)',
    abs((v_plan->>'effective_rate')::numeric - 150000 / (120000::numeric / 960 + 30000::numeric / 1060)) < 0.000000001, v_plan->>'effective_rate');
  v_fail := v_fail + pg_temp.cip_chk('1.the plan wrote nothing (consumptions / remaining unchanged)', pg_temp.cip_counts() = v_before, format('%s vs %s', pg_temp.cip_counts(), v_before));
  v_fail := v_fail + pg_temp.cip_chk('1.card numbers never leak (names + last4 only)', v_plan::text NOT LIKE '%card_number%');

  -- ---- case 2: cup_consumir takes exactly what was planned ----------------------------------------------------------------------------------
  PERFORM cup_consumir(v_acc, 150000, NULL, v_op1, now(), v_today);
  v_ok := NOT EXISTS (
    (SELECT (l->>'lot_id')::uuid, sum((l->>'amount_cup')::numeric) FROM jsonb_array_elements(v_plan->'beneficiaries') b, jsonb_array_elements(b->'lines') l GROUP BY 1)
    EXCEPT
    (SELECT lot_id, sum(amount_cup) FROM cup_lot_consumptions WHERE operation_id = v_op1 GROUP BY 1))
   AND NOT EXISTS (
    (SELECT lot_id, sum(amount_cup) FROM cup_lot_consumptions WHERE operation_id = v_op1 GROUP BY 1)
    EXCEPT
    (SELECT (l->>'lot_id')::uuid, sum((l->>'amount_cup')::numeric) FROM jsonb_array_elements(v_plan->'beneficiaries') b, jsonb_array_elements(b->'lines') l GROUP BY 1));
  v_fail := v_fail + pg_temp.cip_chk('2.consumed (lot, amount) pairs equal the plan', v_ok);
  v_fail := v_fail + pg_temp.cip_chk('2.A at its limit today, B used 30,000',
    (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE card_id = v_a.id AND cuba_day = v_today) = 120000
    AND (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE card_id = v_b.id AND cuba_day = v_today) = 30000);

  -- ---- case 3: next operation plans B; completing it consumes the plan; the completed read shows it --------------------------------------
  v_op3 := pg_temp.cip_op(v_acc, v_conv, 20000);
  PERFORM pg_temp.cip_ben(v_op3, 1, 'Beneficiario Z', 40000);
  v_plan := pg_temp.cip_panel(v_op3, v_agent);
  v_fail := v_fail + pg_temp.cip_chk('3.plan is B 40,000 @1060',
    v_plan->>'state' = 'plan' AND jsonb_array_length(v_plan->'beneficiaries'->0->'lines') = 1
    AND v_plan->'beneficiaries'->0->'lines'->0->>'card_name' = 'Tarjeta B' AND (v_plan->'beneficiaries'->0->'lines'->0->>'amount_cup')::numeric = 40000
    AND (v_plan->'beneficiaries'->0->'lines'->0->>'lot_rate')::numeric = 1060, v_plan::text);
  PERFORM pg_temp.cip_done(v_op3, v_agent);
  v_done := pg_temp.cip_panel(v_op3, v_agent);
  v_fail := v_fail + pg_temp.cip_chk('3.completed read: consumption B 40,000 @1060, cup_rate 1060, estimate false',
    v_done->>'state' = 'completed' AND NOT (v_done->>'estimate')::boolean AND jsonb_array_length(v_done->'lines') = 1
    AND v_done->'lines'->0->>'card_name' = 'Tarjeta B' AND v_done->'lines'->0->>'last4' = '2222'
    AND (v_done->'lines'->0->>'amount_cup')::numeric = 40000 AND (v_done->'lines'->0->>'lot_rate')::numeric = 1060
    AND (v_done->>'consumed_cup')::numeric = 40000 AND abs((v_done->>'cup_rate')::numeric - 1060) < 0.000000001, v_done::text);
  v_fail := v_fail + pg_temp.cip_chk('3.what the plan said is what the completion took',
    (v_plan->'beneficiaries'->0->'lines'->0->>'lot_id') = (v_done->'lines'->0->>'lot_id'));

  -- ---- case 4: shortfall -----------------------------------------------------------------------------------------------------------------------
  -- B has used 70,000 today -> 50,000 of room; A is at its limit.
  v_op4 := pg_temp.cip_op(v_acc, v_conv, 100000);
  PERFORM pg_temp.cip_ben(v_op4, 1, 'Beneficiario P', 120000);
  PERFORM pg_temp.cip_ben(v_op4, 2, 'Beneficiario Q', 80000);
  v_before := pg_temp.cip_counts();
  v_plan := pg_temp.cip_panel(v_op4, v_admin);
  v_fail := v_fail + pg_temp.cip_chk('4.planned 50,000 of 200,000, missing 150,000',
    (v_plan->>'total_cup')::numeric = 200000 AND (v_plan->>'planned_cup')::numeric = 50000 AND (v_plan->>'missing_cup')::numeric = 150000, v_plan::text);
  v_fail := v_fail + pg_temp.cip_chk('4.P gets the 50,000 and misses 70,000; Q has no line and misses 80,000',
    (v_plan->'beneficiaries'->0->>'missing_cup')::numeric = 70000 AND (v_plan->'beneficiaries'->0->'lines'->0->>'amount_cup')::numeric = 50000
    AND (v_plan->'beneficiaries'->1->>'missing_cup')::numeric = 80000 AND jsonb_array_length(v_plan->'beneficiaries'->1->'lines') = 0, v_plan::text);
  v_fail := v_fail + pg_temp.cip_chk('4.nothing written', pg_temp.cip_counts() = v_before);

  -- ---- case 5: states ----------------------------------------------------------------------------------------------------------------------------
  v_opz := pg_temp.cip_op(v_acc, v_conv, 1000);
  PERFORM pg_temp.cip_ben(v_opz, 1, 'Zelle', 50, 'zelle');
  v_fail := v_fail + pg_temp.cip_chk('5.zelle-only operation -> not_cup', pg_temp.cip_panel(v_opz, v_agent)->>'state' = 'not_cup');
  v_opn := pg_temp.cip_op(v_acc, v_conv, 1000);
  -- Two CUP beneficiaries without an amount: a LONE one takes the operation's quoted CUP by design (the trigger quotes this fixture at 2000), so
  -- 'no amounts' needs at least two.
  PERFORM pg_temp.cip_ben(v_opn, 1, 'Sin monto', NULL);
  PERFORM pg_temp.cip_ben(v_opn, 2, 'Sin monto 2', NULL);
  v_fail := v_fail + pg_temp.cip_chk('5.CUP beneficiary without amount -> no_amounts', pg_temp.cip_panel(v_opn, v_agent)->>'state' = 'no_amounts');
  v_opx := pg_temp.cip_op(v_acc, v_conv, 1000, 'cancelled');
  PERFORM pg_temp.cip_ben(v_opx, 1, 'Cancelada', 2000);
  v_fail := v_fail + pg_temp.cip_chk('5.cancelled -> unavailable', pg_temp.cip_panel(v_opx, v_agent)->>'state' = 'unavailable');
  v_op2a := pg_temp.cip_op(v_acc2, v_conv2, 1000);
  PERFORM pg_temp.cip_ben(v_op2a, 1, 'Cuenta 2', 2000);
  v_fail := v_fail + pg_temp.cip_chk('5.account without an active card -> no_inventory', pg_temp.cip_panel(v_op2a, v_admin2)->>'state' = 'no_inventory');

  -- ---- case 6: refusals --------------------------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cip_chk('6.another account''s admin is refused',
    pg_temp.cip_expect_state(format('SELECT crm_inventario_cup_operacion(%L)', v_op1), '42501', v_admin2));
  v_fail := v_fail + pg_temp.cip_chk('6.a viewer of the account is refused',
    pg_temp.cip_expect_state(format('SELECT crm_inventario_cup_operacion(%L)', v_op1), '42501', v_viewer));
  v_fail := v_fail + pg_temp.cip_chk('6.unauthenticated is refused',
    pg_temp.cip_expect_state(format('SELECT crm_inventario_cup_operacion(%L)', v_op1), '42501', NULL));
  v_fail := v_fail + pg_temp.cip_chk('6.unknown operation -> P0002',
    pg_temp.cip_expect_state(format('SELECT crm_inventario_cup_operacion(%L)', gen_random_uuid()), 'P0002', v_agent));
  v_fail := v_fail + pg_temp.cip_chk('6.an agent of the account reads the plan', pg_temp.cip_panel(v_op4, v_agent)->>'state' = 'plan');

  -- ---- case 7: FIFO inside a card; plan and cup_consumir agree on account 2 ------------------------------------------------------------------------
  PERFORM pg_temp.cip_claims(v_admin2);
  v_c := crm_guardar_tarjeta_cup(v_acc2, NULL, 'Tarjeta C', NULL, 1, 120000, NULL);
  v_l1 := crm_cargar_lote_cup(v_acc2, v_c.id, 30000, 900, 'primero', now() - interval '2 days');
  v_l2 := crm_cargar_lote_cup(v_acc2, v_c.id, 30000, 1000, 'segundo', now() - interval '1 day');
  v_d := crm_guardar_tarjeta_cup(v_acc2, NULL, 'Tarjeta D', NULL, 0, 120000, NULL);
  v_ld := crm_cargar_lote_cup(v_acc2, v_d.id, 50000, 800, 'lote D', NULL);
  v_d := crm_guardar_tarjeta_cup(v_acc2, v_d.id, NULL, NULL, NULL, NULL, false);
  PERFORM pg_temp.cip_claims(NULL);
  v_op7 := pg_temp.cip_op(v_acc2, v_conv2, 20000);
  PERFORM pg_temp.cip_ben(v_op7, 1, 'FIFO', 40000);
  v_plan := pg_temp.cip_panel(v_op7, v_admin2);
  v_fail := v_fail + pg_temp.cip_chk('7.plan: 30,000 @900 then 10,000 @1000, inactive D never planned',
    jsonb_array_length(v_plan->'beneficiaries'->0->'lines') = 2
    AND (v_plan->'beneficiaries'->0->'lines'->0->>'amount_cup')::numeric = 30000 AND (v_plan->'beneficiaries'->0->'lines'->0->>'lot_rate')::numeric = 900
    AND (v_plan->'beneficiaries'->0->'lines'->1->>'amount_cup')::numeric = 10000 AND (v_plan->'beneficiaries'->0->'lines'->1->>'lot_rate')::numeric = 1000
    AND v_plan::text NOT LIKE '%Tarjeta D%', v_plan::text);
  SELECT * INTO v_cons FROM cup_consumir(v_acc2, 40000, NULL, v_op7, now(), v_today);
  v_fail := v_fail + pg_temp.cip_chk('7.cup_consumir parts are the same list and rate is exact',
    v_cons.consumed_cup = 40000 AND v_cons.missing_cup = 0 AND jsonb_array_length(v_cons.parts) = 2
    AND (v_cons.parts->0->>'lot_id')::uuid = v_l1.id AND (v_cons.parts->0->>'amount_cup')::numeric = 30000
    AND (v_cons.parts->1->>'lot_id')::uuid = v_l2.id AND (v_cons.parts->1->>'amount_cup')::numeric = 10000
    AND abs(v_cons.effective_rate - 40000 / (30000::numeric / 900 + 10000::numeric / 1000)) < 0.000000001, v_cons::text);
  v_fail := v_fail + pg_temp.cip_chk('7.an idempotent second cup_consumir takes nothing more',
    (SELECT consumed_cup FROM cup_consumir(v_acc2, 40000, NULL, v_op7, now(), v_today)) = 40000
    AND (SELECT coalesce(sum(amount_cup), 0) FROM cup_lot_consumptions WHERE operation_id = v_op7) = 40000);

  -- ---- case 8: grants ---------------------------------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cip_chk('8.cup_planificar is internal; the RPC is authenticated-only',
    NOT has_function_privilege('authenticated', 'public.cup_planificar(uuid, numeric, date)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cup_planificar(uuid, numeric, date)', 'EXECUTE')
    -- (257 widened the RPC to an optional second argument: look the function up by name so the check holds before and after)
    AND (SELECT bool_and(has_function_privilege('authenticated', p.oid, 'EXECUTE') AND NOT has_function_privilege('anon', p.oid, 'EXECUTE'))
           FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'crm_inventario_cup_operacion')
    AND NOT has_function_privilege('authenticated', 'public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date)', 'EXECUTE'));

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'cup-inventory-panel: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE NOTICE 'cup-inventory-panel: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT cup_inventory_panel;
