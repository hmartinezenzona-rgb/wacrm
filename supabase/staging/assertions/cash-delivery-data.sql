\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written.
-- cash-delivery-data.sql — self-reverting assertion for
-- 150_cash_delivery_data.sql
--
-- Proves crm_registrar_datos_entrega_efectivo (B1.4):
--   case 1 — phone only, no prior beneficiary: creates a vigente
--            efectivo_usd row with phone set, address/id_photo_wamid null.
--   case 2 — address only, later: merges into the SAME logical recipient
--            (case 1's row -> reemplazado with replaced_at set; new
--            vigente row has BOTH phone and address).
--   case 3 — id_photo_wamid only, later still: merges again (case 2's row
--            -> reemplazado; new vigente row has all three fields, and
--            the returned 'complete' flag is true).
--   case 4 — a call that changes nothing (same id_photo_wamid already on
--            file) is a harmless no-op: no new row, no new 'reemplazado'.
--   case 5 — a call with every parameter NULL is also a no-op.
--   case 6 — no operation at all for the conversation -> 22023 with a
--            clear message; this RPC never creates an operation.
--   case 7 — an operation exists but is CLOSED (status='completed') ->
--            same 22023 refusal (a closed op is not "open").
--   case 8 — full history check: every row that was ever vigente for
--            this recipient, except the current one, is 'reemplazado'
--            with replaced_at set — nothing was ever deleted or
--            overwritten in place.
--   case 9 — not exposed to anon or authenticated (service_role only).
--
-- RED (against 042-149, function does not exist): every SELECT of
--   crm_registrar_datos_entrega_efectivo fails with "function ... does
--   not exist" (42883).
-- GREEN (after 150): all cases above pass.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker exec -i wacrm-ensayo psql -U supabase_admin -d postgres,
-- wrapped in BEGIN ... \i 150 ... \i this file ... ROLLBACK, or against
-- real staging the same way). Never COMMIT. Never run against
-- production. Builds its own fixtures, reusing an existing conversation's
-- user_id/account_id (this RPC has no session-based auth check to
-- exercise — see 150's header — so no auth.users/accounts/profiles
-- fixtures are needed, same shape as zelle-confirmed-name.sql's own
-- assertion for the sibling cerebro_* bot tools).

SAVEPOINT cash_delivery_data;

