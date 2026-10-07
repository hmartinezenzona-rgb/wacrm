\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 227 (the weekly cut: "Limpiar todo" archives the week and keeps the history). Self-reverting:
-- BEGIN ... ROLLBACK is in this file; any failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so nothing is
-- kept). Each passing case NOTICEs. Runs on staging (production after the owner's go-ahead). Builds its own data.
--
-- odd/tasks/calculator-delete-and-weekly-clear.md (T2). crm_cerrar_semana_calculadora archives the Calculator week (the
-- manual text and period label the client holds, the manual totals the client computed, the chat totals computed here
-- from the entries shown, a snapshot of those entries), records the cut and empties the manual document. The Calculator
-- reads calculator_current_entries (a view): no completed entry that was archived, every pending one, every entry
-- completed after the cut. Nothing in remittance_calculator_entries changes, so Finanzas, the dashboard and the closes
-- give EXACTLY the same numbers before and after.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t227_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

-- completes a fresh operation of the account and returns its id
CREATE FUNCTION pg_temp.t227_complete(p_acc uuid, p_conv uuid, p_agent uuid, p_amount numeric, p_service text DEFAULT 'remesa',
                                      p_dm text DEFAULT 'zelle') RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acc, p_conv, 'ready_to_transfer', p_service, 'GYD', p_amount, p_dm) RETURNING id INTO v_op;
  PERFORM pg_temp.t227_claims(p_agent);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM pg_temp.t227_claims(NULL);
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t227_side(p_acc uuid) RETURNS bigint LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id WHERE c.account_id = p_acc)
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id WHERE c.account_id = p_acc)
       + (SELECT count(*) FROM notifications n WHERE n.account_id = p_acc);
$f$;

CREATE FUNCTION pg_temp.t227_cut(p_uid uuid, p_acc uuid, p_text text, p_period text, p_f numeric, p_i numeric, p_r numeric)
RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t227_claims(p_uid);
  PERFORM crm_cerrar_semana_calculadora(p_acc, p_text, p_period, p_f, p_i, p_r);
  PERFORM pg_temp.t227_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t227_claims(NULL);
  RETURN SQLSTATE;
END $f$;

CREATE FUNCTION pg_temp.t227_visible(p_acc uuid) RETURNS text LANGUAGE sql AS $f$
  SELECT coalesce(string_agg(operation_id::text || ':' || status, ',' ORDER BY operation_id::text), '')
    FROM calculator_current_entries WHERE account_id = p_acc;
$f$;

