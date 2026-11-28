-- =====================================================================
-- Assertion for migration 354 (the history hides operations deleted from the panel).
-- Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'. Fictitious data only.
-- Cases: 1 deleted op (cancelled + latest cancelled audit = human_operation_deleted) is absent from rows, total, counts and
-- the cancelled group filter; 2 cancelled by correction is present; 3 open op is present; 4 cancelled without audit is
-- present; 5 an earlier deletion audit followed by a later correction audit shows the op (latest wins); 6 pagination
-- stays consistent with total; 7 an unrelated later audit row (other status) does not resurrect a deleted op.
-- =====================================================================
CREATE FUNCTION pg_temp.mk_op(p_acc uuid, p_conv uuid, p_ct uuid, p_status text, p_audit text)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_op uuid;
BEGIN
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, status, service_type, source_currency, quoted_source_amount, delivery_method)
  VALUES (p_acc, p_conv, p_ct, p_status, 'remesa', 'GYD', 10000, 'zelle') RETURNING id INTO v_op;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, name, position, block_index, source, status)
  VALUES (v_op, 'zelle', 'Hide Recipient', 1, 1, 'manual', 'vigente');
  IF p_audit IS NOT NULL THEN
    INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after)
    VALUES (p_acc, 'remittance_operations', v_op, 'status', p_audit, 'test', '{"status":"collecting_information"}'::jsonb, '{"status":"cancelled"}'::jsonb);
  END IF;
  RETURN v_op;
END $f$;

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_acc uuid; v_ct uuid; v_conv uuid;
  v_hash text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_del uuid; v_cor uuid; v_open uuid; v_noaud uuid; v_late uuid; v_unrel uuid;
  v_n int; v_c bigint; v_t bigint;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ho-' || v_user || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'hide deleted account', v_user) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_user, 'hide deleted agent', 'ho-' || v_user || '@test.invalid', v_acc, 'agent');
  INSERT INTO contacts (user_id, account_id, phone, name) VALUES (v_user, v_acc, '+592 600-3540', 'Zq354 Cliente') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id) VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user, 'role', 'authenticated')::text, true);
  v_del   := pg_temp.mk_op(v_acc, v_conv, v_ct, 'cancelled', 'human_operation_deleted');
  v_cor   := pg_temp.mk_op(v_acc, v_conv, v_ct, 'cancelled', 'human_correction');
  v_open  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'collecting_information', NULL);
  v_noaud := pg_temp.mk_op(v_acc, v_conv, v_ct, 'cancelled', NULL);
  v_late  := pg_temp.mk_op(v_acc, v_conv, v_ct, 'cancelled', 'human_operation_deleted');
  v_unrel := pg_temp.mk_op(v_acc, v_conv, v_ct, 'cancelled', 'human_operation_deleted');
  PERFORM set_config('request.jwt.claims', '', true);

  -- 5. A later audit row that also ends in cancelled with another action: the latest decides.
  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after, created_at)
  VALUES (v_acc, 'remittance_operations', v_late, 'status', 'human_correction', 'test', '{"status":"cancelled"}'::jsonb, '{"status":"cancelled"}'::jsonb, clock_timestamp() + interval '1 second');
  -- 7. A later audit row about another status does not count as the cancellation.
  INSERT INTO remittance_admin_audit (account_id, table_name, row_id, field_name, action, actor, before, after, created_at)
  VALUES (v_acc, 'remittance_operations', v_unrel, 'status', 'human_correction', 'test', '{"status":"cancelled"}'::jsonb, '{"status":"incident"}'::jsonb, clock_timestamp() + interval '1 second');

  -- 1. Deleted op: absent from rows.
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 200, 0) t WHERE t.operation_id IN (v_del, v_unrel);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: deleted operations must not be listed, got % rows', v_n; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, 'cancelled', 'zq354', 200, 0) t WHERE t.operation_id IN (v_del, v_unrel);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: deleted operations must not be listed in the cancelled group, got % rows', v_n; END IF;
  -- visible: v_cor, v_open, v_noaud, v_late = 4 rows; total and counts agree.
  SELECT count(*), max(t.total) INTO v_n, v_t FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 200, 0) t;
  IF v_n <> 4 OR v_t <> 4 THEN RAISE EXCEPTION 'case 1: expected 4 rows and total 4, got % rows and total %', v_n, v_t; END IF;
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq354') WHERE grupo = 'cancelled';
  IF v_c IS DISTINCT FROM 3 THEN RAISE EXCEPTION 'case 1: cancelled count expected 3, got %', v_c; END IF;
  SELECT cantidad INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq354') WHERE grupo = 'in_progress';
  IF v_c IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'case 1: in_progress count expected 1, got %', v_c; END IF;
  SELECT sum(cantidad) INTO v_c FROM crm_historial_estados(NULL, NULL, NULL, 'zq354');
  IF v_c IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'case 1: counts must add up to the total 4, got %', v_c; END IF;

  -- 2, 3, 4, 5. Present.
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 200, 0) t WHERE t.operation_id = v_cor;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 2: cancelled by correction must still show'; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 200, 0) t WHERE t.operation_id = v_open;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 3: open operation must show'; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 200, 0) t WHERE t.operation_id = v_noaud;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 4: cancelled without audit must show'; END IF;
  SELECT count(*) INTO v_n FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 200, 0) t WHERE t.operation_id = v_late;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 5: latest audit (correction) must win over an earlier deletion'; END IF;

  -- 6. Pagination consistent with total.
  SELECT count(*), max(t.total) INTO v_n, v_t FROM crm_historial_operaciones(NULL, NULL, NULL, NULL, 'zq354', 3, 2) t;
  IF v_n <> 2 OR v_t <> 4 THEN RAISE EXCEPTION 'case 6: page 2 of size 3 expected 2 rows and total 4, got % rows and total %', v_n, v_t; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
