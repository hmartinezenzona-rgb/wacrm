\set ON_ERROR_STOP on
-- cup-balance-adjust.sql -- self-reverting assertion for 256_cup_balance_adjust.sql
--
-- Proves: the consumption kind (operacion / manual / ajuste), crm_ajustar_saldo_cup (FIFO decrease, newest-first increase with
-- negative ajuste rows, refusals, no-op, audit), the daily limit ignoring adjustments (report AND allocator), the report listing every
-- lot (used-up ones flagged agotado), and an operation / manual consumption still working after an adjustment.
--
-- Fixture account 1: card A (priority 1, limit 120,000) with lot L1 100,000 @900 (loaded 2 days ago) and lot L2 200,000 @1000 (loaded
-- yesterday). Account 2 only exists for the cross-account refusal.
--   case 1   used today = 30,000 first (a real cup_consumir), kind of that row is 'operacion'
--   case 2   lower 270,000 -> 250,000: FIFO, oldest lot first
--   case 3   lower across lots: oldest lot emptied, the next one takes the rest
--   case 4   higher: newest lot first, each up to its loaded amount, NEGATIVE ajuste rows
--   case 5   refusals: above the loaded total, negative, NULL (22023); equal is a no-op (no rows, no audit)
--   case 6   authorization: agent / other account admin / anonymous 42501; unknown card P0002
--   case 7   adjustments never change used_today / remaining_limit (report) nor the allocator's room
--   case 8   report lists every lot, used-up ones agotado = true, not editable; kind and reason on movements
--   case 9   an operation consumption and a manual line after an adjustment still work; kinds recorded
--   case 10  audit row, check constraints, grants
--
-- Run it as: BEGIN; \i 239 \i 240 \i 241 \i 242 ...(whatever is applied) \i 256_cup_balance_adjust.sql \i this file; ROLLBACK;
-- STAGING only. It always ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)' and builds its own fixtures.

CREATE FUNCTION pg_temp.cba_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.cba_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

-- Runs a statement as p_uid and returns true when it fails with exactly p_state.
CREATE FUNCTION pg_temp.cba_expect_state(p_sql text, p_state text, p_uid uuid) RETURNS boolean LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.cba_claims(p_uid);
  BEGIN
    EXECUTE p_sql;
    PERFORM pg_temp.cba_claims(NULL);
    RETURN false;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.cba_claims(NULL);
    RETURN SQLSTATE = p_state;
  END;
END $f$;