DO $$
DECLARE
  v_dummy constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid();
  v_viewer uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_acc uuid; v_acc2 uuid; v_ct uuid; v_conv uuid; v_ct2 uuid; v_conv2 uuid;
  v_op1 uuid; v_op2 uuid; v_op3 uuid; v_opp uuid; v_opv uuid; v_opo uuid;
  v_e1 uuid; v_e2 uuid; v_e3 uuid; v_ep uuid; v_ev uuid;
  v_day date := (now() AT TIME ZONE 'America/Guyana')::date;
  v_close0 jsonb; v_close1 jsonb;
  v_w remittance_calculator_weeks; v_w2 remittance_calculator_weeks; v_doc remittance_calculator_documents;
  v_before_rows jsonb; v_n int; v_side bigint; v_res text; v_vis text; v_cut1 timestamptz;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'cwc-' || u || '@test.invalid', v_dummy, now(), now(), now(), '{}', '{}', false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_viewer, v_other]) u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cwc test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'cwc other account', v_other) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'cwc owner', 'cwc-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'cwc admin', 'cwc-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'cwc agent', 'cwc-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_viewer, 'cwc viewer', 'cwc-' || v_viewer || '@test.invalid', v_acc, 'viewer'),
    (gen_random_uuid(), v_other, 'cwc other', 'cwc-' || v_other || '@test.invalid', v_acc2, 'owner');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '59902270001', v_acc, 'Cliente CWC') RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_other, '59902270002', v_acc2, 'Cliente CWC2') RETURNING id INTO v_ct2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_other, v_ct2, v_acc2) RETURNING id INTO v_conv2;
  PERFORM pg_temp.t227_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 400));
  PERFORM pg_temp.t227_claims(v_other);
  PERFORM crm_set_calculator_rates(v_acc2, jsonb_build_object('cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 400));
  PERFORM pg_temp.t227_claims(NULL);

  -- E1, E2 completed; a pending one (no sell rate when it was fed); a reverted void one; another account's line
  v_op1 := pg_temp.t227_complete(v_acc, v_conv, v_agent, 26000);
  v_op2 := pg_temp.t227_complete(v_acc, v_conv, v_agent, 13000);
  SELECT id INTO v_e1 FROM remittance_calculator_entries WHERE operation_id = v_op1;
  SELECT id INTO v_e2 FROM remittance_calculator_entries WHERE operation_id = v_op2;
  v_opv := pg_temp.t227_complete(v_acc, v_conv, v_agent, 9000);
  PERFORM pg_temp.t227_claims(v_agent);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_opv;
  PERFORM pg_temp.t227_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('usdt_sell_gyd', NULL));
  PERFORM pg_temp.t227_claims(NULL);
  v_opp := pg_temp.t227_complete(v_acc, v_conv, v_agent, 30000);
  SELECT id INTO v_ep FROM remittance_calculator_entries WHERE operation_id = v_opp;
  PERFORM pg_temp.t227_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('usdt_sell_gyd', 260));
  PERFORM pg_temp.t227_claims(NULL);
  v_opo := pg_temp.t227_complete(v_acc2, v_conv2, v_other, 20000);
  IF v_e1 IS NULL OR v_e2 IS NULL OR (SELECT status FROM remittance_calculator_entries WHERE id = v_ep) <> 'verified_pending' THEN
    RAISE EXCEPTION 'fixture: expected two completed lines and a pending one'; END IF;

  SELECT id INTO v_ev FROM remittance_calculator_entries WHERE operation_id = v_opv AND status = 'void';
  -- the manual document the client holds
  PERFORM pg_temp.t227_claims(v_agent);
  PERFORM crm_guardar_documento_calculadora(v_acc, '5 zelle 100', 'Semana 1');
  PERFORM pg_temp.t227_claims(NULL);

  -- ---- 1. before the cut the Calculator read returns E1, E2 and the pending one ----
  v_vis := pg_temp.t227_visible(v_acc);
  IF v_vis <> (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY[v_op1::text || ':completed', v_op2::text || ':completed', v_opp::text || ':verified_pending']) x) THEN
    RAISE EXCEPTION 'case 1: the Calculator read before the cut returned %', v_vis; END IF;
  RAISE NOTICE 'PASS 1: before the cut the Calculator read returns the completed lines and the pending one (a void one is not returned)';

  -- the whole-account close before the cut
  PERFORM pg_temp.t227_claims(v_admin);
  v_close0 := crm_cierre_financiero(v_day, v_day);
  PERFORM pg_temp.t227_claims(NULL);
  SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]') INTO v_before_rows FROM remittance_calculator_entries e WHERE e.account_id = v_acc;
  v_side := pg_temp.t227_side(v_acc);

  -- ---- 2. the cut archives and empties ----
  v_res := pg_temp.t227_cut(v_agent, v_acc, '5 zelle 100', 'Semana 1', 1300.5, 1200, 100.5);
  IF v_res <> 'ok' THEN RAISE EXCEPTION 'case 2: the agent cut failed with %', v_res; END IF;
  SELECT * INTO v_w FROM remittance_calculator_weeks WHERE account_id = v_acc;
  IF v_w.raw_text <> '5 zelle 100' OR v_w.period_label <> 'Semana 1' OR v_w.cut_by IS DISTINCT FROM v_agent OR v_w.cut_at IS NULL THEN
    RAISE EXCEPTION 'case 2: the archived week lost the text / period / author: % / % / %', v_w.raw_text, v_w.period_label, v_w.cut_by; END IF;
  IF (v_w.manual_totals ->> 'facturado_gyd')::numeric <> 1300.5 OR (v_w.manual_totals ->> 'invertido_gyd')::numeric <> 1200
     OR (v_w.manual_totals ->> 'retorno_gyd')::numeric <> 100.5 THEN
    RAISE EXCEPTION 'case 2: the manual totals must be stored as sent, got %', v_w.manual_totals; END IF;
  IF (v_w.chat_totals ->> 'count')::int <> 2
     OR (v_w.chat_totals ->> 'facturado_gyd')::numeric <> (SELECT sum(facturado_gyd) FROM remittance_calculator_entries WHERE id IN (v_e1, v_e2))
     OR (v_w.chat_totals ->> 'invertido_gyd')::numeric <> (SELECT sum(invertido_gyd) FROM remittance_calculator_entries WHERE id IN (v_e1, v_e2))
     OR (v_w.chat_totals ->> 'retorno_gyd')::numeric <> (SELECT sum(retorno_gyd) FROM remittance_calculator_entries WHERE id IN (v_e1, v_e2)) THEN
    RAISE EXCEPTION 'case 2: the chat totals must be computed from the entries shown, got %', v_w.chat_totals; END IF;
  IF jsonb_array_length(v_w.entries) <> 2
     OR NOT (v_w.entries @> jsonb_build_array(jsonb_build_object('id', v_e1)) AND v_w.entries @> jsonb_build_array(jsonb_build_object('id', v_e2))) THEN
    RAISE EXCEPTION 'case 2: the snapshot must hold the two completed entries shown (not the pending one), got %', v_w.entries; END IF;
  SELECT * INTO v_doc FROM remittance_calculator_documents WHERE account_id = v_acc;
  IF v_doc.raw_text <> '' OR v_doc.period_label <> '' THEN RAISE EXCEPTION 'case 2: the document must be emptied, got % / %', v_doc.raw_text, v_doc.period_label; END IF;
  v_cut1 := v_w.cut_at;
  PERFORM pg_temp.t227_claims(v_admin);
  v_close1 := crm_cierre_financiero(v_day, v_day);
  PERFORM pg_temp.t227_claims(NULL);
  RAISE NOTICE 'PASS 2: the cut archives text, period, manual and chat totals and the entries shown, records the cut, empties the document';

  -- ---- 3. after the cut: no completed line older than it; the pending one stays; a new one shows ----
  v_vis := pg_temp.t227_visible(v_acc);
  IF v_vis <> v_opp::text || ':verified_pending' THEN RAISE EXCEPTION 'case 3: after the cut only the pending line may remain, got %', v_vis; END IF;
  v_op3 := pg_temp.t227_complete(v_acc, v_conv, v_agent, 7800);
  SELECT id INTO v_e3 FROM remittance_calculator_entries WHERE operation_id = v_op3;
  v_vis := pg_temp.t227_visible(v_acc);
  IF v_vis <> (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY[v_op3::text || ':completed', v_opp::text || ':verified_pending']) x) THEN
    RAISE EXCEPTION 'case 3: a line completed after the cut must show, got %', v_vis; END IF;
  -- the pending line, resolved after the cut, stays in the new week (it was never archived)
  PERFORM pg_temp.t227_claims(v_admin);
  PERFORM crm_corregir_entrada_calculadora(v_ep, 30500, 28000);
  PERFORM pg_temp.t227_claims(NULL);
  IF pg_temp.t227_visible(v_acc) <> (SELECT string_agg(x, ',' ORDER BY x) FROM unnest(ARRAY[v_op3::text || ':completed', v_opp::text || ':completed']) x) THEN
    RAISE EXCEPTION 'case 3: a pending line resolved after the cut must stay in the new week, got %', pg_temp.t227_visible(v_acc); END IF;
  IF pg_temp.t227_visible(v_acc2) <> v_opo::text || ':completed' THEN RAISE EXCEPTION 'case 3: the other account must be untouched'; END IF;
  RAISE NOTICE 'PASS 3: the Calculator read drops the archived lines, keeps pending ones, shows lines completed after the cut';

  -- ---- 4. Finanzas gives EXACTLY the same numbers before and after the cut (the same jsonb) ----
  IF v_close1 IS DISTINCT FROM v_close0 THEN RAISE EXCEPTION 'case 4: the close changed after the cut: % vs %', v_close0, v_close1; END IF;
  IF jsonb_array_length(v_close1 -> 'detalle') < 2 THEN RAISE EXCEPTION 'case 4: the compared close must hold the archived lines'; END IF;
  IF (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]') FROM remittance_calculator_entries e WHERE e.account_id = v_acc AND e.id IN (v_e1, v_e2, v_ev))
     IS DISTINCT FROM (SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'id'), '[]') FROM jsonb_array_elements(v_before_rows) x WHERE (x ->> 'id')::uuid IN (v_e1, v_e2, v_ev)) THEN
    RAISE EXCEPTION 'case 4: the cut changed archived entry rows'; END IF;
  RAISE NOTICE 'PASS 4: the close of the account is the same jsonb before and after the cut; entry rows untouched';

  -- ---- 5. the archived week reads back for a member, not for another account ----
  SET LOCAL ROLE authenticated;
  PERFORM pg_temp.t227_claims(v_viewer);
  SELECT count(*) INTO v_n FROM remittance_calculator_weeks WHERE account_id = v_acc;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: a member must read the archived week (list), got % rows', v_n; END IF;
  SELECT * INTO v_w FROM remittance_calculator_weeks WHERE id = (SELECT id FROM remittance_calculator_weeks WHERE account_id = v_acc);
  IF v_w.raw_text <> '5 zelle 100' OR jsonb_array_length(v_w.entries) <> 2 THEN RAISE EXCEPTION 'case 5: one archived week must read back whole'; END IF;
  PERFORM pg_temp.t227_claims(v_other);
  SELECT count(*) INTO v_n FROM remittance_calculator_weeks WHERE account_id = v_acc;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 5: another account read % archived weeks', v_n; END IF;
  SELECT count(*) INTO v_n FROM calculator_current_entries WHERE account_id = v_acc;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 5: another account read the Calculator view of this account'; END IF;
  PERFORM pg_temp.t227_claims(NULL);
  RESET ROLE;
  -- a client cannot write the archive directly
  IF has_table_privilege('authenticated', 'remittance_calculator_weeks', 'INSERT') OR has_table_privilege('authenticated', 'remittance_calculator_weeks', 'UPDATE')
     OR has_table_privilege('authenticated', 'remittance_calculator_weeks', 'DELETE') OR has_table_privilege('anon', 'remittance_calculator_weeks', 'SELECT') THEN
    RAISE EXCEPTION 'case 5: the archive is read-only for clients and invisible to anon'; END IF;
  RAISE NOTICE 'PASS 5: an account member reads the archive (list and one week), another account does not, clients cannot write it';

  -- ---- 6. roles ----
  IF pg_temp.t227_cut(v_viewer, v_acc, 'x', 'y', 0, 0, 0) <> '42501' THEN RAISE EXCEPTION 'case 6: a viewer must be refused (42501)'; END IF;
  IF pg_temp.t227_cut(v_other, v_acc, 'x', 'y', 0, 0, 0) <> '42501' THEN RAISE EXCEPTION 'case 6: another account''s admin must be refused (42501)'; END IF;
  IF pg_temp.t227_cut(NULL, v_acc, 'x', 'y', 0, 0, 0) <> '42501' THEN RAISE EXCEPTION 'case 6: no session must be refused (42501)'; END IF;
  IF pg_temp.t227_cut(v_agent, NULL, 'x', 'y', 0, 0, 0) <> '22023' THEN RAISE EXCEPTION 'case 6: a missing account must be refused (22023)'; END IF;
  IF pg_temp.t227_cut(v_agent, v_acc, NULL, 'y', 0, 0, 0) <> '22023' OR pg_temp.t227_cut(v_agent, v_acc, 'x', NULL, 0, 0, 0) <> '22023'
     OR pg_temp.t227_cut(v_agent, v_acc, 'x', 'y', NULL, 0, 0) <> '22023' OR pg_temp.t227_cut(v_agent, v_acc, 'x', 'y', 0, 1e15, 0) <> '22023' THEN
    RAISE EXCEPTION 'case 6: a missing text / period or a missing / out-of-range manual total must be refused (22023)'; END IF;
  IF has_function_privilege('anon', 'crm_cerrar_semana_calculadora(uuid,text,text,numeric,numeric,numeric)', 'execute') THEN RAISE EXCEPTION 'case 6: anon must not execute the cut'; END IF;
  IF (SELECT count(*) FROM remittance_calculator_weeks WHERE account_id = v_acc) <> 1 THEN RAISE EXCEPTION 'case 6: a refused cut recorded a week'; END IF;
  RAISE NOTICE 'PASS 6: agent+ can cut; viewer, other account, no session refused; bad input refused; anon cannot execute';

  -- ---- 7. two cuts in a row: the second archive has only what came after the first ----
  v_res := pg_temp.t227_cut(v_admin, v_acc, 'second week', 'Semana 2', 0, 0, 0);
  IF v_res <> 'ok' THEN RAISE EXCEPTION 'case 7: the second cut failed with %', v_res; END IF;
  SELECT * INTO v_w2 FROM remittance_calculator_weeks WHERE account_id = v_acc ORDER BY cut_at DESC LIMIT 1;
  IF v_w2.raw_text <> 'second week' OR v_w2.cut_at <= v_cut1 THEN RAISE EXCEPTION 'case 7: the second week must be the latest'; END IF;
  IF jsonb_array_length(v_w2.entries) <> 2 OR NOT (v_w2.entries @> jsonb_build_array(jsonb_build_object('id', v_e3)) AND v_w2.entries @> jsonb_build_array(jsonb_build_object('id', v_ep)))
     OR (v_w2.chat_totals ->> 'count')::int <> 2 THEN
    RAISE EXCEPTION 'case 7: the second archive must hold only E3 and the resolved line, got %', v_w2.entries; END IF;
  IF v_w2.entries @> jsonb_build_array(jsonb_build_object('id', v_e1)) OR v_w2.entries @> jsonb_build_array(jsonb_build_object('id', v_e2)) THEN
    RAISE EXCEPTION 'case 7: the second archive repeats the first week''s lines'; END IF;
  IF pg_temp.t227_visible(v_acc) <> '' THEN RAISE EXCEPTION 'case 7: the Calculator must be empty after the second cut, got %', pg_temp.t227_visible(v_acc); END IF;
  IF (SELECT count(*) FROM remittance_calculator_weeks WHERE account_id = v_acc) <> 2 THEN RAISE EXCEPTION 'case 7: two weeks expected'; END IF;
  RAISE NOTICE 'PASS 7: two cuts in a row work; the second archive holds only what came after the first';

  -- ---- 8. nothing changed in the history, nothing posted ----
  IF (SELECT coalesce(jsonb_agg(to_jsonb(e) ORDER BY e.id), '[]') FROM remittance_calculator_entries e WHERE e.account_id = v_acc AND e.id IN (v_e1, v_e2, v_ev))
     IS DISTINCT FROM (SELECT coalesce(jsonb_agg(x ORDER BY x ->> 'id'), '[]') FROM jsonb_array_elements(v_before_rows) x WHERE (x ->> 'id')::uuid IN (v_e1, v_e2, v_ev)) THEN
    RAISE EXCEPTION 'case 8: a cut changed entry rows'; END IF;
  IF pg_temp.t227_side(v_acc) <> v_side THEN RAISE EXCEPTION 'case 8: a cut must not post a message, an outbox row or a notification'; END IF;
  RAISE NOTICE 'PASS 8: entry rows untouched, nothing posted';

  RAISE NOTICE 'calculator-weekly-cut: ALL PASS';
END $$;

ROLLBACK;
