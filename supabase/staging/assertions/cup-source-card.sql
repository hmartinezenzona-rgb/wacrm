\set ON_ERROR_STOP on
-- cup-source-card.sql -- self-reverting assertion for 257_cup_source_card.sql
--
-- Proves the optional "source card" choice when a CUP operation is completed (odd/tasks/cup-balance-adjust-and-source-card.md, B3):
-- remittance_operations.cup_source_card_id is set by crm_entregar_operacion / crm_cerrar_operacion_manual in the same statement that
-- completes the operation, the calculator feed hands it to the allocator, and the allocator starts there and continues by priority.
--
-- Fixture account 1 (cup_global_rate 2, so 50,000 GYD = 100,000 CUP): cards A (priority 1), B (2), C (3), each with a 120,000 daily limit
-- and one lot (A 500,000 @960, B 250,000 @1060, C 300,000 @1100); card E is inactive. Account 2 has its own card X.
--   case 1   no choice = today's behaviour: the old call signature (two and three arguments) still works, priority order, FIFO lots;
--            cup_source_card_id stays NULL; cup_planificar / cup_consumir with a NULL start card equal the old wrappers
--   case 2   the plan reflects the choice (chosen card first) and, without it, the usual priority order
--   case 3   an adjustment never counts toward the limit, also for the chosen card
--   case 4   choosing B: B takes the CUP although A has room, the completed read shows it, the column holds the choice
--   case 5   manual close (admin) with a chosen card
--   case 6   the chosen card is short (limit): it gives what it has and the rest continues by priority (A, then C)
--   case 7   nothing has room for the whole amount: completion still succeeds, the plan and the consumption agree, shortfall warning
--   case 8   refusals: a card of another account, an inactive card, an unknown card (22023) -- the operation stays ready_to_transfer
--   case 9   the plan RPC refuses the same cards; the plan lists the active cards of the account only
--   case 10  deleting the chosen card clears the column; grants and ACLs
--
-- Run it as: BEGIN; \i 239 \i 240 \i 241 \i 256 \i 257_cup_source_card.sql \i this file; ROLLBACK;
-- STAGING only. It always ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)' and builds its own fixtures.

CREATE FUNCTION pg_temp.csc_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.csc_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

-- Runs a statement as p_uid and returns true when it fails with exactly p_state.
CREATE FUNCTION pg_temp.csc_expect_state(p_sql text, p_state text, p_uid uuid) RETURNS boolean LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.csc_claims(p_uid);
  BEGIN
    EXECUTE p_sql;
    PERFORM pg_temp.csc_claims(NULL);
    RETURN false;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.csc_claims(NULL);
    RETURN SQLSTATE = p_state;
  END;
END $f$;

-- A ready_to_transfer CUP remesa with ONE complete beneficiary that receives p_cup CUP (so the delivery readiness gate passes).
CREATE FUNCTION pg_temp.csc_op(p_acct uuid, p_conv uuid, p_cup numeric) RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acct, p_conv, 'ready_to_transfer', 'remesa', 'GYD', p_cup / 2, 'cuban_card') RETURNING id INTO v;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, card_number, phone, amount, currency, position, block_index)
  VALUES (v, 'cuban_card', 'Beneficiario ' || left(v::text, 4), '9225000011112222', '5355500000', p_cup, 'CUP', 1, 1);
  -- (329) Delivery now requires verified funding, in GYD (the source is p_cup / 2).
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, consumido_en, operation_id)
  VALUES ('3292' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12), p_cup / 2, 'GYD', 'PRUEBA CSC', now(), now(), v);
  RETURN v;
END $f$;

