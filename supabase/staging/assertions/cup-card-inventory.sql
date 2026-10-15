\set ON_ERROR_STOP on
-- Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- cup-card-inventory.sql -- self-reverting assertion for 239_cup_card_inventory.sql
--
-- STATUS: written, pending staging run (T4). It has NOT been executed yet.
--
-- Proves the CUP inventory (phase 1):
--   case 1  admin creates card A (priority 1) and B (priority 2); loads 500,000 CUP @960 on A and 250,000 @1060 on B; the report lists
--           A then B with balances 500000 / 250000, used_today 0 and remaining_limit_today 120000 each, lots FIFO with their rates.
--   case 2  reorder: B -> priority 0 puts B first; the update keeps what it did not name (limit, last4); last4 '' clears it.
--   case 3  create without priority goes last; two lots on one card come back FIFO by loaded_at.
--   case 4  correct an unconsumed lot (amount, rate, note): remaining follows the new amount; a lot with a consumption row, or with
--           remaining < amount, is refused (22023); delete likewise; an unconsumed lot deletes.
--   case 5  used today / remaining limit: a consumption row today (Cuba day) lowers remaining_limit_today; yesterday's does not;
--           cup_cuba_day uses America/Havana (2026-01-01 03:00Z is still 2025-12-31 in Cuba).
--   case 6  deactivated cards leave the report unless p_include_inactive; a lot cannot be loaded on an inactive card (22023);
--           a duplicate ACTIVE name is refused (22023), the same name on an inactive card is fine; reactivating into a clash is refused.
--   case 7  bad values refused (22023): empty name, last4 of 3 digits / letters, limit 0, amount 0 / negative, rate 0, nothing to correct.
--   case 8  non-admin (agent) and a user of another account are refused on every RPC (42501); unknown card / lot (P0002);
--           a card of another account addressed with my account id is P0002.
--   case 9  direct INSERT / UPDATE / DELETE by role authenticated is refused (42501); members SELECT only their own account's rows.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK (BEGIN ... \i 239 ... \i this file ... ROLLBACK), on STAGING only.
-- Never COMMIT. Never run against production. Builds its own fixtures (consumption rows are inserted directly: phase 1 has no writer).

SAVEPOINT cup_card_inventory;