-- The adjust RPC as a given user.
CREATE FUNCTION pg_temp.cba_adjust(p_card uuid, p_target numeric, p_reason text, p_uid uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.cba_claims(p_uid);
  v := crm_ajustar_saldo_cup(p_card, p_target, p_reason);
  PERFORM pg_temp.cba_claims(NULL);
  RETURN v;
END $f$;

-- One card of the report as a given user.
CREATE FUNCTION pg_temp.cba_card(p_acct uuid, p_card uuid, p_uid uuid) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.cba_claims(p_uid);
  v := crm_inventario_cup(p_acct);
  PERFORM pg_temp.cba_claims(NULL);
  RETURN (SELECT c FROM jsonb_array_elements(v->'cards') c WHERE (c->>'id')::uuid = p_card);
END $f$;

CREATE FUNCTION pg_temp.cba_lot(p_card jsonb, p_lot uuid) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT l FROM jsonb_array_elements(p_card->'lots') l WHERE (l->>'id')::uuid = p_lot;
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_today date; v_gy_today date;
  v_a cup_cards; v_l1 cup_lots; v_l2 cup_lots;
  v_r jsonb; v_card jsonb; v_cnt integer; v_audn integer; v_aud record; v_cons record; v_man uuid; v_plan_total numeric;
  v_fail integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cba-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_owner2, v_admin2]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup adjust test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup adjust other account', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'cba owner', 'cba-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'cba admin', 'cba-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'cba agent', 'cba-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_owner2, 'cba owner2', 'cba-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'cba admin2', 'cba-' || v_admin2 || '@test.invalid', v_acc2, 'admin');

  PERFORM pg_temp.cba_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 2, 'usdt_buy_gyd', 240, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 1100));
  v_a := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta A', '1111', 1, 120000, NULL);
  v_l1 := crm_cargar_lote_cup(v_acc, v_a.id, 100000, 900, 'lote 1', now() - interval '2 days');
  v_l2 := crm_cargar_lote_cup(v_acc, v_a.id, 200000, 1000, 'lote 2', now() - interval '1 day');
  PERFORM pg_temp.cba_claims(NULL);
  v_today := cup_cuba_day(now());
  v_gy_today := (now() AT TIME ZONE 'America/Guyana')::date;

  -- ---- case 1: 30,000 used today by a real consumption (FIFO: from L1) --------------------------------------------------------------
  PERFORM cup_consumir(v_acc, 30000, NULL, NULL, now(), v_today);
  v_card := pg_temp.cba_card(v_acc, v_a.id, v_admin);
  v_fail := v_fail + pg_temp.cba_chk('1.balance 270,000, used today 30,000, room 90,000',
    (v_card->>'balance_cup')::numeric = 270000 AND (v_card->>'used_today_cup')::numeric = 30000
    AND (v_card->>'remaining_limit_today_cup')::numeric = 90000, v_card::text);
  v_fail := v_fail + pg_temp.cba_chk('1.the operation consumption is kind operacion',
    (SELECT kind FROM cup_lot_consumptions WHERE card_id = v_a.id AND amount_cup = 30000) = 'operacion');

  -- ---- case 2: lower 270,000 -> 250,000: FIFO, oldest loaded first (L1 had 70,000 left) ----------------------------------------------
  v_r := pg_temp.cba_adjust(v_a.id, 250000, 'conteo real', v_admin);
  v_fail := v_fail + pg_temp.cba_chk('2.result: before 270,000, after 250,000, one movement of 20,000 on the oldest lot',
    (v_r->>'card_id')::uuid = v_a.id AND (v_r->>'saldo_anterior')::numeric = 270000 AND (v_r->>'saldo_nuevo')::numeric = 250000
    AND jsonb_array_length(v_r->'movimientos') = 1 AND (v_r->'movimientos'->0->>'lot_id')::uuid = v_l1.id
    AND (v_r->'movimientos'->0->>'amount_cup')::numeric = 20000, v_r::text);
  v_fail := v_fail + pg_temp.cba_chk('2.L1 remaining 50,000 (70,000 - 20,000), L2 untouched 200,000',
    (SELECT remaining_cup FROM cup_lots WHERE id = v_l1.id) = 50000 AND (SELECT remaining_cup FROM cup_lots WHERE id = v_l2.id) = 200000);
  SELECT * INTO v_cons FROM cup_lot_consumptions WHERE card_id = v_a.id AND kind = 'ajuste';
  v_fail := v_fail + pg_temp.cba_chk('2.the ajuste row: positive 20,000, no operation / entry, reason and actor',
    v_cons.amount_cup = 20000 AND v_cons.operation_id IS NULL AND v_cons.calculator_entry_id IS NULL
    AND v_cons.reason = 'conteo real' AND v_cons.created_by = v_admin AND v_cons.lot_id = v_l1.id, to_jsonb(v_cons)::text);

  -- ---- case 3: lower across lots 250,000 -> 120,000: L1 emptied (50,000), L2 gives 80,000 ------------------------------------------------
  v_r := pg_temp.cba_adjust(v_a.id, 120000, NULL, v_admin);
  v_fail := v_fail + pg_temp.cba_chk('3.two movements, oldest first: L1 50,000 then L2 80,000',
    jsonb_array_length(v_r->'movimientos') = 2
    AND (v_r->'movimientos'->0->>'lot_id')::uuid = v_l1.id AND (v_r->'movimientos'->0->>'amount_cup')::numeric = 50000
    AND (v_r->'movimientos'->1->>'lot_id')::uuid = v_l2.id AND (v_r->'movimientos'->1->>'amount_cup')::numeric = 80000
    AND (v_r->>'saldo_nuevo')::numeric = 120000, v_r::text);
  v_fail := v_fail + pg_temp.cba_chk('3.L1 = 0, L2 = 120,000, exact balance 120,000',
    (SELECT remaining_cup FROM cup_lots WHERE id = v_l1.id) = 0 AND (SELECT remaining_cup FROM cup_lots WHERE id = v_l2.id) = 120000
    AND (SELECT sum(remaining_cup) FROM cup_lots WHERE card_id = v_a.id) = 120000);

  -- ---- case 4: higher 120,000 -> 260,000 (+140,000): newest lot first up to its loaded amount, then the older one -------------------
  v_r := pg_temp.cba_adjust(v_a.id, 260000, 'se acredito', v_admin);
  v_fail := v_fail + pg_temp.cba_chk('4.movements newest first: L2 gets 80,000 back (to its 200,000), L1 gets 60,000; recorded negative',
    jsonb_array_length(v_r->'movimientos') = 2
    AND (v_r->'movimientos'->0->>'lot_id')::uuid = v_l2.id AND (v_r->'movimientos'->0->>'amount_cup')::numeric = -80000
    AND (v_r->'movimientos'->1->>'lot_id')::uuid = v_l1.id AND (v_r->'movimientos'->1->>'amount_cup')::numeric = -60000
    AND (v_r->>'saldo_anterior')::numeric = 120000 AND (v_r->>'saldo_nuevo')::numeric = 260000, v_r::text);
  v_fail := v_fail + pg_temp.cba_chk('4.L2 = 200,000 (full), L1 = 60,000, never above the loaded amount',
    (SELECT remaining_cup FROM cup_lots WHERE id = v_l2.id) = 200000 AND (SELECT remaining_cup FROM cup_lots WHERE id = v_l1.id) = 60000
    AND (SELECT bool_and(remaining_cup <= amount_cup) FROM cup_lots WHERE card_id = v_a.id));
  v_fail := v_fail + pg_temp.cba_chk('4.two negative ajuste rows with the reason',
    (SELECT count(*) FROM cup_lot_consumptions WHERE card_id = v_a.id AND kind = 'ajuste' AND amount_cup < 0 AND reason = 'se acredito') = 2);

  -- ---- case 5: refusals and the no-op ------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cba_chk('5.above the loaded total (300,000) is refused 22023',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, 300001, NULL)', v_a.id), '22023', v_admin));
  v_fail := v_fail + pg_temp.cba_chk('5.exactly the loaded total (300,000) is allowed',
    (pg_temp.cba_adjust(v_a.id, 300000, 'todo el cargado', v_admin)->>'saldo_nuevo')::numeric = 300000);
  v_fail := v_fail + pg_temp.cba_chk('5.negative is refused 22023',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, -1, NULL)', v_a.id), '22023', v_admin));
  v_fail := v_fail + pg_temp.cba_chk('5.NULL target is refused 22023',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, NULL, NULL)', v_a.id), '22023', v_admin));
  SELECT count(*) INTO v_cnt FROM cup_lot_consumptions WHERE kind = 'ajuste';
  SELECT count(*) INTO v_audn FROM remittance_admin_audit WHERE row_id = v_a.id AND field_name = 'balance_cup';
  v_r := pg_temp.cba_adjust(v_a.id, 300000, 'igual', v_admin);
  v_fail := v_fail + pg_temp.cba_chk('5.equal target is a no-op: no movements, no new rows, no new audit',
    jsonb_array_length(v_r->'movimientos') = 0 AND (v_r->>'saldo_anterior')::numeric = 300000 AND (v_r->>'saldo_nuevo')::numeric = 300000
    AND (SELECT count(*) FROM cup_lot_consumptions WHERE kind = 'ajuste') = v_cnt
    AND (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_a.id AND field_name = 'balance_cup') = v_audn, v_r::text);
  v_r := pg_temp.cba_adjust(v_a.id, 0, 'vacia', v_admin);
  v_fail := v_fail + pg_temp.cba_chk('5.zero is allowed (empties the card)',
    (v_r->>'saldo_nuevo')::numeric = 0 AND (v_r->>'saldo_anterior')::numeric = 300000
    AND (SELECT coalesce(sum(remaining_cup), 0) FROM cup_lots WHERE card_id = v_a.id) = 0, v_r::text);
  PERFORM pg_temp.cba_adjust(v_a.id, 260000, 'repone', v_admin);

  -- ---- case 6: authorization -----------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cba_chk('6.an agent of the account is refused 42501',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, 100, NULL)', v_a.id), '42501', v_agent));
  v_fail := v_fail + pg_temp.cba_chk('6.an admin of another account is refused 42501',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, 100, NULL)', v_a.id), '42501', v_admin2));
  v_fail := v_fail + pg_temp.cba_chk('6.an unauthenticated caller is refused 42501',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, 100, NULL)', v_a.id), '42501', NULL));
  v_fail := v_fail + pg_temp.cba_chk('6.an unknown card is P0002',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, 100, NULL)', gen_random_uuid()), 'P0002', v_admin));
  v_fail := v_fail + pg_temp.cba_chk('6.a too long reason is refused 22023',
    pg_temp.cba_expect_state(format('SELECT crm_ajustar_saldo_cup(%L, 100, %L)', v_a.id, repeat('x', 501)), '22023', v_admin));
  v_fail := v_fail + pg_temp.cba_chk('6.nothing changed by the refusals (balance 260,000)',
    (SELECT sum(remaining_cup) FROM cup_lots WHERE card_id = v_a.id) = 260000);

  -- ---- case 7: adjustments never touch the daily limit ------------------------------------------------------------------------------------
  v_card := pg_temp.cba_card(v_acc, v_a.id, v_admin);
  v_fail := v_fail + pg_temp.cba_chk('7.after several adjustments used today is still 30,000 and room 90,000',
    (v_card->>'used_today_cup')::numeric = 30000 AND (v_card->>'remaining_limit_today_cup')::numeric = 90000, v_card::text);
  SELECT coalesce(sum(amount_cup), 0) INTO v_plan_total FROM cup_planificar(v_acc, 500000, v_today);
  v_fail := v_fail + pg_temp.cba_chk('7.the allocator plans exactly the 90,000 of room (adjustments excluded)', v_plan_total = 90000, v_plan_total::text);

  -- ---- case 8: the report lists every lot ------------------------------------------------------------------------------------------------------
  PERFORM pg_temp.cba_adjust(v_a.id, 150000, 'baja', v_admin);   -- 260,000 -> 150,000: L1 (60,000) is used up, L2 gives 50,000
  v_card := pg_temp.cba_card(v_acc, v_a.id, v_admin);
  v_fail := v_fail + pg_temp.cba_chk('8.both lots listed, even the used-up one, with agotado flags',
    jsonb_array_length(v_card->'lots') = 2
    AND (pg_temp.cba_lot(v_card, v_l1.id)->>'agotado')::boolean = true AND (pg_temp.cba_lot(v_card, v_l1.id)->>'remaining_cup')::numeric = 0
    AND (pg_temp.cba_lot(v_card, v_l2.id)->>'agotado')::boolean = false, v_card->>'lots');
  v_fail := v_fail + pg_temp.cba_chk('8.balance_cup kept (150,000), lots keep amount_cup and are not editable once touched',
    (v_card->>'balance_cup')::numeric = 150000 AND (pg_temp.cba_lot(v_card, v_l1.id)->>'amount_cup')::numeric = 100000
    AND (pg_temp.cba_lot(v_card, v_l1.id)->>'editable')::boolean = false AND (pg_temp.cba_lot(v_card, v_l2.id)->>'editable')::boolean = false);
  v_fail := v_fail + pg_temp.cba_chk('8.an adjusted lot says so (adjusted = true) and exposes the net adjustment',
    (pg_temp.cba_lot(v_card, v_l2.id)->>'adjusted')::boolean = true AND (pg_temp.cba_lot(v_card, v_l2.id)->>'adjustment_net_cup') IS NOT NULL);
  v_fail := v_fail + pg_temp.cba_chk('8.movements carry kind and reason; ajuste rows are listed',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v_card->'consumptions_today') m WHERE m->>'kind' = 'ajuste' AND m->>'reason' = 'baja')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_card->'consumptions_today') m WHERE m->>'kind' = 'operacion'), v_card->>'consumptions_today');
  v_fail := v_fail + pg_temp.cba_chk('8.the report still shows used today 30,000 (adjustments excluded)',
    (v_card->>'used_today_cup')::numeric = 30000);

  -- ---- case 9: operation and manual consumptions after adjustments ------------------------------------------------------------------------------
  SELECT * INTO v_cons FROM cup_consumir(v_acc, 10000, NULL, NULL, now(), v_today);
  v_fail := v_fail + pg_temp.cba_chk('9.an operation consumption after the adjustments takes from the usable lot (L2 @1000) at its rate',
    v_cons.consumed_cup = 10000 AND v_cons.missing_cup = 0 AND jsonb_array_length(v_cons.parts) = 1
    AND (v_cons.parts->0->>'lot_id')::uuid = v_l2.id AND v_cons.effective_rate = 1000, to_jsonb(v_cons)::text);
  PERFORM pg_temp.cba_claims(v_agent);
  PERFORM crm_registrar_entradas_manuales(v_acc, jsonb_build_array(jsonb_build_object(
    'customer', 'Manual CBA', 'service', 'CUP', 'currency', 'CUP', 'amount', 5000, 'facturado_gyd', 2000, 'invertido_gyd', 1500,
    'retorno_gyd', 500, 'date', v_gy_today::text, 'raw_line', '• Manual CBA 5,000 cup (240/960)')));
  PERFORM pg_temp.cba_claims(NULL);
  SELECT id INTO v_man FROM remittance_calculator_entries WHERE account_id = v_acc AND source = 'manual' AND customer_name = 'Manual CBA';
  v_fail := v_fail + pg_temp.cba_chk('9.the manual line consumption is kind manual',
    (SELECT count(*) FROM cup_lot_consumptions WHERE calculator_entry_id = v_man AND kind = 'manual') >= 1
    AND (SELECT count(*) FROM cup_lot_consumptions WHERE calculator_entry_id = v_man AND kind <> 'manual') = 0);
  v_card := pg_temp.cba_card(v_acc, v_a.id, v_admin);
  v_fail := v_fail + pg_temp.cba_chk('9.used today counts operation + manual only: 30,000 + 10,000 + 5,000 = 45,000',
    (v_card->>'used_today_cup')::numeric = 45000 AND (v_card->>'remaining_limit_today_cup')::numeric = 75000, v_card::text);
  PERFORM cup_devolver(v_man, NULL);
  v_fail := v_fail + pg_temp.cba_chk('9.voiding the manual line returns its CUP and leaves the adjustment rows alone',
    (SELECT count(*) FROM cup_lot_consumptions WHERE card_id = v_a.id AND kind = 'ajuste') > 0
    AND (SELECT count(*) FROM cup_lot_consumptions WHERE calculator_entry_id = v_man) = 0);

  -- ---- case 10: audit, constraints, grants -----------------------------------------------------------------------------------------------------
  SELECT * INTO v_aud FROM remittance_admin_audit
   WHERE row_id = v_a.id AND field_name = 'balance_cup' AND reason = 'conteo real';
  v_fail := v_fail + pg_temp.cba_chk('10.audit: cup_cards / human_correction / balance_cup with before, after and reason',
    v_aud.table_name = 'cup_cards' AND v_aud.action = 'human_correction' AND v_aud.account_id = v_acc
    AND (v_aud.before->>'balance_cup')::numeric = 270000 AND (v_aud.after->>'balance_cup')::numeric = 250000 AND v_aud.actor = v_admin::text,
    to_jsonb(v_aud)::text);
  v_fail := v_fail + pg_temp.cba_chk('10.a NEGATIVE row is only allowed for kind ajuste',
    pg_temp.cba_expect_state(format('INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, cuba_day, kind) VALUES (%L, %L, %L, -5, current_date, %L)',
                                    v_acc, v_l2.id, v_a.id, 'operacion'), '23514', NULL));
  v_fail := v_fail + pg_temp.cba_chk('10.an ajuste row cannot carry an operation or entry reference',
    pg_temp.cba_expect_state(format('INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, calculator_entry_id, amount_cup, cuba_day, kind) VALUES (%L, %L, %L, %L, 5, current_date, %L)',
                                    v_acc, v_l2.id, v_a.id, v_man, 'ajuste'), '23514', NULL));
  v_fail := v_fail + pg_temp.cba_chk('10.an unknown kind is refused',
    pg_temp.cba_expect_state(format('INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, cuba_day, kind) VALUES (%L, %L, %L, 5, current_date, %L)',
                                    v_acc, v_l2.id, v_a.id, 'otro'), '23514', NULL));
  v_fail := v_fail + pg_temp.cba_chk('10.grants: the RPC is authenticated-only',
    has_function_privilege('authenticated', 'public.crm_ajustar_saldo_cup(uuid, numeric, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_ajustar_saldo_cup(uuid, numeric, text)', 'EXECUTE'));

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'cup-balance-adjust: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
