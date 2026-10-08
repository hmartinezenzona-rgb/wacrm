\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 226 part A (delete a calculator entry). Self-reverting: BEGIN ... ROLLBACK is in this file; any
-- failure RAISEs (ON_ERROR_STOP aborts and the connection closes, so nothing is kept). Each passing case NOTICEs.
-- Runs on staging (production after the owner's go-ahead). Builds its own accounts, users and operations.
--
-- odd/tasks/calculator-delete-and-weekly-clear.md (T1). An admin can delete a chat-fed calculator entry even when it is
-- completed: the row becomes a durable void (status void, deleted_at/deleted_by set, figures untouched), so it stops
-- counting in the Calculator, the Finanzas close (it is listed under "excluidas") and the dashboard, and the feed never
-- revives it (re-completion, replay, combo cost change). A void row that is NOT deleted (operation reverted) is still
-- revived by the feed as before. The linked operation is untouched; nothing is sent to anyone.
-- =====================================================================
BEGIN;

CREATE FUNCTION pg_temp.t226_claims(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
END $f$;

CREATE FUNCTION pg_temp.t226_del(p_uid uuid, p_entry uuid) RETURNS text LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM pg_temp.t226_claims(p_uid);
  PERFORM crm_eliminar_entrada_calculadora(p_entry);
  PERFORM pg_temp.t226_claims(NULL);
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  PERFORM pg_temp.t226_claims(NULL);
  RETURN SQLSTATE;
END $f$;

-- completes a fresh operation of the account and returns its id
CREATE FUNCTION pg_temp.t226_complete(p_acc uuid, p_conv uuid, p_agent uuid, p_amount numeric, p_service text DEFAULT 'remesa',
                                      p_dm text DEFAULT 'zelle') RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (gen_random_uuid(), p_acc, p_conv, 'ready_to_transfer', p_service, 'GYD', p_amount, p_dm) RETURNING id INTO v_op;
  PERFORM pg_temp.t226_claims(p_agent);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op;
  PERFORM pg_temp.t226_claims(NULL);
  RETURN v_op;
END $f$;

CREATE FUNCTION pg_temp.t226_side(p_acc uuid) RETURNS bigint LANGUAGE sql AS $f$
  SELECT (SELECT count(*) FROM messages m JOIN conversations c ON c.id = m.conversation_id WHERE c.account_id = p_acc)
       + (SELECT count(*) FROM message_outbox m JOIN conversations c ON c.id = m.conversation_id WHERE c.account_id = p_acc)
       + (SELECT count(*) FROM notifications n WHERE n.account_id = p_acc);
$f$;

DO $$
DECLARE
  v_dummy constant text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_owner uuid := gen_random_uuid(); v_admin uuid := gen_random_uuid(); v_agent uuid := gen_random_uuid(); v_other uuid := gen_random_uuid();
  v_acc uuid; v_acc2 uuid; v_ct uuid; v_conv uuid; v_ct2 uuid; v_conv2 uuid;
  v_op_a uuid; v_op_p uuid; v_op_c uuid; v_op_v uuid; v_op_x uuid; v_op_o uuid; v_op_a2 uuid;
  v_ea uuid; v_ep uuid; v_ec uuid; v_ev uuid; v_ex uuid; v_eo uuid; v_em uuid; v_ea2 uuid;
  v_e remittance_calculator_entries; v_before remittance_calculator_entries;
  v_close jsonb; v_close0 jsonb; v_n int; v_side bigint; v_res text; v_fid uuid;
  v_unfed int;
BEGIN
  -- ---- fixtures: two accounts, an owner, an admin, an agent, and a stranger admin of the second account ----
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ced-' || u || '@test.invalid', v_dummy, now(), now(), now(), '{}', '{}', false, false
    FROM unnest(ARRAY[v_owner, v_admin, v_agent, v_other]) u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'ced test account', v_owner) RETURNING id INTO v_acc;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'ced other account', v_other) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner, 'ced owner', 'ced-' || v_owner || '@test.invalid', v_acc, 'owner'),
    (gen_random_uuid(), v_admin, 'ced admin', 'ced-' || v_admin || '@test.invalid', v_acc, 'admin'),
    (gen_random_uuid(), v_agent, 'ced agent', 'ced-' || v_agent || '@test.invalid', v_acc, 'agent'),
    (gen_random_uuid(), v_other, 'ced other', 'ced-' || v_other || '@test.invalid', v_acc2, 'owner');
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_owner, '59902260001', v_acc, 'Cliente CED') RETURNING id INTO v_ct;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ct, v_acc) RETURNING id INTO v_conv;
  INSERT INTO contacts (id, user_id, phone, account_id, name) VALUES (gen_random_uuid(), v_other, '59902260002', v_acc2, 'Cliente CED2') RETURNING id INTO v_ct2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_other, v_ct2, v_acc2) RETURNING id INTO v_conv2;

  FOREACH v_fid IN ARRAY ARRAY[v_acc, v_acc2] LOOP
    PERFORM pg_temp.t226_claims(CASE WHEN v_fid = v_acc THEN v_admin ELSE v_other END);
    PERFORM crm_set_calculator_rates(v_fid, jsonb_build_object('cup_global_rate', 1.5, 'usdt_buy_gyd', 250, 'usdt_sell_gyd', 260, 'usdt_sell_cup', 400));
  END LOOP;
  PERFORM pg_temp.t226_claims(NULL);

  -- a completed line, a second completed line, a combo line, a reverted (void, not deleted) line, a pending line
  v_op_a := pg_temp.t226_complete(v_acc, v_conv, v_agent, 26000);
  v_op_x := pg_temp.t226_complete(v_acc, v_conv, v_agent, 13000);
  SELECT id INTO v_ea FROM remittance_calculator_entries WHERE operation_id = v_op_a;
  SELECT id INTO v_ex FROM remittance_calculator_entries WHERE operation_id = v_op_x;
  IF v_ea IS NULL OR v_ex IS NULL THEN RAISE EXCEPTION 'fixture: completed operations must feed completed lines'; END IF;

  INSERT INTO remittance_operations (id, account_id, conversation_id, status, service_type, source_currency, quoted_source_amount, combo_costo_gyd)
  VALUES (gen_random_uuid(), v_acc, v_conv, 'ready_to_transfer', 'combo', 'GYD', 30000, 18000) RETURNING id INTO v_op_c;
  PERFORM pg_temp.t226_claims(v_agent);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_c;
  PERFORM pg_temp.t226_claims(NULL);
  SELECT id INTO v_ec FROM remittance_calculator_entries WHERE operation_id = v_op_c;
  IF v_ec IS NULL OR (SELECT status FROM remittance_calculator_entries WHERE id = v_ec) <> 'completed' THEN
    RAISE EXCEPTION 'fixture: the combo must feed a completed line'; END IF;

  v_op_v := pg_temp.t226_complete(v_acc, v_conv, v_agent, 9000);
  PERFORM pg_temp.t226_claims(v_agent);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op_v;
  PERFORM pg_temp.t226_claims(NULL);
  SELECT id INTO v_ev FROM remittance_calculator_entries WHERE operation_id = v_op_v AND status = 'void';
  IF v_ev IS NULL THEN RAISE EXCEPTION 'fixture: a reverted operation must leave a void line'; END IF;

  PERFORM pg_temp.t226_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('usdt_sell_gyd', NULL));
  PERFORM pg_temp.t226_claims(NULL);
  v_op_p := pg_temp.t226_complete(v_acc, v_conv, v_agent, 30000);
  SELECT id INTO v_ep FROM remittance_calculator_entries WHERE operation_id = v_op_p;
  IF (SELECT status FROM remittance_calculator_entries WHERE id = v_ep) <> 'verified_pending' THEN RAISE EXCEPTION 'fixture: expected a pending line'; END IF;
  PERFORM pg_temp.t226_claims(v_admin);
  PERFORM crm_set_calculator_rates(v_acc, jsonb_build_object('usdt_sell_gyd', 260));
  PERFORM pg_temp.t226_claims(NULL);

  INSERT INTO remittance_calculator_entries (account_id, source, status, entry_date, customer_name, service, amount, amount_currency,
                                             facturado_gyd, invertido_gyd, retorno_gyd, completed_at)
  VALUES (v_acc, 'manual', 'completed', current_date, 'Manual CED', 'ZELLE', 50, 'USD', 13000, 12000, 1000, now()) RETURNING id INTO v_em;

  v_op_o := pg_temp.t226_complete(v_acc2, v_conv2, v_other, 20000);
  SELECT id INTO v_eo FROM remittance_calculator_entries WHERE operation_id = v_op_o;

  -- the whole-account close before anything is deleted (today's Guyana day covers every fixture)
  PERFORM pg_temp.t226_claims(v_admin);
  v_close0 := crm_cierre_financiero((now() AT TIME ZONE 'America/Guyana')::date, (now() AT TIME ZONE 'America/Guyana')::date);
  PERFORM pg_temp.t226_claims(NULL);
  v_side := pg_temp.t226_side(v_acc);

  -- ---- 1. an admin deletes a COMPLETED entry ----
  SELECT * INTO v_before FROM remittance_calculator_entries WHERE id = v_ea;
  v_res := pg_temp.t226_del(v_admin, v_ea);
  IF v_res <> 'ok' THEN RAISE EXCEPTION 'case 1: the admin delete failed with %', v_res; END IF;
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_ea;
  IF v_e.status <> 'void' OR v_e.voided_at IS NULL OR v_e.deleted_at IS NULL OR v_e.deleted_by IS DISTINCT FROM v_admin
     OR v_e.void_reason NOT LIKE 'deleted%' THEN
    RAISE EXCEPTION 'case 1: expected a deleted void, got % / % / % / % / %', v_e.status, v_e.voided_at, v_e.deleted_at, v_e.deleted_by, v_e.void_reason; END IF;
  IF v_e.facturado_gyd IS DISTINCT FROM v_before.facturado_gyd OR v_e.invertido_gyd IS DISTINCT FROM v_before.invertido_gyd
     OR v_e.retorno_gyd IS DISTINCT FROM v_before.retorno_gyd OR v_e.amount IS DISTINCT FROM v_before.amount THEN
    RAISE EXCEPTION 'case 1: the figures must stay untouched'; END IF;
  SELECT count(*) INTO v_n FROM remittance_admin_audit WHERE row_id = v_ea AND action = 'human_calculator_entry_deleted'
     AND (before ->> 'status') = 'completed' AND (after ->> 'status') = 'void';
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: exactly one audit row expected, got %', v_n; END IF;
  RAISE NOTICE 'PASS 1: an admin deletes a completed entry (void + deleted, figures untouched, one audit row)';

  -- ---- 2. it stops counting: Calculator read, Finanzas, dashboard ----
  IF EXISTS (SELECT 1 FROM remittance_calculator_entries WHERE id = v_ea AND source = 'completed_operation' AND status <> 'void') THEN
    RAISE EXCEPTION 'case 2: the Calculator / dashboard condition (non-void) still returns the entry'; END IF;
  PERFORM pg_temp.t226_claims(v_admin);
  v_close := crm_cierre_financiero((now() AT TIME ZONE 'America/Guyana')::date, (now() AT TIME ZONE 'America/Guyana')::date);
  PERFORM pg_temp.t226_claims(NULL);
  IF (v_close -> 'totales') IS NOT DISTINCT FROM (v_close0 -> 'totales') THEN
    RAISE EXCEPTION 'case 2: the close totals did not change'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_close -> 'excluidas') x
                  WHERE x ->> 'id' = v_ea::text AND x ->> 'status' = 'void' AND (x ->> 'void_reason') LIKE 'deleted%') THEN
    RAISE EXCEPTION 'case 2: the close must list the deleted entry under excluidas with its reason: %', v_close -> 'excluidas'; END IF;
  RAISE NOTICE 'PASS 2: a deleted entry is out of the Calculator read, the close totals and the dashboard condition; listed as excluded';

  -- ---- 3. the operation is untouched, nothing was sent ----
  IF (SELECT status FROM remittance_operations WHERE id = v_op_a) <> 'completed' THEN RAISE EXCEPTION 'case 3: the operation must stay completed'; END IF;
  IF pg_temp.t226_side(v_acc) <> v_side THEN RAISE EXCEPTION 'case 3: a delete must not post a message, an outbox row or a notification'; END IF;
  RAISE NOTICE 'PASS 3: the operation stays completed, nothing posted';

  -- ---- 4. the feed never revives it ----
  PERFORM pg_temp.t226_claims(v_agent);
  UPDATE remittance_operations SET status = 'ready_to_transfer' WHERE id = v_op_a;
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_a;
  PERFORM pg_temp.t226_claims(v_admin);
  PERFORM crm_feed_calculator(v_op_a);
  PERFORM pg_temp.t226_claims(NULL);
  PERFORM calculator_feed_operation(v_op_a);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_ea;
  IF v_e.status <> 'void' OR v_e.deleted_at IS NULL THEN RAISE EXCEPTION 'case 4: revert + re-complete / feed revived a deleted entry (%)', v_e.status; END IF;
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE operation_id = v_op_a AND status <> 'void';
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 4: no live line may exist for the deleted entry''s operation, got %', v_n; END IF;
  RAISE NOTICE 'PASS 4: revert, re-complete, crm_feed_calculator and calculator_feed_operation leave it deleted';

  -- ---- 5. the unfed view does not list the operation because of the deletion ----
  SELECT count(*) INTO v_unfed FROM calculator_unfed_operations WHERE operation_id = v_op_a;
  IF v_unfed <> 0 THEN RAISE EXCEPTION 'case 5: calculator_unfed_operations lists an operation whose entry was deleted on purpose'; END IF;
  -- a plain void (reverted, not deleted) of a still-completed operation would be listed: control
  RAISE NOTICE 'PASS 5: the unfed view skips an operation whose entry was deleted on purpose';

  -- ---- 6. a combo entry: a cost change does not bring it back ----
  v_res := pg_temp.t226_del(v_admin, v_ec);
  IF v_res <> 'ok' THEN RAISE EXCEPTION 'case 6: deleting the combo entry failed with %', v_res; END IF;
  PERFORM pg_temp.t226_claims(v_admin);
  PERFORM crm_set_combo_costo(v_op_c, 20000);
  PERFORM crm_set_combo_costo(v_op_c, NULL);
  PERFORM crm_set_combo_costo(v_op_c, 15000);
  PERFORM pg_temp.t226_claims(NULL);
  SELECT count(*) INTO v_n FROM remittance_calculator_entries WHERE operation_id = v_op_c AND status <> 'void';
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_ec;
  IF v_n <> 0 OR v_e.deleted_at IS NULL OR v_e.invertido_gyd IS DISTINCT FROM 18000 THEN
    RAISE EXCEPTION 'case 6: the combo cost path revived or changed a deleted entry (% live, invertido %)', v_n, v_e.invertido_gyd; END IF;
  RAISE NOTICE 'PASS 6: the combo cost path leaves a deleted combo entry deleted';

  -- ---- 7. a pending entry can be deleted ----
  v_res := pg_temp.t226_del(v_admin, v_ep);
  IF v_res <> 'ok' THEN RAISE EXCEPTION 'case 7: deleting a pending entry failed with %', v_res; END IF;
  IF (SELECT status || coalesce(deleted_at::text, '') FROM remittance_calculator_entries WHERE id = v_ep) NOT LIKE 'void%' THEN
    RAISE EXCEPTION 'case 7: the pending entry must be a deleted void'; END IF;
  RAISE NOTICE 'PASS 7: a verified_pending entry can be deleted';

  -- ---- 8. refusals ----
  IF pg_temp.t226_del(v_admin, v_ev) <> '22023' THEN RAISE EXCEPTION 'case 8: a void entry must be refused (22023)'; END IF;
  IF pg_temp.t226_del(v_admin, v_ea) <> '22023' THEN RAISE EXCEPTION 'case 8: an already deleted entry must be refused (22023)'; END IF;
  -- (228) a manual entry is a row of the same table now: only an admin deletes it (it used to be refused here with 22023)
  IF pg_temp.t226_del(v_agent, v_em) <> '42501' THEN RAISE EXCEPTION 'case 8: an agent must not delete a manual entry (42501)'; END IF;
  IF pg_temp.t226_del(v_admin, v_eo) <> '42501' THEN RAISE EXCEPTION 'case 8: another account''s entry must be refused (42501)'; END IF;
  IF pg_temp.t226_del(v_agent, v_ex) <> '42501' THEN RAISE EXCEPTION 'case 8: an agent must be refused (42501)'; END IF;
  IF pg_temp.t226_del(NULL, v_ex) <> '42501' THEN RAISE EXCEPTION 'case 8: no session must be refused (42501)'; END IF;
  IF pg_temp.t226_del(v_admin, gen_random_uuid()) <> 'P0002' THEN RAISE EXCEPTION 'case 8: an unknown entry must report not found (P0002)'; END IF;
  IF (SELECT status FROM remittance_calculator_entries WHERE id = v_ex) <> 'completed' THEN RAISE EXCEPTION 'case 8: a refused delete changed the entry'; END IF;
  IF has_function_privilege('anon', 'crm_eliminar_entrada_calculadora(uuid)', 'execute') THEN RAISE EXCEPTION 'case 8: anon must not execute the delete'; END IF;
  IF NOT has_function_privilege('authenticated', 'crm_eliminar_entrada_calculadora(uuid)', 'execute') THEN RAISE EXCEPTION 'case 8: authenticated must execute the delete'; END IF;
  RAISE NOTICE 'PASS 8: void, already deleted, other account, agent (also on a manual entry), no session, unknown id refused; anon cannot execute';

  -- ---- 9. a void entry that was NOT deleted is still revived on re-completion (unchanged behaviour) ----
  PERFORM pg_temp.t226_claims(v_agent);
  UPDATE remittance_operations SET status = 'completed', completed_at = now() WHERE id = v_op_v;
  PERFORM pg_temp.t226_claims(NULL);
  SELECT * INTO v_e FROM remittance_calculator_entries WHERE id = v_ev;
  IF v_e.status <> 'completed' OR v_e.voided_at IS NOT NULL OR v_e.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'case 9: a reverted (not deleted) entry must be revived, got % / %', v_e.status, v_e.deleted_at; END IF;
  RAISE NOTICE 'PASS 9: a reverted entry is still revived by the feed';

  -- ---- 10. the other account is untouched; no leftover side effects ----
  IF (SELECT status FROM remittance_calculator_entries WHERE id = v_eo) <> 'completed' THEN RAISE EXCEPTION 'case 10: the other account''s entry changed'; END IF;
  IF pg_temp.t226_side(v_acc) <> v_side THEN RAISE EXCEPTION 'case 10: side effects found'; END IF;
  RAISE NOTICE 'PASS 10: other account untouched, no messages / outbox / notifications';

  -- ---- 11. (228) an admin deletes a manual entry: a durable void, like a chat-fed one ----
  IF pg_temp.t226_del(v_admin, v_em) <> 'ok' THEN RAISE EXCEPTION 'case 11: an admin must be able to delete a manual entry'; END IF;
  IF (SELECT status || coalesce(deleted_at::text, '') FROM remittance_calculator_entries WHERE id = v_em) NOT LIKE 'void%'
     OR (SELECT deleted_by FROM remittance_calculator_entries WHERE id = v_em) IS DISTINCT FROM v_admin THEN
    RAISE EXCEPTION 'case 11: the manual entry must be a deleted void'; END IF;
  RAISE NOTICE 'PASS 11: a manual entry can be deleted by an admin (durable void)';

  RAISE NOTICE 'calculator-entry-delete: ALL PASS';
END $$;

ROLLBACK;