CREATE FUNCTION pg_temp.cup_expect(p_label text, p_sql text, p_state text, p_user text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_user IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  END IF;
  BEGIN
    EXECUTE p_sql;
    RAISE WARNING 'FAIL [%] expected % but it succeeded', p_label, p_state;
    RETURN 1;
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = p_state THEN
      RAISE NOTICE 'PASS [%] refused (%)', p_label, SQLERRM;
      RETURN 0;
    END IF;
    RAISE WARNING 'FAIL [%] expected % got % (%)', p_label, p_state, SQLSTATE, SQLERRM;
    RETURN 1;
  END;
END $f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid();
  v_admin uuid := gen_random_uuid();
  v_agent uuid := gen_random_uuid();
  v_other uuid := gen_random_uuid();
  v_acc   uuid;
  v_acc2  uuid;
  v_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_a cup_cards; v_b cup_cards; v_c cup_cards; v_x cup_cards; v_foreign cup_cards;
  v_la cup_lots; v_lb cup_lots; v_l1 cup_lots; v_l2 cup_lots; v_cons cup_lots; v_part cup_lots; v_del cup_lots;
  v_rep jsonb; v_card jsonb;
  v_today date;
  v_fail integer := 0;
  v_n numeric;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cup-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_other]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup inventory test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cup inventory other account', v_other) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'cup owner', 'cup-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'cup admin', 'cup-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'cup agent', 'cup-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_other, 'cup other', 'cup-' || v_other || '@test.invalid', v_acc2, 'owner');

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_other, 'role', 'authenticated')::text, true);
  v_foreign := crm_guardar_tarjeta_cup(v_acc2, NULL, 'Foreign', NULL, 1, NULL, NULL);

  -- ---- case 1: the acceptance example ------------------------------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_a := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta A', '1234', 1, NULL, NULL);
  v_b := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta B', NULL, 2, NULL, NULL);
  IF v_a.daily_limit_cup <> 120000 OR v_a.last4 <> '1234' OR NOT v_a.active OR v_b.last4 IS NOT NULL THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 1.create] defaults wrong: %', row_to_json(v_a);
  ELSE RAISE NOTICE 'PASS [case 1.create] cards created with the 120000 default limit'; END IF;
  v_la := crm_cargar_lote_cup(v_acc, v_a.id, 500000, 960, 'compra A', NULL);
  v_lb := crm_cargar_lote_cup(v_acc, v_b.id, 250000, 1060, NULL, NULL);
  v_rep := crm_inventario_cup(v_acc);
  IF jsonb_array_length(v_rep->'cards') <> 2
     OR v_rep->'cards'->0->>'name' <> 'Tarjeta A' OR v_rep->'cards'->1->>'name' <> 'Tarjeta B'
     OR (v_rep->'cards'->0->>'balance_cup')::numeric <> 500000 OR (v_rep->'cards'->1->>'balance_cup')::numeric <> 250000
     OR (v_rep->'cards'->0->>'remaining_limit_today_cup')::numeric <> 120000 OR (v_rep->'cards'->1->>'remaining_limit_today_cup')::numeric <> 120000
     OR (v_rep->'cards'->0->>'used_today_cup')::numeric <> 0
     OR (v_rep->'cards'->0->'lots'->0->>'rate_cup_per_usdt')::numeric <> 960 OR (v_rep->'cards'->1->'lots'->0->>'rate_cup_per_usdt')::numeric <> 1060
     OR (v_rep->>'cuba_day')::date <> cup_cuba_day(now()) THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 1.report] %', v_rep;
  ELSE RAISE NOTICE 'PASS [case 1.report] A 500000 @960, B 250000 @1060, both 120000 left today'; END IF;

  -- ---- case 2: reorder, partial update, clear last4 ------------------------------------------------------------------
  v_b := crm_guardar_tarjeta_cup(v_acc, v_b.id, NULL, NULL, 0, NULL, NULL);
  v_rep := crm_inventario_cup(v_acc);
  IF v_rep->'cards'->0->>'name' <> 'Tarjeta B' OR v_b.daily_limit_cup <> 120000 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 2.reorder] %', v_rep;
  ELSE RAISE NOTICE 'PASS [case 2.reorder] B (priority 0) comes first and kept its limit'; END IF;
  v_a := crm_guardar_tarjeta_cup(v_acc, v_a.id, NULL, '', NULL, 90000, NULL);
  IF v_a.last4 IS NOT NULL OR v_a.daily_limit_cup <> 90000 OR v_a.name <> 'Tarjeta A' OR v_a.priority <> 1 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 2.partial] %', row_to_json(v_a);
  ELSE RAISE NOTICE 'PASS [case 2.partial] last4 cleared, limit 90000, name and priority kept'; END IF;
  v_a := crm_guardar_tarjeta_cup(v_acc, v_a.id, NULL, NULL, NULL, 120000, NULL);

  -- ---- case 3: priority defaults last; FIFO order ---------------------------------------------------------------------
  v_c := crm_guardar_tarjeta_cup(v_acc, NULL, '  Tarjeta C  ', NULL, NULL, NULL, NULL);
  IF v_c.priority <> 3 OR v_c.name <> 'Tarjeta C' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 3.priority] priority %, name "%"', v_c.priority, v_c.name;
  ELSE RAISE NOTICE 'PASS [case 3.priority] new card goes last (3), name trimmed'; END IF;
  v_l1 := crm_cargar_lote_cup(v_acc, v_c.id, 1000, 970, 'segundo', now() - interval '1 hour');
  v_l2 := crm_cargar_lote_cup(v_acc, v_c.id, 2000, 980, 'primero', now() - interval '2 hours');
  v_rep := crm_inventario_cup(v_acc);
  SELECT c INTO v_card FROM jsonb_array_elements(v_rep->'cards') c WHERE c->>'name' = 'Tarjeta C';
  IF v_card->'lots'->0->>'note' <> 'primero' OR v_card->'lots'->1->>'note' <> 'segundo' OR (v_card->>'balance_cup')::numeric <> 3000 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 3.fifo] %', v_card;
  ELSE RAISE NOTICE 'PASS [case 3.fifo] lots come back by loaded_at, balance 3000'; END IF;

  -- ---- case 4: correct / delete ------------------------------------------------------------------------------------------
  v_l1 := crm_corregir_lote_cup(v_l1.id, 1500, 975, 'corregido');
  IF v_l1.amount_cup <> 1500 OR v_l1.remaining_cup <> 1500 OR v_l1.rate_cup_per_usdt <> 975 OR v_l1.note <> 'corregido' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 4.correct] %', row_to_json(v_l1);
  ELSE RAISE NOTICE 'PASS [case 4.correct] unconsumed lot corrected, remaining follows amount'; END IF;
  v_l1 := crm_corregir_lote_cup(v_l1.id, NULL, NULL, '');
  IF v_l1.note IS NOT NULL OR v_l1.amount_cup <> 1500 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 4.note] %', row_to_json(v_l1);
  ELSE RAISE NOTICE 'PASS [case 4.note] note cleared, rest kept'; END IF;

  v_cons := crm_cargar_lote_cup(v_acc, v_a.id, 10000, 960, 'consumido', NULL);
  INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, consumed_at, cuba_day)
  VALUES (v_acc, v_cons.id, v_a.id, 1000, now(), cup_cuba_day(now()));
  v_fail := v_fail + pg_temp.cup_expect('case 4.consumed-row correct (remaining = amount, row exists)', format('SELECT crm_corregir_lote_cup(%L, 5000, NULL, NULL)', v_cons.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 4.consumed-row delete', format('SELECT crm_eliminar_lote_cup(%L)', v_cons.id), '22023');
  v_part := crm_cargar_lote_cup(v_acc, v_a.id, 8000, 960, 'parcial', NULL);
  UPDATE cup_lots SET remaining_cup = 7000 WHERE id = v_part.id;
  v_fail := v_fail + pg_temp.cup_expect('case 4.partial correct (remaining < amount)', format('SELECT crm_corregir_lote_cup(%L, 5000, NULL, NULL)', v_part.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 4.partial delete', format('SELECT crm_eliminar_lote_cup(%L)', v_part.id), '22023');
  v_del := crm_cargar_lote_cup(v_acc, v_a.id, 777, 960, 'borrable', NULL);
  PERFORM crm_eliminar_lote_cup(v_del.id);
  IF EXISTS (SELECT 1 FROM cup_lots WHERE id = v_del.id) THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 4.delete] lot still there';
  ELSE RAISE NOTICE 'PASS [case 4.delete] unconsumed lot deleted'; END IF;

  -- ---- case 5: used today / remaining limit ------------------------------------------------------------------------------
  v_today := cup_cuba_day(now());
  INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, consumed_at, cuba_day)
  VALUES (v_acc, v_cons.id, v_a.id, 20000, now(), v_today),
         (v_acc, v_cons.id, v_a.id, 50000, now() - interval '1 day', v_today - 1);
  v_rep := crm_inventario_cup(v_acc);
  SELECT c INTO v_card FROM jsonb_array_elements(v_rep->'cards') c WHERE c->>'name' = 'Tarjeta A';
  IF (v_card->>'used_today_cup')::numeric <> 21000 OR (v_card->>'remaining_limit_today_cup')::numeric <> 99000 THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 5.limit] %', v_card;
  ELSE RAISE NOTICE 'PASS [case 5.limit] used 21000 today (yesterday ignored), 99000 left'; END IF;
  IF cup_cuba_day('2026-01-01 03:00:00+00') <> DATE '2025-12-31' OR cup_cuba_day('2026-01-01 06:00:00+00') <> DATE '2026-01-01' THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 5.cuba] the helper is not on America/Havana';
  ELSE RAISE NOTICE 'PASS [case 5.cuba] the Cuba day rolls at midnight Havana'; END IF;
  SELECT c INTO v_card FROM jsonb_array_elements(v_rep->'cards') c WHERE c->>'name' = 'Tarjeta A';
  IF (SELECT bool_or((l->>'editable')::boolean) FROM jsonb_array_elements(v_card->'lots') l WHERE l->>'note' = 'consumido') THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 5.editable] a consumed lot is flagged editable';
  ELSE RAISE NOTICE 'PASS [case 5.editable] a consumed lot is not editable in the report'; END IF;

  -- ---- case 6: inactive cards and names -------------------------------------------------------------------------------------
  v_c := crm_guardar_tarjeta_cup(v_acc, v_c.id, NULL, NULL, NULL, NULL, false);
  v_rep := crm_inventario_cup(v_acc);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rep->'cards') c WHERE c->>'name' = 'Tarjeta C') THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 6.hidden] inactive card in the default report';
  ELSE RAISE NOTICE 'PASS [case 6.hidden] inactive card left the report'; END IF;
  v_rep := crm_inventario_cup(v_acc, true);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rep->'cards') c WHERE c->>'name' = 'Tarjeta C' AND (c->>'active')::boolean = false) THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 6.include] inactive card missing with p_include_inactive';
  ELSE RAISE NOTICE 'PASS [case 6.include] p_include_inactive lists it flagged inactive'; END IF;
  v_fail := v_fail + pg_temp.cup_expect('case 6.load on inactive', format('SELECT crm_cargar_lote_cup(%L, %L, 100, 960, NULL, NULL)', v_acc, v_c.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 6.duplicate active name', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''tarjeta a'', NULL, NULL, NULL, NULL)', v_acc), '22023');
  v_x := crm_guardar_tarjeta_cup(v_acc, NULL, 'Tarjeta C', NULL, NULL, NULL, NULL);
  RAISE NOTICE 'PASS [case 6.reuse] an inactive card''s name can be taken by a new active card';
  v_fail := v_fail + pg_temp.cup_expect('case 6.reactivate into a clash', format('SELECT crm_guardar_tarjeta_cup(%L, %L, NULL, NULL, NULL, NULL, true)', v_acc, v_c.id), '22023');

  -- ---- case 7: bad values --------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cup_expect('case 7.empty name', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''   '', NULL, NULL, NULL, NULL)', v_acc), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.last4 3 digits', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''Z1'', ''123'', NULL, NULL, NULL)', v_acc), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.last4 letters', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''Z2'', ''12ab'', NULL, NULL, NULL)', v_acc), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.limit zero', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''Z3'', NULL, NULL, 0, NULL)', v_acc), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.amount zero', format('SELECT crm_cargar_lote_cup(%L, %L, 0, 960, NULL, NULL)', v_acc, v_a.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.amount negative', format('SELECT crm_cargar_lote_cup(%L, %L, -5, 960, NULL, NULL)', v_acc, v_a.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.rate zero', format('SELECT crm_cargar_lote_cup(%L, %L, 100, 0, NULL, NULL)', v_acc, v_a.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.loaded far in the future', format('SELECT crm_cargar_lote_cup(%L, %L, 100, 960, NULL, now() + interval ''10 days'')', v_acc, v_a.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.nothing to correct', format('SELECT crm_corregir_lote_cup(%L, NULL, NULL, NULL)', v_la.id), '22023');
  v_fail := v_fail + pg_temp.cup_expect('case 7.correct rate zero', format('SELECT crm_corregir_lote_cup(%L, NULL, 0, NULL)', v_la.id), '22023');

  -- ---- case 8: roles and tenants ----------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.cup_expect('case 8.agent save card', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''Ag'', NULL, NULL, NULL, NULL)', v_acc), '42501', v_agent::text);
  v_fail := v_fail + pg_temp.cup_expect('case 8.agent load lot', format('SELECT crm_cargar_lote_cup(%L, %L, 100, 960, NULL, NULL)', v_acc, v_a.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.agent correct lot', format('SELECT crm_corregir_lote_cup(%L, 100, NULL, NULL)', v_la.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.agent delete lot', format('SELECT crm_eliminar_lote_cup(%L)', v_la.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.agent report', format('SELECT crm_inventario_cup(%L)', v_acc), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.other-account user, my account: save', format('SELECT crm_guardar_tarjeta_cup(%L, NULL, ''X'', NULL, NULL, NULL, NULL)', v_acc), '42501', v_other::text);
  v_fail := v_fail + pg_temp.cup_expect('case 8.other-account user: report', format('SELECT crm_inventario_cup(%L)', v_acc), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.other-account user: correct my lot', format('SELECT crm_corregir_lote_cup(%L, 100, NULL, NULL)', v_la.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.other-account user: delete my lot', format('SELECT crm_eliminar_lote_cup(%L)', v_la.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 8.unknown lot', format('SELECT crm_eliminar_lote_cup(%L)', gen_random_uuid()), 'P0002', v_admin::text);
  v_fail := v_fail + pg_temp.cup_expect('case 8.unknown card', format('SELECT crm_cargar_lote_cup(%L, %L, 100, 960, NULL, NULL)', v_acc, gen_random_uuid()), 'P0002');
  v_fail := v_fail + pg_temp.cup_expect('case 8.foreign card with my account id (load)', format('SELECT crm_cargar_lote_cup(%L, %L, 100, 960, NULL, NULL)', v_acc, v_foreign.id), 'P0002');
  v_fail := v_fail + pg_temp.cup_expect('case 8.foreign card with my account id (save)', format('SELECT crm_guardar_tarjeta_cup(%L, %L, ''Hijack'', NULL, NULL, NULL, NULL)', v_acc, v_foreign.id), 'P0002');
  v_fail := v_fail + pg_temp.cup_expect('case 8.admin of A on account B', format('SELECT crm_inventario_cup(%L)', v_acc2), '42501');
  v_rep := crm_inventario_cup(v_acc);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rep->'cards') c WHERE c->>'name' IN ('Foreign', 'Hijack')) THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 8.leak] a foreign card shows in my report';
  ELSE RAISE NOTICE 'PASS [case 8.leak] my report holds only my cards'; END IF;

  -- ---- case 9: no direct writes, members read their own account only ---------------------------------------------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM cup_cards;
  IF v_n <> (SELECT count(*) FROM cup_cards WHERE account_id = v_acc) OR EXISTS (SELECT 1 FROM cup_cards WHERE account_id = v_acc2) THEN
    v_fail := v_fail + 1; RAISE WARNING 'FAIL [case 9.select] a member sees another account''s cards';
  ELSE RAISE NOTICE 'PASS [case 9.select] a member reads only their account''s cards (%)', v_n; END IF;
  v_fail := v_fail + pg_temp.cup_expect('case 9.direct insert card', format('INSERT INTO cup_cards (account_id, name) VALUES (%L, ''Directa'')', v_acc), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 9.direct update card', format('UPDATE cup_cards SET daily_limit_cup = 1 WHERE id = %L', v_a.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 9.direct delete lot', format('DELETE FROM cup_lots WHERE id = %L', v_la.id), '42501');
  v_fail := v_fail + pg_temp.cup_expect('case 9.direct insert consumption', format('INSERT INTO cup_lot_consumptions (account_id, lot_id, card_id, amount_cup, cuba_day) VALUES (%L, %L, %L, 1, current_date)', v_acc, v_la.id, v_a.id), '42501');
  RESET ROLE;

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'cup-card-inventory: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE NOTICE 'cup-card-inventory: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT cup_card_inventory;