DO $$
DECLARE
  v_user        uuid;
  v_acc         uuid;
  v_ct          uuid;
  v_conv        uuid;
  v_conv_none   uuid;
  v_conv_closed uuid;
  v_op          uuid;
  v_op_closed   uuid;

  v_result      jsonb;
  v_row1_id     uuid;
  v_row2_id     uuid;
  v_row3_id     uuid;
  v_row         remittance_beneficiaries%ROWTYPE;
  v_count       integer;
  v_fail_count  integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  SELECT user_id, account_id INTO v_user, v_acc FROM conversations LIMIT 1;

  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59900150001', 'test150-efectivo') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv;

  -- opNone: a conversation with no operation at all (case 6).
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59900150002', 'test150-none') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv_none;

  -- opClosed: a conversation whose only efectivo_usd operation is
  -- completed (case 7).
  INSERT INTO contacts (user_id, account_id, phone, name)
  VALUES (v_user, v_acc, '59900150003', 'test150-closed') RETURNING id INTO v_ct;
  INSERT INTO conversations (user_id, account_id, contact_id)
  VALUES (v_user, v_acc, v_ct) RETURNING id INTO v_conv_closed;
  -- wacrm.origin='admin' is needed so the completion guard (096) does not
  -- coerce this fixture's 'completed' status to 'incident' the way it
  -- would for an unauthenticated automation write.
  PERFORM set_config('wacrm.origin', 'admin', true);
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status)
  VALUES (v_acc, v_conv_closed, v_ct, 'efectivo_usd', 'completed') RETURNING id INTO v_op_closed;
  PERFORM set_config('wacrm.origin', '', true);

  -- The main operation: open, efectivo_usd, for cases 1-5 and 8.
  INSERT INTO remittance_operations (account_id, conversation_id, contact_id, delivery_method, status)
  VALUES (v_acc, v_conv, (SELECT contact_id FROM conversations WHERE id = v_conv), 'efectivo_usd', 'collecting_information')
  RETURNING id INTO v_op;

  -- ---- case 1: phone only, nothing on file yet -------------------------
  SELECT crm_registrar_datos_entrega_efectivo(v_conv, p_phone => '15305550101') INTO v_result;
  v_row1_id := (v_result ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE id = v_row1_id;

  IF v_row1_id IS NULL
     OR v_row.beneficiary_type IS DISTINCT FROM 'efectivo_usd'
     OR v_row.status IS DISTINCT FROM 'vigente'
     OR v_row.position IS DISTINCT FROM 1
     OR v_row.phone IS DISTINCT FROM '15305550101'
     OR v_row.address IS NOT NULL
     OR v_row.id_photo_wamid IS NOT NULL
     OR (v_result ->> 'complete') IS DISTINCT FROM 'false'
     OR (v_result ->> 'changed') IS DISTINCT FROM 'true'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected a vigente efectivo_usd row with only phone set; got phone=%, address=%, id_photo_wamid=%, complete=%', v_row.phone, v_row.address, v_row.id_photo_wamid, v_result ->> 'complete';
  ELSE
    RAISE NOTICE 'PASS [case 1] phone-only call creates a vigente efectivo_usd row';
  END IF;

  -- ---- case 2: address only, later — merges with the phone -------------
  SELECT crm_registrar_datos_entrega_efectivo(v_conv, p_address => '123 Calle Falsa, La Habana') INTO v_result;
  v_row2_id := (v_result ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE id = v_row2_id;

  IF v_row2_id IS NULL OR v_row2_id = v_row1_id
     OR v_row.phone IS DISTINCT FROM '15305550101'
     OR v_row.address IS DISTINCT FROM '123 Calle Falsa, La Habana'
     OR v_row.id_photo_wamid IS NOT NULL
     OR (v_result ->> 'complete') IS DISTINCT FROM 'false'
     OR (v_result ->> 'changed') IS DISTINCT FROM 'true'
     OR NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE id = v_row1_id AND status = 'reemplazado' AND replaced_at IS NOT NULL)
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected the new vigente row to carry both phone and address, and the old row reemplazado; got phone=%, address=%, old row still %', v_row.phone, v_row.address, (SELECT status FROM remittance_beneficiaries WHERE id = v_row1_id);
  ELSE
    RAISE NOTICE 'PASS [case 2] address-only call merges into the same logical recipient';
  END IF;

  -- ---- case 3: id_photo_wamid only, later still — all three fields -----
  SELECT crm_registrar_datos_entrega_efectivo(v_conv, p_id_photo_wamid => 'wamid.HBgLNTk5MDAxNTAwMDE=') INTO v_result;
  v_row3_id := (v_result ->> 'id')::uuid;
  SELECT * INTO v_row FROM remittance_beneficiaries WHERE id = v_row3_id;

  IF v_row3_id IS NULL OR v_row3_id = v_row2_id
     OR v_row.phone IS DISTINCT FROM '15305550101'
     OR v_row.address IS DISTINCT FROM '123 Calle Falsa, La Habana'
     OR v_row.id_photo_wamid IS DISTINCT FROM 'wamid.HBgLNTk5MDAxNTAwMDE='
     OR (v_result ->> 'complete') IS DISTINCT FROM 'true'
     OR (v_result ->> 'changed') IS DISTINCT FROM 'true'
     OR NOT EXISTS (SELECT 1 FROM remittance_beneficiaries WHERE id = v_row2_id AND status = 'reemplazado' AND replaced_at IS NOT NULL)
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected all three fields populated and complete=true; got phone=%, address=%, id_photo_wamid=%, complete=%', v_row.phone, v_row.address, v_row.id_photo_wamid, v_result ->> 'complete';
  ELSE
    RAISE NOTICE 'PASS [case 3] id_photo_wamid-only call completes the recipient data';
  END IF;

  -- ---- case 4: a call that changes nothing is a no-op -------------------
  SELECT count(*) INTO v_count FROM remittance_beneficiaries WHERE operation_id = v_op;
  SELECT crm_registrar_datos_entrega_efectivo(v_conv, p_id_photo_wamid => 'wamid.HBgLNTk5MDAxNTAwMDE=') INTO v_result;

  IF (v_result ->> 'id')::uuid IS DISTINCT FROM v_row3_id
     OR (v_result ->> 'changed') IS DISTINCT FROM 'false'
     OR (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op) IS DISTINCT FROM v_count
     OR (SELECT status FROM remittance_beneficiaries WHERE id = v_row3_id) IS DISTINCT FROM 'vigente'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] repeating an already-stored value must be a no-op; row count went from % to %', v_count, (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op);
  ELSE
    RAISE NOTICE 'PASS [case 4] a call with an unchanged value is a harmless no-op';
  END IF;

  -- ---- case 5: a call with every parameter NULL is also a no-op --------
  SELECT count(*) INTO v_count FROM remittance_beneficiaries WHERE operation_id = v_op;
  SELECT crm_registrar_datos_entrega_efectivo(v_conv) INTO v_result;

  IF (v_result ->> 'id')::uuid IS DISTINCT FROM v_row3_id
     OR (v_result ->> 'changed') IS DISTINCT FROM 'false'
     OR (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op) IS DISTINCT FROM v_count
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] an all-NULL call must be a no-op; got id=%, changed=%', v_result ->> 'id', v_result ->> 'changed';
  ELSE
    RAISE NOTICE 'PASS [case 5] an all-NULL call is a harmless no-op';
  END IF;

  -- ---- case 6: no operation at all for the conversation -> 22023 -------
  BEGIN
    PERFORM crm_registrar_datos_entrega_efectivo(v_conv_none, p_phone => '15305550199');
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected 22023 when the conversation has no operation, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 6] no operation at all for the conversation is rejected with 22023 (%)', SQLERRM;
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 6] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7: the only efectivo_usd operation is closed -> 22023 ------
  BEGIN
    PERFORM crm_registrar_datos_entrega_efectivo(v_conv_closed, p_phone => '15305550199');
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7] expected 22023 for a closed (completed) operation, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7] a closed efectivo_usd operation is rejected with 22023 (%)', SQLERRM;
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8: full history — every superseded row is reemplazado ------
  IF EXISTS (
       SELECT 1 FROM remittance_beneficiaries
        WHERE operation_id = v_op AND id <> v_row3_id
          AND (status <> 'reemplazado' OR replaced_at IS NULL)
     )
     OR (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op AND status = 'vigente') IS DISTINCT FROM 1
     OR (SELECT count(*) FROM remittance_beneficiaries WHERE operation_id = v_op) IS DISTINCT FROM 3
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8] expected exactly 3 rows total, 1 vigente (the current one) and every other one reemplazado with replaced_at set';
  ELSE
    RAISE NOTICE 'PASS [case 8] the full correction history is preserved: nothing deleted or overwritten in place';
  END IF;

  -- ---- case 9: bot-only, never exposed to anon or authenticated --------
  IF has_function_privilege('anon', 'crm_registrar_datos_entrega_efectivo(uuid,text,text,text)', 'EXECUTE') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] anon must not execute crm_registrar_datos_entrega_efectivo';
  ELSIF has_function_privilege('authenticated', 'crm_registrar_datos_entrega_efectivo(uuid,text,text,text)', 'EXECUTE') THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 9] authenticated must not execute crm_registrar_datos_entrega_efectivo (service_role only)';
  ELSE
    RAISE NOTICE 'PASS [case 9] not exposed to anon or authenticated';
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'cash-delivery-data: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'cash-delivery-data: ALL PASS (9 expectations)';
END $$;

ROLLBACK TO SAVEPOINT cash_delivery_data;
