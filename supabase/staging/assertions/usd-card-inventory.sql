\set ON_ERROR_STOP on
-- usd-card-inventory.sql -- self-reverting assertion for 355_usd_card_inventory.sql
--
-- STATUS: written BEFORE the migration (strict TDD). NOT RUN YET: the RED/GREEN runs happen in T6 on staging.
--
-- Proves the Clasica/Tropical USD inventory (odd/tasks/usd-card-inventory.md, T1):
--   case 1   cards per service: Clasica and Tropical cards, default monthly limit 5000, priority counted PER SERVICE, name trimmed
--   case 2   unique ACTIVE name per account + service (case-insensitive); the same name on the other service is fine
--   case 3   the service is immutable after creation; a NULL argument keeps the stored value; last4 '' clears it; reorder works
--   case 4   lot load stores usd_per_usdt = amount_usd / usdt_paid (500 / 476.19 to 6 decimals; 1x1 = 1); report balance, limit,
--            0 used this month, lots FIFO by loaded_at
--   case 5   correct / delete only while untouched (remaining = amount and no consumption rows); correcting recomputes the rate
--   case 6   usd_cuba_month rolls at midnight Havana; this month's consumptions count, last month's do not
--   case 7   crm_ajustar_saldo_usd: lower = FIFO positive 'ajuste' rows, higher = newest-first negative rows, no-op, refusals,
--            audit row; adjustments never count as month usage
--   case 8   report: inactive cards only with p_include_inactive, per-service totals, all lots listed (agotado flag)
--   case 9   bad values refused (22023); inactive card cannot take a lot
--   case 10  roles and tenants: agent / viewer / other-account admin 42501 on every RPC; unknown ids P0002
--   case 11  direct writes by role authenticated refused, members read only their account, no anon EXECUTE, no PUBLIC EXECUTE
--
-- Run it as: BEGIN; \i 355_usd_card_inventory.sql \i this file; ROLLBACK;   (STAGING only; never COMMIT; never production)
-- It always ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)' and builds its own fixtures.

CREATE FUNCTION pg_temp.uci_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.uci_chk(p_label text, p_ok boolean, p_detail text DEFAULT '') RETURNS integer LANGUAGE plpgsql AS $f$
BEGIN
  IF p_ok IS TRUE THEN RAISE NOTICE 'PASS [%]', p_label; RETURN 0; END IF;
  RAISE WARNING 'FAIL [%] %', p_label, p_detail; RETURN 1;
END $f$;

-- Runs a statement as p_uid and returns true when it fails with exactly p_state.
CREATE FUNCTION pg_temp.uci_expect(p_sql text, p_state text, p_uid uuid) RETURNS boolean LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.uci_claims(p_uid);
  BEGIN
    EXECUTE p_sql;
    PERFORM pg_temp.uci_claims(NULL);
    RETURN false;
  EXCEPTION WHEN OTHERS THEN
    PERFORM pg_temp.uci_claims(NULL);
    RETURN SQLSTATE = p_state;
  END;
END $f$;

-- One card of the report, as a given user.
CREATE FUNCTION pg_temp.uci_card(p_acct uuid, p_card uuid, p_uid uuid, p_inactive boolean DEFAULT false) RETURNS jsonb LANGUAGE plpgsql AS $f$
DECLARE v jsonb;
BEGIN
  PERFORM pg_temp.uci_claims(p_uid);
  v := crm_inventario_usd(p_acct, p_inactive);
  PERFORM pg_temp.uci_claims(NULL);
  RETURN (SELECT c FROM jsonb_array_elements(v->'cards') c WHERE (c->>'id')::uuid = p_card);
END $f$;

CREATE FUNCTION pg_temp.uci_lot(p_card jsonb, p_lot uuid) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT l FROM jsonb_array_elements(p_card->'lots') l WHERE (l->>'id')::uuid = p_lot;
$f$;