-- The plan RPC as a given user, with an optional start card.
CREATE FUNCTION pg_temp.csc_panel(p_op uuid, p_uid uuid, p_card uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.csc_claims(p_uid);
  v := crm_inventario_cup_operacion(p_op, p_card);
  PERFORM pg_temp.csc_claims(NULL);
  RETURN v;
END $f$;

-- The plan lines of a panel read as {card name: CUP}.
CREATE FUNCTION pg_temp.csc_plan_by_card(p_plan jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT coalesce(jsonb_object_agg(t.name, t.cup), '{}'::jsonb)
    FROM (SELECT l->>'card_name' AS name, sum((l->>'amount_cup')::numeric) AS cup
            FROM jsonb_array_elements(p_plan->'beneficiaries') b, jsonb_array_elements(b->'lines') l GROUP BY 1) t;
$f$;

-- What an operation really took, as {card name: CUP}.
CREATE FUNCTION pg_temp.csc_took(p_op uuid) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT coalesce(jsonb_object_agg(t.name, t.cup), '{}'::jsonb)
    FROM (SELECT c.name, sum(k.amount_cup) AS cup
            FROM cup_lot_consumptions k JOIN cup_cards c ON c.id = k.card_id
           WHERE k.operation_id = p_op OR k.calculator_entry_id IN (SELECT e.id FROM remittance_calculator_entries e WHERE e.operation_id = p_op)
           GROUP BY 1) t;
$f$;

CREATE FUNCTION pg_temp.csc_deliver(p_op uuid, p_uid uuid, p_card uuid DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.csc_claims(p_uid);
  IF p_card IS NULL THEN
    v := crm_entregar_operacion(p_op, jsonb_build_object('mode', 'no_proof'));
  ELSE
    v := crm_entregar_operacion(p_op, jsonb_build_object('mode', 'no_proof'), true, p_card);
  END IF;
  PERFORM pg_temp.csc_claims(NULL);
  RETURN v;
END $f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_contact uuid; v_conv uuid; v_contact2 uuid; v_conv2 uuid; v_today date;
  v_a cup_cards; v_b cup_cards; v_c cup_cards; v_e cup_cards; v_f cup_cards; v_x cup_cards;
  v_la cup_lots; v_lb cup_lots; v_lc cup_lots; v_le cup_lots; v_lx cup_lots;
  v_op1 uuid; v_op1b uuid; v_op2 uuid; v_op3 uuid; v_op4 uuid; v_op5 uuid; v_op6 uuid; v_op7 uuid; v_op8 uuid; v_opf uuid;
  v_plan jsonb; v_plan0 jsonb; v_plan_c jsonb; v_done jsonb; v_r jsonb; v_cons record; v_n integer; v_acl text;
  v_fail integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'csc-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_owner2, v_admin2]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup source test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup source other account', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'csc owner', 'csc-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'csc admin', 'csc-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'csc agent', 'csc-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_owner2, 'csc owner2', 'csc-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'csc admin2', 'csc-' || v_admin2 || '@test.invalid', v_acc2, 'admin');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '15550000350', v_acc, 'Cliente CSC') RETURNING id INTO v_contact;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_contact, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner2, '15550000351', v_acc2, 'Cliente CSC2') RETURNING id INTO v_contact2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner2, v_contact2, v_acc2) RETURNING id INTO v_conv2;

  PERFORM pg_temp.csc_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  v_a := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta A', '1111', 1, 120000, NULL);
  v_b := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta B', '2222', 2, 120000, NULL);
  v_c := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta C', '3333', 3, 120000, NULL);
  v_e := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta E', '5555', 4, 120000, NULL);
  v_f := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta F', '6666', 5, 120000, NULL);
  v_la := crm_cargar_lote_cup(v_acc, v_a.id, 500000, 960, 'lote A', NULL);
  v_lb := crm_cargar_lote_cup(v_acc, v_b.id, 250000, 1060, 'lote B', NULL);
  v_lc := crm_cargar_lote_cup(v_acc, v_c.id, 300000, 1100, 'lote C', NULL);
  v_le := crm_cargar_lote_cup(v_acc, v_e.id, 100000, 1200, 'lote E', NULL);
  v_e := crm_guardar_tarjeta_cup(v_acc, v_e.id, NULL, NULL, NULL, NULL, false);
  PERFORM pg_temp.csc_claims(v_admin2);
  PERFORM crm_set_calculator_rates(v_acc2, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  v_x := crm_guardar_tarjeta_cup(v_acc2, NULL, 'Tarjeta X', '9999', 1, 120000, NULL);
  v_lx := crm_cargar_lote_cup(v_acc2, v_x.id, 100000, 900, 'lote X', NULL);
  PERFORM pg_temp.csc_claims(NULL);
  v_today := cup_cuba_day(now());

  -- ---- case 1: no choice = today's behaviour ----------------------------------------------------------------------------------------
  v_op1 := pg_temp.csc_op(v_acc, v_conv, 100000);
  v_done := pg_temp.csc_deliver(v_op1, v_agent);
  v_fail := v_fail + pg_temp.csc_chk('1.the old two-argument call completes the operation', v_done->>'new_status' = 'completed', v_done::text);
  v_fail := v_fail + pg_temp.csc_chk('1.no choice: the whole 100,000 left from A (priority), source column NULL',
    pg_temp.csc_took(v_op1) = jsonb_build_object('Tarjeta A', 100000)
    AND (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_op1) IS NULL, pg_temp.csc_took(v_op1)::text);
  v_op1b := pg_temp.csc_op(v_acc, v_conv, 1000);
  PERFORM pg_temp.csc_claims(v_agent);
  v_r := crm_entregar_operacion(v_op1b, jsonb_build_object('mode', 'no_proof'), false);
  PERFORM pg_temp.csc_claims(NULL);
  v_fail := v_fail + pg_temp.csc_chk('1.the old three-argument call (notify off) still works', v_r->>'new_status' = 'completed', v_r::text);
  -- (A has used 101,000 now.) A NULL start card plans exactly what the three-argument allocator plans.
  v_fail := v_fail + pg_temp.csc_chk('1.cup_planificar with a NULL start card equals the three-argument wrapper',
    NOT EXISTS ((SELECT seq, card_id, lot_id, amount_cup FROM cup_planificar(v_acc, 150000, v_today))
                EXCEPT (SELECT seq, card_id, lot_id, amount_cup FROM cup_planificar(v_acc, 150000, v_today, NULL)))
    AND NOT EXISTS ((SELECT seq, card_id, lot_id, amount_cup FROM cup_planificar(v_acc, 150000, v_today, NULL))
                EXCEPT (SELECT seq, card_id, lot_id, amount_cup FROM cup_planificar(v_acc, 150000, v_today))));

  -- ---- case 2: the plan reflects the choice -------------------------------------------------------------------------------------------
  -- A used 101,000 (room 19,000), B and C untouched.
  v_op2 := pg_temp.csc_op(v_acc, v_conv, 50000);
  v_plan0 := pg_temp.csc_panel(v_op2, v_agent);
  v_fail := v_fail + pg_temp.csc_chk('2.without a choice the plan is the priority one: A 19,000 then B 31,000',
    v_plan0->>'state' = 'plan' AND pg_temp.csc_plan_by_card(v_plan0) = jsonb_build_object('Tarjeta A', 19000, 'Tarjeta B', 31000), v_plan0::text);
  v_plan_c := pg_temp.csc_panel(v_op2, v_agent, v_c.id);
  v_fail := v_fail + pg_temp.csc_chk('2.choosing C: the plan is C 50,000 only',
    pg_temp.csc_plan_by_card(v_plan_c) = jsonb_build_object('Tarjeta C', 50000) AND (v_plan_c->>'missing_cup')::numeric = 0
    AND v_plan_c->>'source_card_id' = v_c.id::text, v_plan_c::text);
  v_fail := v_fail + pg_temp.csc_chk('2.the plan without a choice reports no source card', v_plan0->>'source_card_id' IS NULL, v_plan0::text);

  -- ---- case 3: an adjustment never counts toward the limit, also for the chosen card ---------------------------------------------------
  PERFORM pg_temp.csc_claims(v_admin);
  PERFORM crm_ajustar_saldo_cup(v_a.id, (SELECT sum(remaining_cup) FROM cup_lots WHERE card_id = v_a.id) - 5000, 'conteo');
  PERFORM pg_temp.csc_claims(NULL);
  v_plan := pg_temp.csc_panel(v_op2, v_agent, v_a.id);
  v_fail := v_fail + pg_temp.csc_chk('3.after a 5,000 adjustment A still has 19,000 of limit room: A 19,000 then the rest by priority (B 31,000)',
    pg_temp.csc_plan_by_card(v_plan) = jsonb_build_object('Tarjeta A', 19000, 'Tarjeta B', 31000), v_plan::text);

  -- ---- case 4: choosing C: C takes the CUP although A has room -------------------------------------------------------------------------
  v_done := pg_temp.csc_deliver(v_op2, v_agent, v_c.id);
  v_fail := v_fail + pg_temp.csc_chk('4.delivered with a chosen card', v_done->>'new_status' = 'completed', v_done::text);
  v_fail := v_fail + pg_temp.csc_chk('4.the real consumption is C 50,000 and the column holds the choice',
    pg_temp.csc_took(v_op2) = jsonb_build_object('Tarjeta C', 50000)
    AND (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_op2) = v_c.id, pg_temp.csc_took(v_op2)::text);
  v_fail := v_fail + pg_temp.csc_chk('4.the plan shown for the choice equals what was taken, and differs from the no-choice plan',
    pg_temp.csc_plan_by_card(v_plan_c) = pg_temp.csc_took(v_op2) AND pg_temp.csc_plan_by_card(v_plan0) <> pg_temp.csc_took(v_op2));
  v_done := pg_temp.csc_panel(v_op2, v_agent);
  v_fail := v_fail + pg_temp.csc_chk('4.the completed read ("Salio de") shows C 50,000 at the lot rate',
    v_done->>'state' = 'completed' AND jsonb_array_length(v_done->'lines') = 1 AND v_done->'lines'->0->>'card_name' = 'Tarjeta C'
    AND (v_done->'lines'->0->>'amount_cup')::numeric = 50000 AND (v_done->'lines'->0->>'lot_rate')::numeric = 1100
    AND abs((v_done->>'cup_rate')::numeric - 1100) < 0.000000001, v_done::text);

  -- ---- case 5: manual close with a chosen card -------------------------------------------------------------------------------------------
  -- A room 19,000, B 120,000, C 70,000 now.
  v_op5 := pg_temp.csc_op(v_acc, v_conv, 15000);
  PERFORM pg_temp.csc_claims(v_admin);
  v_r := crm_cerrar_operacion_manual(v_op5, NULL, false, NULL, v_b.id);
  PERFORM pg_temp.csc_claims(NULL);
  v_fail := v_fail + pg_temp.csc_chk('5.manual close with a chosen card completes', v_r->>'new_status' = 'completed', v_r::text);
  v_fail := v_fail + pg_temp.csc_chk('5.manual close: B took the 15,000 (A had room), column holds the choice',
    pg_temp.csc_took(v_op5) = jsonb_build_object('Tarjeta B', 15000) AND (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_op5) = v_b.id,
    pg_temp.csc_took(v_op5)::text);
  v_op6 := pg_temp.csc_op(v_acc, v_conv, 1000);
  PERFORM pg_temp.csc_claims(v_admin);
  v_r := crm_cerrar_operacion_manual(v_op6);
  PERFORM pg_temp.csc_claims(NULL);
  v_fail := v_fail + pg_temp.csc_chk('5.the old one-argument manual close still works and keeps priority (A), column NULL',
    v_r->>'new_status' = 'completed' AND pg_temp.csc_took(v_op6) = jsonb_build_object('Tarjeta A', 1000)
    AND (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_op6) IS NULL, pg_temp.csc_took(v_op6)::text);

  -- ---- case 6: the chosen card is short -> split, rest by priority -------------------------------------------------------------------------
  -- A room 18,000, B room 105,000, C room 70,000. Choose C for 100,000: C 70,000, then A 18,000, then B 12,000.
  v_op3 := pg_temp.csc_op(v_acc, v_conv, 100000);
  v_plan := pg_temp.csc_panel(v_op3, v_agent, v_c.id);
  v_fail := v_fail + pg_temp.csc_chk('6.plan: C first (70,000), then A (18,000), then B (12,000)',
    pg_temp.csc_plan_by_card(v_plan) = jsonb_build_object('Tarjeta C', 70000, 'Tarjeta A', 18000, 'Tarjeta B', 12000)
    AND (v_plan->'beneficiaries'->0->'lines'->0->>'card_name') = 'Tarjeta C'
    AND (v_plan->'beneficiaries'->0->'lines'->1->>'card_name') = 'Tarjeta A'
    AND (v_plan->'beneficiaries'->0->'lines'->2->>'card_name') = 'Tarjeta B'
    AND (v_plan->>'missing_cup')::numeric = 0, v_plan::text);
  v_done := pg_temp.csc_deliver(v_op3, v_agent, v_c.id);
  v_fail := v_fail + pg_temp.csc_chk('6.the split really taken equals the plan',
    pg_temp.csc_took(v_op3) = pg_temp.csc_plan_by_card(v_plan), pg_temp.csc_took(v_op3)::text);

  -- ---- case 7: nothing has room for the whole amount -----------------------------------------------------------------------------------------
  -- A room 0, B room 93,000, C room 0. Choose A for 150,000: A has no room, B 93,000, missing 57,000. Completion still succeeds.
  v_op7 := pg_temp.csc_op(v_acc, v_conv, 150000);
  v_plan := pg_temp.csc_panel(v_op7, v_agent, v_a.id);
  v_fail := v_fail + pg_temp.csc_chk('7.plan: B 93,000 and 57,000 missing',
    pg_temp.csc_plan_by_card(v_plan) = jsonb_build_object('Tarjeta B', 93000) AND (v_plan->>'missing_cup')::numeric = 57000, v_plan::text);
  v_done := pg_temp.csc_deliver(v_op7, v_agent, v_a.id);
  v_fail := v_fail + pg_temp.csc_chk('7.completion is never blocked and takes what exists (B 93,000)',
    v_done->>'new_status' = 'completed' AND pg_temp.csc_took(v_op7) = jsonb_build_object('Tarjeta B', 93000), pg_temp.csc_took(v_op7)::text);

  -- ---- case 8: refusals ---------------------------------------------------------------------------------------------------------------------------
  v_op8 := pg_temp.csc_op(v_acc, v_conv, 1000);
  v_fail := v_fail + pg_temp.csc_chk('8.a card of another account is refused (22023)',
    pg_temp.csc_expect_state(format('SELECT crm_entregar_operacion(%L, %L::jsonb, true, %L)', v_op8, '{"mode":"no_proof"}', v_x.id), '22023', v_agent));
  v_fail := v_fail + pg_temp.csc_chk('8.an inactive card is refused (22023)',
    pg_temp.csc_expect_state(format('SELECT crm_entregar_operacion(%L, %L::jsonb, true, %L)', v_op8, '{"mode":"no_proof"}', v_e.id), '22023', v_agent));
  v_fail := v_fail + pg_temp.csc_chk('8.an unknown card is refused (22023)',
    pg_temp.csc_expect_state(format('SELECT crm_entregar_operacion(%L, %L::jsonb, true, %L)', v_op8, '{"mode":"no_proof"}', gen_random_uuid()), '22023', v_agent));
  v_fail := v_fail + pg_temp.csc_chk('8.manual close refuses a card of another account and an inactive card (22023)',
    pg_temp.csc_expect_state(format('SELECT crm_cerrar_operacion_manual(%L, NULL, false, NULL, %L)', v_op8, v_x.id), '22023', v_admin)
    AND pg_temp.csc_expect_state(format('SELECT crm_cerrar_operacion_manual(%L, NULL, false, NULL, %L)', v_op8, v_e.id), '22023', v_admin));
  v_fail := v_fail + pg_temp.csc_chk('8.the refused operation stays ready_to_transfer with no source card and no consumption',
    (SELECT status FROM remittance_operations WHERE id = v_op8) = 'ready_to_transfer'
    AND (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_op8) IS NULL AND pg_temp.csc_took(v_op8) = '{}'::jsonb);
  v_fail := v_fail + pg_temp.csc_chk('8.the existing authorization still applies (another account admin: 42501)',
    pg_temp.csc_expect_state(format('SELECT crm_entregar_operacion(%L, %L::jsonb, true, %L)', v_op8, '{"mode":"no_proof"}', v_a.id), '42501', v_admin2));

  -- ---- case 9: the plan RPC refuses the same cards and lists the picker's cards ---------------------------------------------------------------
  v_fail := v_fail + pg_temp.csc_chk('9.the plan refuses a card of another account, an inactive card and an unknown card (22023)',
    pg_temp.csc_expect_state(format('SELECT crm_inventario_cup_operacion(%L, %L)', v_op8, v_x.id), '22023', v_agent)
    AND pg_temp.csc_expect_state(format('SELECT crm_inventario_cup_operacion(%L, %L)', v_op8, v_e.id), '22023', v_agent)
    AND pg_temp.csc_expect_state(format('SELECT crm_inventario_cup_operacion(%L, %L)', v_op8, gen_random_uuid()), '22023', v_agent));
  v_plan := pg_temp.csc_panel(v_op8, v_agent);
  v_fail := v_fail + pg_temp.csc_chk('9.the plan lists the ACTIVE cards of the account only (A, B, C, F), by priority, with name, last4, balance and room',
    v_plan->>'state' = 'plan' AND jsonb_array_length(v_plan->'cards') = 4
    AND (v_plan->'cards'->0->>'id') = v_a.id::text AND (v_plan->'cards'->1->>'id') = v_b.id::text
    AND (v_plan->'cards'->2->>'id') = v_c.id::text AND (v_plan->'cards'->3->>'id') = v_f.id::text
    AND v_plan->'cards'->0->>'name' = 'Tarjeta A' AND v_plan->'cards'->0->>'last4' = '1111'
    AND (v_plan->'cards'->0->>'balance_cup')::numeric = (SELECT sum(remaining_cup) FROM cup_lots WHERE card_id = v_a.id)
    AND (v_plan->'cards'->3->>'balance_cup')::numeric = 0
    AND (v_plan->'cards'->1->>'remaining_limit_today_cup')::numeric = 0
    AND v_plan::text NOT LIKE '%Tarjeta X%' AND v_plan::text NOT LIKE '%Tarjeta E%', v_plan::text);

  -- ---- case 10: ON DELETE SET NULL; grants ----------------------------------------------------------------------------------------------------------
  v_opf := pg_temp.csc_op(v_acc, v_conv, 1000);
  v_done := pg_temp.csc_deliver(v_opf, v_agent, v_f.id);
  v_fail := v_fail + pg_temp.csc_chk('10.a card without lots can be chosen; the rest falls to priority (B has 0 room, C 0, A 0 -> nothing), still completes',
    v_done->>'new_status' = 'completed' AND (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_opf) = v_f.id, v_done::text);
  DELETE FROM cup_cards WHERE id = v_f.id;
  v_fail := v_fail + pg_temp.csc_chk('10.deleting the chosen card clears the column (ON DELETE SET NULL)',
    (SELECT cup_source_card_id FROM remittance_operations WHERE id = v_opf) IS NULL);
  v_fail := v_fail + pg_temp.csc_chk('10.grants: the RPCs are authenticated + service_role, never anon; the allocators stay internal',
    has_function_privilege('authenticated', 'public.crm_entregar_operacion(uuid, jsonb, boolean, uuid)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.crm_entregar_operacion(uuid, jsonb, boolean, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_entregar_operacion(uuid, jsonb, boolean, uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_cerrar_operacion_manual(uuid, text, boolean, text, uuid)', 'EXECUTE')
    AND has_function_privilege('service_role', 'public.crm_cerrar_operacion_manual(uuid, text, boolean, text, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_cerrar_operacion_manual(uuid, text, boolean, text, uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_inventario_cup_operacion(uuid, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_inventario_cup_operacion(uuid, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('service_role', 'public.crm_inventario_cup_operacion(uuid, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cup_planificar(uuid, numeric, date, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cup_planificar(uuid, numeric, date, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date, uuid)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cup_planificar(uuid, numeric, date)', 'EXECUTE')
    AND NOT has_function_privilege('authenticated', 'public.cup_consumir(uuid, numeric, uuid, uuid, timestamptz, date)', 'EXECUTE'));
  v_fail := v_fail + pg_temp.csc_chk('10.no stale overloads: one crm_entregar_operacion, one crm_cerrar_operacion_manual, one crm_inventario_cup_operacion',
    (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'crm_entregar_operacion') = 1
    AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'crm_cerrar_operacion_manual') = 1
    AND (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'crm_inventario_cup_operacion') = 1);

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'cup-source-card: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