DO $$
DECLARE
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid(); v_viewer uuid := gen_random_uuid();
  v_owner2 uuid := gen_random_uuid(); v_admin2 uuid := gen_random_uuid();
  v_hash CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc uuid; v_acc2 uuid; v_month date;
  v_cla usd_cards; v_cla2 usd_cards; v_tro usd_cards; v_tro2 usd_cards; v_foreign usd_cards; v_x usd_cards;
  v_l1 usd_lots; v_l2 usd_lots; v_l3 usd_lots; v_lt usd_lots; v_cons usd_lots; v_del usd_lots; v_r2 usd_lots;
  v_r jsonb; v_card jsonb; v_lot jsonb; v_cnt integer; v_audn integer; v_aud record;
  v_n numeric;
  v_fail integer := 0;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'usd-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_viewer, v_owner2, v_admin2]) AS u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'usd inventory test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'usd inventory other account', v_owner2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'usd owner', 'usd-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'usd admin', 'usd-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'usd agent', 'usd-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_viewer, 'usd viewer', 'usd-' || v_viewer || '@test.invalid', v_acc, 'viewer'),
    (gen_random_uuid(), v_owner2, 'usd owner 2', 'usd-' || v_owner2 || '@test.invalid', v_acc2, 'owner'),
    (gen_random_uuid(), v_admin2, 'usd admin 2', 'usd-' || v_admin2 || '@test.invalid', v_acc2, 'admin');
  v_month := usd_cuba_month(now());

  PERFORM pg_temp.uci_claims(v_admin2);
  v_foreign := crm_guardar_tarjeta_usd(v_acc2, NULL, 'CLASICA', 'Foreign', NULL, NULL, NULL, NULL);
  PERFORM pg_temp.uci_claims(v_admin);

  -- ---- case 1: cards per service ---------------------------------------------------------------------------------------
  v_cla := crm_guardar_tarjeta_usd(v_acc, NULL, 'CLASICA', '  Clasica Banco  ', '1234', NULL, NULL, NULL);
  v_tro := crm_guardar_tarjeta_usd(v_acc, NULL, 'TROPICAL', 'Tropical Banco', NULL, NULL, NULL, NULL);
  v_cla2 := crm_guardar_tarjeta_usd(v_acc, NULL, 'CLASICA', 'Clasica Dos', NULL, NULL, NULL, NULL);
  v_tro2 := crm_guardar_tarjeta_usd(v_acc, NULL, 'TROPICAL', 'Tropical Dos', NULL, 3, 2500, NULL);
  v_fail := v_fail + pg_temp.uci_chk('case 1.defaults', v_cla.service = 'CLASICA' AND v_cla.name = 'Clasica Banco' AND v_cla.last4 = '1234'
    AND v_cla.monthly_limit_usd = 5000 AND v_cla.active AND v_cla.priority = 1, row_to_json(v_cla)::text);
  v_fail := v_fail + pg_temp.uci_chk('case 1.priority per service', v_tro.priority = 1 AND v_cla2.priority = 2 AND v_tro2.priority = 3,
    format('tro %s cla2 %s tro2 %s', v_tro.priority, v_cla2.priority, v_tro2.priority));
  v_fail := v_fail + pg_temp.uci_chk('case 1.explicit limit', v_tro2.monthly_limit_usd = 2500, row_to_json(v_tro2)::text);

  -- ---- case 2: unique active name per account + service ----------------------------------------------------------------
  v_fail := v_fail + pg_temp.uci_chk('case 2.duplicate same service (case-insensitive)',
    pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''clasica banco'', NULL, NULL, NULL, NULL)', v_acc), '22023', v_admin), '');
  v_x := crm_guardar_tarjeta_usd(v_acc, NULL, 'TROPICAL', 'Clasica Banco', NULL, NULL, NULL, NULL);
  v_fail := v_fail + pg_temp.uci_chk('case 2.same name other service allowed', v_x.service = 'TROPICAL' AND v_x.name = 'Clasica Banco', row_to_json(v_x)::text);
  v_x := crm_guardar_tarjeta_usd(v_acc, v_x.id, NULL, NULL, NULL, NULL, NULL, false);
  v_x := crm_guardar_tarjeta_usd(v_acc, NULL, 'TROPICAL', 'Clasica Banco', NULL, NULL, NULL, NULL);
  v_fail := v_fail + pg_temp.uci_chk('case 2.inactive name can be reused', v_x.active, row_to_json(v_x)::text);
  v_fail := v_fail + pg_temp.uci_chk('case 2.rename into a clash',
    pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, %L, NULL, ''Clasica Banco'', NULL, NULL, NULL, NULL)', v_acc, v_tro.id), '22023', v_admin), '');
  v_x := crm_guardar_tarjeta_usd(v_acc, v_x.id, NULL, NULL, NULL, NULL, NULL, false);

  -- ---- case 3: service immutability, partial update, reorder -------------------------------------------------------------
  v_fail := v_fail + pg_temp.uci_chk('case 3.service cannot change',
    pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, %L, ''TROPICAL'', NULL, NULL, NULL, NULL, NULL)', v_acc, v_cla.id), '22023', v_admin), '');
  v_x := crm_guardar_tarjeta_usd(v_acc, v_cla.id, 'CLASICA', NULL, '', NULL, 4000, NULL);
  v_fail := v_fail + pg_temp.uci_chk('case 3.same service ok, last4 cleared, limit set, name kept',
    v_x.last4 IS NULL AND v_x.monthly_limit_usd = 4000 AND v_x.name = 'Clasica Banco' AND v_x.service = 'CLASICA' AND v_x.priority = 1, row_to_json(v_x)::text);
  v_cla := crm_guardar_tarjeta_usd(v_acc, v_cla.id, NULL, NULL, NULL, NULL, 5000, NULL);
  v_cla2 := crm_guardar_tarjeta_usd(v_acc, v_cla2.id, NULL, NULL, NULL, 0, NULL, NULL);
  v_r := crm_inventario_usd(v_acc);
  v_fail := v_fail + pg_temp.uci_chk('case 3.reorder puts Clasica Dos first in its service',
    (SELECT c->>'name' FROM jsonb_array_elements(v_r->'cards') c WHERE c->>'service' = 'CLASICA' ORDER BY (c->>'priority')::int, c->>'name' LIMIT 1) = 'Clasica Dos',
    v_r::text);

  -- ---- case 4: lot load, rate, report ------------------------------------------------------------------------------------
  v_l1 := crm_cargar_lote_usd(v_acc, v_cla.id, 500, 476.19, now() - interval '2 hours', 'cinco por ciento');
  v_fail := v_fail + pg_temp.uci_chk('case 4.usd_per_usdt = amount / paid',
    v_l1.amount_usd = 500 AND v_l1.remaining_usd = 500 AND v_l1.usdt_paid = 476.19
    AND abs(v_l1.usd_per_usdt - 500 / 476.19) < 0.000001 AND round(v_l1.usd_per_usdt, 4) = 1.0500, row_to_json(v_l1)::text);
  v_l2 := crm_cargar_lote_usd(v_acc, v_cla.id, 300, 300, now() - interval '3 hours', '1x1');
  v_fail := v_fail + pg_temp.uci_chk('case 4.one by one lot rate is 1', v_l2.usd_per_usdt = 1, row_to_json(v_l2)::text);
  v_card := pg_temp.uci_card(v_acc, v_cla.id, v_admin);
  v_fail := v_fail + pg_temp.uci_chk('case 4.report card fields',
    v_card->>'service' = 'CLASICA' AND v_card->>'name' = 'Clasica Banco' AND (v_card->>'balance_usd')::numeric = 800
    AND (v_card->>'monthly_limit_usd')::numeric = 5000 AND (v_card->>'used_this_month_usd')::numeric = 0
    AND (v_card->>'remaining_month_usd')::numeric = 5000, v_card::text);
  v_fail := v_fail + pg_temp.uci_chk('case 4.lots FIFO by loaded_at',
    (v_card->'lots'->0->>'note') = '1x1' AND (v_card->'lots'->1->>'note') = 'cinco por ciento'
    AND (v_card->'lots'->1->>'usdt_paid')::numeric = 476.19 AND (v_card->'lots'->1->>'amount_usd')::numeric = 500
    AND (v_card->'lots'->1->>'editable')::boolean, (v_card->'lots')::text);
  v_fail := v_fail + pg_temp.uci_chk('case 4.report has the Cuba month', (crm_inventario_usd(v_acc)->>'cuba_month')::date = v_month, '');

  -- ---- case 5: correct / delete only while untouched ------------------------------------------------------------------------
  v_l3 := crm_cargar_lote_usd(v_acc, v_cla2.id, 1000, 1000, NULL, 'a corregir');
  v_l3 := crm_corregir_lote_usd(v_l3.id, 1000, 952.38, NULL);
  v_fail := v_fail + pg_temp.uci_chk('case 4.loaded_at defaults to now', v_l3.loaded_at > now() - interval '1 minute', row_to_json(v_l3)::text);
  v_fail := v_fail + pg_temp.uci_chk('case 5.correct recomputes the rate and keeps the note',
    v_l3.usdt_paid = 952.38 AND v_l3.remaining_usd = 1000 AND abs(v_l3.usd_per_usdt - 1000 / 952.38) < 0.000001 AND v_l3.note = 'a corregir', row_to_json(v_l3)::text);
  v_l3 := crm_corregir_lote_usd(v_l3.id, 800, NULL, '');
  v_fail := v_fail + pg_temp.uci_chk('case 5.amount change moves remaining, note cleared, paid kept',
    v_l3.amount_usd = 800 AND v_l3.remaining_usd = 800 AND v_l3.usdt_paid = 952.38 AND v_l3.note IS NULL
    AND abs(v_l3.usd_per_usdt - 800 / 952.38) < 0.000001, row_to_json(v_l3)::text);
  v_cons := crm_cargar_lote_usd(v_acc, v_cla2.id, 2000, 2000, NULL, 'consumido');
  INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, consumed_at, cuba_month, kind)
  VALUES (v_acc, v_cons.id, v_cla2.id, 10, now(), v_month, 'operacion');
  UPDATE usd_lots SET remaining_usd = 1990 WHERE id = v_cons.id;
  v_fail := v_fail + pg_temp.uci_chk('case 5.consumed lot cannot be corrected',
    pg_temp.uci_expect(format('SELECT crm_corregir_lote_usd(%L, 5000, NULL, NULL)', v_cons.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 5.consumed lot cannot be deleted',
    pg_temp.uci_expect(format('SELECT crm_eliminar_lote_usd(%L)', v_cons.id), '22023', v_admin), '');
  v_del := crm_cargar_lote_usd(v_acc, v_cla2.id, 77, 77, NULL, 'borrable');
  PERFORM crm_eliminar_lote_usd(v_del.id);
  v_fail := v_fail + pg_temp.uci_chk('case 5.untouched lot deleted', NOT EXISTS (SELECT 1 FROM usd_lots WHERE id = v_del.id), '');
  v_fail := v_fail + pg_temp.uci_chk('case 5.nothing to correct',
    pg_temp.uci_expect(format('SELECT crm_corregir_lote_usd(%L, NULL, NULL, NULL)', v_l3.id), '22023', v_admin), '');

  -- ---- case 6: Cuba month and month usage ---------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.uci_chk('case 6.month rolls at midnight Havana',
    usd_cuba_month('2026-01-01 03:00:00+00') = DATE '2025-12-01' AND usd_cuba_month('2026-01-01 06:00:00+00') = DATE '2026-01-01'
    AND usd_cuba_month('2026-02-01 03:00:00+00') = DATE '2026-01-01', '');
  INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, consumed_at, cuba_month, kind)
  VALUES (v_acc, v_l1.id, v_cla.id, 100, now(), v_month, 'operacion'),
         (v_acc, v_l1.id, v_cla.id, 25, now(), v_month, 'manual'),
         (v_acc, v_l2.id, v_cla.id, 900, now() - interval '40 days', usd_cuba_month(now() - interval '40 days'), 'operacion');
  UPDATE usd_lots SET remaining_usd = remaining_usd - 125 WHERE id = v_l1.id;
  UPDATE usd_lots SET remaining_usd = remaining_usd - 0 WHERE id = v_l2.id;
  v_card := pg_temp.uci_card(v_acc, v_cla.id, v_admin);
  v_fail := v_fail + pg_temp.uci_chk('case 6.used this month counts operation and manual, not last month',
    (v_card->>'used_this_month_usd')::numeric = 125 AND (v_card->>'remaining_month_usd')::numeric = 4875
    AND (v_card->>'balance_usd')::numeric = 675, v_card::text);
  v_lot := pg_temp.uci_lot(v_card, v_l1.id);
  v_fail := v_fail + pg_temp.uci_chk('case 6.touched lot is not editable', NOT (v_lot->>'editable')::boolean AND (v_lot->>'remaining_usd')::numeric = 375, v_lot::text);

  -- ---- case 7: balance adjustment -------------------------------------------------------------------------------------------------
  -- balance now 675 = L2 300 + L1 375 (FIFO: L2 loaded 3h ago comes first, L1 2h ago second)
  SELECT count(*) INTO v_audn FROM remittance_admin_audit WHERE row_id = v_cla.id AND field_name = 'balance_usd';
  PERFORM pg_temp.uci_claims(v_admin);
  v_r := crm_ajustar_saldo_usd(v_cla.id, 600, 'conteo fisico');
  PERFORM pg_temp.uci_claims(NULL);
  SELECT * INTO v_l2 FROM usd_lots WHERE id = v_l2.id;
  SELECT * INTO v_l1 FROM usd_lots WHERE id = v_l1.id;
  v_fail := v_fail + pg_temp.uci_chk('case 7.lower takes FIFO (oldest loaded first)',
    (v_r->>'saldo_anterior')::numeric = 675 AND (v_r->>'saldo_nuevo')::numeric = 600 AND v_l2.remaining_usd = 225 AND v_l1.remaining_usd = 375
    AND jsonb_array_length(v_r->'movimientos') = 1 AND (v_r->'movimientos'->0->>'amount_usd')::numeric = 75, v_r::text);
  SELECT count(*), coalesce(sum(amount_usd), 0) INTO v_cnt, v_n FROM usd_lot_consumptions WHERE card_id = v_cla.id AND kind = 'ajuste';
  v_fail := v_fail + pg_temp.uci_chk('case 7.lower wrote one positive ajuste row', v_cnt = 1 AND v_n = 75, format('%s rows, sum %s', v_cnt, v_n));
  SELECT * INTO v_aud FROM remittance_admin_audit WHERE row_id = v_cla.id AND field_name = 'balance_usd' ORDER BY created_at DESC LIMIT 1;
  v_fail := v_fail + pg_temp.uci_chk('case 7.audit row',
    (SELECT count(*) FROM remittance_admin_audit WHERE row_id = v_cla.id AND field_name = 'balance_usd') = v_audn + 1
    AND v_aud.table_name = 'usd_cards' AND v_aud.action = 'human_correction' AND v_aud.reason = 'conteo fisico' AND v_aud.account_id = v_acc, coalesce(row_to_json(v_aud)::text, 'no audit row'));
  v_card := pg_temp.uci_card(v_acc, v_cla.id, v_admin);
  v_fail := v_fail + pg_temp.uci_chk('case 7.adjustment is not month usage',
    (v_card->>'used_this_month_usd')::numeric = 125 AND (v_card->>'remaining_month_usd')::numeric = 4875 AND (v_card->>'balance_usd')::numeric = 600, v_card::text);

  -- lower across lots: 600 -> 300 takes 225 from L2 (emptied) then 75 from L1
  PERFORM pg_temp.uci_claims(v_admin);
  v_r := crm_ajustar_saldo_usd(v_cla.id, 300, NULL);
  PERFORM pg_temp.uci_claims(NULL);
  SELECT * INTO v_l2 FROM usd_lots WHERE id = v_l2.id;
  SELECT * INTO v_l1 FROM usd_lots WHERE id = v_l1.id;
  v_fail := v_fail + pg_temp.uci_chk('case 7.lower across lots', v_l2.remaining_usd = 0 AND v_l1.remaining_usd = 300 AND jsonb_array_length(v_r->'movimientos') = 2, v_r::text);

  -- higher: 300 -> 500 gives back newest-first (L1 loaded later: up to its amount - remaining = 200), as a NEGATIVE row
  PERFORM pg_temp.uci_claims(v_admin);
  v_r := crm_ajustar_saldo_usd(v_cla.id, 500, 'reposicion');
  PERFORM pg_temp.uci_claims(NULL);
  SELECT * INTO v_l2 FROM usd_lots WHERE id = v_l2.id;
  SELECT * INTO v_l1 FROM usd_lots WHERE id = v_l1.id;
  v_fail := v_fail + pg_temp.uci_chk('case 7.higher gives back newest first, negative row',
    v_l1.remaining_usd = 500 AND v_l2.remaining_usd = 0 AND (v_r->'movimientos'->0->>'amount_usd')::numeric = -200
    AND EXISTS (SELECT 1 FROM usd_lot_consumptions WHERE lot_id = v_l1.id AND kind = 'ajuste' AND amount_usd = -200), v_r::text);

  SELECT count(*) INTO v_cnt FROM usd_lot_consumptions WHERE card_id = v_cla.id;
  PERFORM pg_temp.uci_claims(v_admin);
  v_r := crm_ajustar_saldo_usd(v_cla.id, 500, 'igual');
  PERFORM pg_temp.uci_claims(NULL);
  v_fail := v_fail + pg_temp.uci_chk('case 7.equal is a no-op (no rows)',
    jsonb_array_length(v_r->'movimientos') = 0 AND (SELECT count(*) FROM usd_lot_consumptions WHERE card_id = v_cla.id) = v_cnt, v_r::text);
  v_fail := v_fail + pg_temp.uci_chk('case 7.above the loaded total refused',
    pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, 99999, NULL)', v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.negative refused',
    pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, -1, NULL)', v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.NULL refused',
    pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, NULL, NULL)', v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.reason too long refused',
    pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, 400, %L)', v_cla.id, repeat('x', 501)), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.agent refused',
    pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, 400, NULL)', v_cla.id), '42501', v_agent), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.unknown card',
    pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, 400, NULL)', gen_random_uuid()), 'P0002', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.ajuste row must carry no operation / entry reference (CHECK)',
    pg_temp.uci_expect(format('INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, cuba_month, kind, operation_id) VALUES (%L, %L, %L, 1, %L, ''ajuste'', gen_random_uuid())',
      v_acc, v_l1.id, v_cla.id, v_month), '23514', NULL), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.non-ajuste row cannot be negative',
    pg_temp.uci_expect(format('INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, cuba_month, kind) VALUES (%L, %L, %L, -1, %L, ''operacion'')',
      v_acc, v_l1.id, v_cla.id, v_month), '23514', NULL), '');
  v_fail := v_fail + pg_temp.uci_chk('case 7.unknown kind refused',
    pg_temp.uci_expect(format('INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, cuba_month, kind) VALUES (%L, %L, %L, 1, %L, ''otro'')',
      v_acc, v_l1.id, v_cla.id, v_month), '23514', NULL), '');

  -- ---- case 8: inactive cards, totals, all lots -------------------------------------------------------------------------------------
  v_lt := crm_cargar_lote_usd(v_acc, v_tro.id, 1000, 952.38, NULL, 'tropical');
  v_tro2 := crm_guardar_tarjeta_usd(v_acc, v_tro2.id, NULL, NULL, NULL, NULL, NULL, false);
  v_r := crm_inventario_usd(v_acc);
  v_fail := v_fail + pg_temp.uci_chk('case 8.inactive hidden by default', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'cards') c WHERE c->>'name' = 'Tropical Dos'), v_r::text);
  v_r := crm_inventario_usd(v_acc, true);
  v_fail := v_fail + pg_temp.uci_chk('case 8.p_include_inactive lists it flagged',
    EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'cards') c WHERE c->>'name' = 'Tropical Dos' AND NOT (c->>'active')::boolean), '');
  v_r := crm_inventario_usd(v_acc);
  v_fail := v_fail + pg_temp.uci_chk('case 8.service totals match the cards and the lots',
    (v_r->'totals'->'CLASICA'->>'balance_usd')::numeric = (SELECT sum((c->>'balance_usd')::numeric) FROM jsonb_array_elements(v_r->'cards') c WHERE c->>'service' = 'CLASICA')
    AND (v_r->'totals'->'CLASICA'->>'balance_usd')::numeric = (SELECT coalesce(sum(remaining_usd), 0) FROM usd_lots WHERE card_id IN (v_cla.id, v_cla2.id))
    AND (v_r->'totals'->'CLASICA'->>'cards')::int = 2 AND (v_r->'totals'->'TROPICAL'->>'cards')::int = 1, v_r::text);
  v_fail := v_fail + pg_temp.uci_chk('case 8.totals: tropical balance, limit and usage',
    (v_r->'totals'->'TROPICAL'->>'balance_usd')::numeric = 1000 AND (v_r->'totals'->'TROPICAL'->>'used_this_month_usd')::numeric = 0
    AND (v_r->'totals'->'CLASICA'->>'used_this_month_usd')::numeric = 135
    AND (v_r->'totals'->'CLASICA'->>'monthly_limit_usd')::numeric = (SELECT sum(monthly_limit_usd) FROM usd_cards WHERE account_id = v_acc AND active AND service = 'CLASICA'), v_r::text);
  v_card := pg_temp.uci_card(v_acc, v_cla.id, v_admin);
  v_lot := pg_temp.uci_lot(v_card, v_l2.id);
  v_fail := v_fail + pg_temp.uci_chk('case 8.used-up lot still listed, agotado, adjusted, not editable',
    v_lot IS NOT NULL AND (v_lot->>'agotado')::boolean AND (v_lot->>'adjusted')::boolean AND NOT (v_lot->>'editable')::boolean, coalesce(v_lot::text, 'lot missing'));
  v_fail := v_fail + pg_temp.uci_chk('case 8.consumptions listed with kind and reason',
    jsonb_array_length(v_card->'consumptions_month') >= 3
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_card->'consumptions_month') m WHERE m->>'kind' = 'ajuste' AND m->>'reason' = 'conteo fisico')
    AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_card->'consumptions_month') m WHERE m->>'kind' = 'manual'), (v_card->'consumptions_month')::text);

  -- ---- case 9: bad values ------------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.uci_chk('case 9.empty name', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''   '', NULL, NULL, NULL, NULL)', v_acc), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.missing service on create', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, NULL, ''Z0'', NULL, NULL, NULL, NULL)', v_acc), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.unknown service', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''ZELLE'', ''Z1'', NULL, NULL, NULL, NULL)', v_acc), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.last4 3 digits', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''Z2'', ''123'', NULL, NULL, NULL)', v_acc), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.limit zero', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''Z3'', NULL, NULL, 0, NULL)', v_acc), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.priority out of range', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''Z4'', NULL, -1, NULL, NULL)', v_acc), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.amount zero', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 0, 10, NULL, NULL)', v_acc, v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.amount negative', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, -5, 10, NULL, NULL)', v_acc, v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.usdt_paid zero', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 0, NULL, NULL)', v_acc, v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.usdt_paid NULL', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, NULL, NULL, NULL)', v_acc, v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.loaded far in the future', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, now() + interval ''10 days'', NULL)', v_acc, v_cla.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.note too long', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, NULL, %L)', v_acc, v_cla.id, repeat('n', 501)), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.load on inactive card', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, NULL, NULL)', v_acc, v_tro2.id), '22023', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 9.correct rate input zero', pg_temp.uci_expect(format('SELECT crm_corregir_lote_usd(%L, NULL, 0, NULL)', v_lt.id), '22023', v_admin), '');

  -- ---- case 10: roles and tenants ------------------------------------------------------------------------------------------------------
  v_fail := v_fail + pg_temp.uci_chk('case 10.agent save card', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''Ag'', NULL, NULL, NULL, NULL)', v_acc), '42501', v_agent), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.viewer save card', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''Vw'', NULL, NULL, NULL, NULL)', v_acc), '42501', v_viewer), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.agent load lot', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, NULL, NULL)', v_acc, v_cla.id), '42501', v_agent), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.viewer load lot', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, NULL, NULL)', v_acc, v_cla.id), '42501', v_viewer), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.agent correct lot', pg_temp.uci_expect(format('SELECT crm_corregir_lote_usd(%L, 100, NULL, NULL)', v_lt.id), '42501', v_agent), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.agent delete lot', pg_temp.uci_expect(format('SELECT crm_eliminar_lote_usd(%L)', v_lt.id), '42501', v_agent), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.viewer delete lot', pg_temp.uci_expect(format('SELECT crm_eliminar_lote_usd(%L)', v_lt.id), '42501', v_viewer), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.agent report', pg_temp.uci_expect(format('SELECT crm_inventario_usd(%L)', v_acc), '42501', v_agent), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.viewer report', pg_temp.uci_expect(format('SELECT crm_inventario_usd(%L)', v_acc), '42501', v_viewer), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.other-account admin: report on my account', pg_temp.uci_expect(format('SELECT crm_inventario_usd(%L)', v_acc), '42501', v_admin2), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.other-account admin: save', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, NULL, ''CLASICA'', ''X'', NULL, NULL, NULL, NULL)', v_acc), '42501', v_admin2), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.other-account admin: correct my lot', pg_temp.uci_expect(format('SELECT crm_corregir_lote_usd(%L, 100, NULL, NULL)', v_lt.id), '42501', v_admin2), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.other-account admin: adjust my card', pg_temp.uci_expect(format('SELECT crm_ajustar_saldo_usd(%L, 1, NULL)', v_cla.id), '42501', v_admin2), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.anonymous refused', pg_temp.uci_expect(format('SELECT crm_inventario_usd(%L)', v_acc), '42501', NULL), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.unknown lot', pg_temp.uci_expect(format('SELECT crm_eliminar_lote_usd(%L)', gen_random_uuid()), 'P0002', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.unknown card on load', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, NULL, NULL)', v_acc, gen_random_uuid()), 'P0002', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.foreign card with my account id (load)', pg_temp.uci_expect(format('SELECT crm_cargar_lote_usd(%L, %L, 100, 100, NULL, NULL)', v_acc, v_foreign.id), 'P0002', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 10.foreign card with my account id (save)', pg_temp.uci_expect(format('SELECT crm_guardar_tarjeta_usd(%L, %L, NULL, ''Hijack'', NULL, NULL, NULL, NULL)', v_acc, v_foreign.id), 'P0002', v_admin), '');
  v_r := crm_inventario_usd(v_acc);
  v_fail := v_fail + pg_temp.uci_chk('case 10.no leak of the foreign card', NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'cards') c WHERE c->>'name' IN ('Foreign', 'Hijack')), '');

  -- ---- case 11: no direct writes, members read their own account only, grants ------------------------------------------------------------
  PERFORM pg_temp.uci_claims(v_admin);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_cnt FROM usd_cards;
  v_fail := v_fail + pg_temp.uci_chk('case 11.member reads only their account',
    v_cnt = (SELECT count(*) FROM usd_cards WHERE account_id = v_acc) AND NOT EXISTS (SELECT 1 FROM usd_cards WHERE account_id = v_acc2), format('%s cards', v_cnt));
  v_fail := v_fail + pg_temp.uci_chk('case 11.direct insert card', pg_temp.uci_expect(format('INSERT INTO usd_cards (account_id, service, name) VALUES (%L, ''CLASICA'', ''Directa'')', v_acc), '42501', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 11.direct update card', pg_temp.uci_expect(format('UPDATE usd_cards SET monthly_limit_usd = 1 WHERE id = %L', v_cla.id), '42501', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 11.direct delete lot', pg_temp.uci_expect(format('DELETE FROM usd_lots WHERE id = %L', v_lt.id), '42501', v_admin), '');
  v_fail := v_fail + pg_temp.uci_chk('case 11.direct insert consumption', pg_temp.uci_expect(format('INSERT INTO usd_lot_consumptions (account_id, lot_id, card_id, amount_usd, cuba_month) VALUES (%L, %L, %L, 1, current_date)', v_acc, v_lt.id, v_tro.id), '42501', v_admin), '');
  RESET ROLE;
  PERFORM pg_temp.uci_claims(NULL);

  v_fail := v_fail + pg_temp.uci_chk('case 11.RLS enabled on all three tables',
    (SELECT count(*) FROM pg_class WHERE oid IN ('public.usd_cards'::regclass, 'public.usd_lots'::regclass, 'public.usd_lot_consumptions'::regclass) AND relrowsecurity) = 3, '');
  v_fail := v_fail + pg_temp.uci_chk('case 11.anon has no table access',
    NOT has_table_privilege('anon', 'public.usd_cards', 'SELECT') AND NOT has_table_privilege('anon', 'public.usd_lots', 'SELECT')
    AND NOT has_table_privilege('anon', 'public.usd_lot_consumptions', 'SELECT'), '');
  v_fail := v_fail + pg_temp.uci_chk('case 11.authenticated cannot write tables',
    NOT has_table_privilege('authenticated', 'public.usd_cards', 'INSERT') AND NOT has_table_privilege('authenticated', 'public.usd_lots', 'UPDATE')
    AND NOT has_table_privilege('authenticated', 'public.usd_lot_consumptions', 'DELETE') AND has_table_privilege('authenticated', 'public.usd_lots', 'SELECT'), '');
  v_fail := v_fail + pg_temp.uci_chk('case 11.EXECUTE: authenticated yes, anon no',
    has_function_privilege('authenticated', 'public.crm_guardar_tarjeta_usd(uuid, uuid, text, text, text, integer, numeric, boolean)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_cargar_lote_usd(uuid, uuid, numeric, numeric, timestamptz, text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_corregir_lote_usd(uuid, numeric, numeric, text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_eliminar_lote_usd(uuid)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_ajustar_saldo_usd(uuid, numeric, text)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.crm_inventario_usd(uuid, boolean)', 'EXECUTE')
    AND has_function_privilege('authenticated', 'public.usd_cuba_month(timestamptz)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_guardar_tarjeta_usd(uuid, uuid, text, text, text, integer, numeric, boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_cargar_lote_usd(uuid, uuid, numeric, numeric, timestamptz, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_corregir_lote_usd(uuid, numeric, numeric, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_eliminar_lote_usd(uuid)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_ajustar_saldo_usd(uuid, numeric, text)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.crm_inventario_usd(uuid, boolean)', 'EXECUTE')
    AND NOT has_function_privilege('anon', 'public.usd_cuba_month(timestamptz)', 'EXECUTE'), '');

  IF v_fail > 0 THEN
    RAISE EXCEPTION 'usd-card-inventory: % expectation(s) FAILED -- see WARNINGs above', v_fail;
  END IF;
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
