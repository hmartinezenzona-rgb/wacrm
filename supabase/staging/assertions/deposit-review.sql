-- deposit-review.sql — self-reverting assertion for
-- 099_deposit_review_rpcs.sql
--
-- Proves crm_comprobantes_de_operacion, crm_verificar_deposito and
-- crm_forzar_verificacion: the derived receipt/consumed-deposit read
-- model, authorization (viewer+ / agent+ / admin+ per function),
-- validation, the panel verify path delegating to the live (unversioned)
-- cerebro_cruzar_depositos cross-reference engine without moving the
-- deal's stage during the cross-reference call itself, the
-- "VERIFICADO -> VERIFICADO EN PANEL" notes rewrite that keeps the
-- client-notify skip working, and the admin-only forced verification
-- path.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures
-- (pipeline/stage via ON CONFLICT DO NOTHING, same ids as corrections.sql)
-- so it can run alongside or independently of the other assertion files.

SAVEPOINT deposit_review;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_agent_user     uuid := gen_random_uuid();
  v_viewer_user    uuid := gen_random_uuid();
  v_nonmember_user uuid := gen_random_uuid();
  v_contact_id     uuid;
  v_conv_id        uuid;
  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista          CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_owner uuid;
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_ref_main       CONSTANT text := '10412345678901';
  v_ref_mismatch   CONSTANT text := '10412345678902';
  v_ref_consumed   CONSTANT text := '10412345678903';
  v_comp_id        CONSTANT text := 'COMP-1a2b3c4d5e6f7890abcd';
  v_wamid          CONSTANT text := 'wamid.TEST00000000000001';

  v_deal_id        uuid; v_op_id        uuid;
  v_deal_x2_id     uuid; v_op_x2_id     uuid;
  v_deal_x3_id     uuid; v_op_x3_id     uuid;
  v_deal_items_id  uuid; v_op_items_id  uuid;
  v_deal_ready_id  uuid; v_op_ready_id  uuid;
  v_deal_force_id  uuid; v_op_force_id  uuid;

  v_message_id     uuid;

  v_result         jsonb;
  v_receipts       jsonb;
  v_receipt0       jsonb;
  v_consumed       jsonb;
  v_stage          uuid;
  v_notes          text;
  v_deposit_deal   uuid;
  v_deposit_cons   timestamptz;
  v_body_text      text;

  v_case_start     timestamptz;
  v_fail_count     integer := 0;
BEGIN
  -- ---- fixtures -------------------------------------------------------
  -- Does not rely on the on_auth_user_created / handle_new_user() signup
  -- trigger — see corrections.sql's fixture comment for why.
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'deposit-review-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'deposit-review-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'deposit-review-viewer-' || v_viewer_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_nonmember_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'deposit-review-nonmember-' || v_nonmember_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'deposit review test account', v_owner_user)
  RETURNING id INTO v_account_id;

  -- v_owner_user doubles as the "owner/admin" persona for the
  -- admin-gated crm_forzar_verificacion cases: is_account_member ranks
  -- owner above admin, so an owner satisfies an admin-or-above check.
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'deposit review owner', 'deposit-review-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_agent_user, 'deposit review agent', 'deposit-review-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent'),
    (gen_random_uuid(), v_viewer_user, 'deposit review viewer', 'deposit-review-viewer-' || v_viewer_user || '@test.invalid', v_account_id, 'viewer');
  -- v_nonmember_user intentionally has no profile in this (or any) account.

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista, v_pipeline_id, 'Lista para transferir', 50) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 90) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() / notify_deal_stage_change() (pre-existing
  -- triggers, unrelated to 099) fire on every deals INSERT / stage UPDATE
  -- and need a non-null notify_url; point them at a loopback no-op. Our
  -- own transaction never commits, so pg_net's worker never actually
  -- dispatches these.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/deposit-review-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'deposit-review-noop') ON CONFLICT (clave) DO NOTHING;

  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000401', v_account_id) RETURNING id INTO v_contact_id;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_id, v_account_id) RETURNING id INTO v_conv_id;

  -- deal (main): POR_VERIFICAR, notes carry one receipt block (comp id,
  -- declared amount/currency/ref) plus a BENEFICIARIO block. Used by the
  -- read cases (1, 2b, 4) and the exact-match verify case (3).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'deposit review fixture main', v_account_id, v_conv_id, v_contact_id, 25000, 'GYD')
  RETURNING id INTO v_deal_id;
  SELECT id INTO v_op_id FROM remittance_operations WHERE deal_id = v_deal_id;
  IF v_op_id IS NULL THEN
    RAISE EXCEPTION 'deposit-review: fixture setup failed — no operation created for deal %', v_deal_id;
  END IF;
  UPDATE deals SET notes =
      'DEPOSITO: 25,000 GYD - EXITOSA' || E'\n' ||
      'Ref: ' || v_ref_main || E'\n' ||
      v_comp_id ||
      E'\n---\n' ||
      'BENEFICIARIO (auto)' || E'\n' ||
      'Tarjeta: 1111222233334444' || E'\n' ||
      'Celular: 55512345'
   WHERE id = v_deal_id;
  -- Since 156 every receipt the bot registers is also a structured row
  -- (cerebro_registrar_deposito dual-writes it); since 159 the panel reads
  -- that row, not the notes. Mirror what the bot writes.
  INSERT INTO remittance_operation_receipts (operation_id, conversation_id, comp_id, amount, currency,
         receipt_status, recipient, via, reference, receipt_date, correct_destination, source, block_index)
  SELECT v_op_id, v_conv_id, p.comp_id, p.amount, p.currency, p.receipt_status, p.recipient, p.via,
         p.reference, p.receipt_date, p.correct_destination, 'bot', p.block_index
    FROM cerebro_parsear_comprobantes((SELECT notes FROM deals WHERE id = v_deal_id)) p;

  -- deal x2: POR_VERIFICAR, used for the amount-mismatch cross-reference
  -- case (5) and as the FK anchor for the already-consumed deposit fixture.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'deposit review fixture x2', v_account_id, v_conv_id, v_contact_id, 25000, 'GYD')
  RETURNING id INTO v_deal_x2_id;
  SELECT id INTO v_op_x2_id FROM remittance_operations WHERE deal_id = v_deal_x2_id;
  IF v_op_x2_id IS NULL THEN
    RAISE EXCEPTION 'deposit-review: fixture setup failed — no operation created for deal %', v_deal_x2_id;
  END IF;

  -- deal x3: POR_VERIFICAR, used for the already-consumed cross-reference
  -- case (6).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'deposit review fixture x3', v_account_id, v_conv_id, v_contact_id, 10000, 'GYD')
  RETURNING id INTO v_deal_x3_id;
  SELECT id INTO v_op_x3_id FROM remittance_operations WHERE deal_id = v_deal_x3_id;
  IF v_op_x3_id IS NULL THEN
    RAISE EXCEPTION 'deposit-review: fixture setup failed — no operation created for deal %', v_deal_x3_id;
  END IF;

  -- deal items: POR_VERIFICAR, left untouched throughout — used only for
  -- the items-validation negative cases and the viewer-authorization
  -- case (7a, 7c-7e), so those checks always exercise the intended
  -- branch instead of tripping an earlier stage/status guard.
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'deposit review fixture items', v_account_id, v_conv_id, v_contact_id, 5000, 'GYD')
  RETURNING id INTO v_deal_items_id;
  SELECT id INTO v_op_items_id FROM remittance_operations WHERE deal_id = v_deal_items_id;
  IF v_op_items_id IS NULL THEN
    RAISE EXCEPTION 'deposit-review: fixture setup failed — no operation created for deal %', v_deal_items_id;
  END IF;

  -- deal ready: already in LISTA (ready_to_transfer) — used for the
  -- "operation not awaiting deposit verification" negative case (7b).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_lista, 'deposit review fixture ready', v_account_id, v_conv_id, v_contact_id, 5000, 'GYD')
  RETURNING id INTO v_deal_ready_id;
  SELECT id INTO v_op_ready_id FROM remittance_operations WHERE deal_id = v_deal_ready_id;
  IF v_op_ready_id IS NULL THEN
    RAISE EXCEPTION 'deposit-review: fixture setup failed — no operation created for deal %', v_deal_ready_id;
  END IF;

  -- deal force: POR_VERIFICAR — used for the forced-verification cases (8).
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'deposit review fixture force', v_account_id, v_conv_id, v_contact_id, 5000, 'GYD')
  RETURNING id INTO v_deal_force_id;
  SELECT id INTO v_op_force_id FROM remittance_operations WHERE deal_id = v_deal_force_id;
  IF v_op_force_id IS NULL THEN
    RAISE EXCEPTION 'deposit-review: fixture setup failed — no operation created for deal %', v_deal_force_id;
  END IF;

  -- receipt image: comprobantes_hashes.comp_id -> whatsapp_message_id ->
  -- messages.message_id (the wamid), same conversation as the operation.
  INSERT INTO messages (id, conversation_id, sender_type, sender_id, content_type, media_url, message_id, status, created_at)
  VALUES (gen_random_uuid(), v_conv_id, 'customer', v_contact_id, 'image', 'https://example.invalid/deposit-review-receipt.jpg', v_wamid, 'delivered', now() - interval '10 minutes')
  RETURNING id INTO v_message_id;

  INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, fecha_recibido, whatsapp_message_id)
  VALUES ('deadbeefdeadbeefdeadbeefdeadbeef01', '15550000401', v_comp_id, now() - interval '10 minutes', v_wamid);

  -- depositos_mmg: exact match (unconsumed), already-consumed (for deal
  -- x2), mismatched amount (unconsumed).
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, gmail_message_id)
  VALUES (v_ref_main, 25000, 'GYD', 'Deposito de prueba - exacto', now(), 'gm-deposit-review-exact-001');

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, gmail_message_id, deal_id, consumido_en)
  VALUES (v_ref_consumed, 10000, 'GYD', 'Deposito de prueba - consumido', now() - interval '2 hours', 'gm-deposit-review-consumed-001', v_deal_x2_id, now() - interval '1 hour');

  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, gmail_message_id)
  VALUES (v_ref_mismatch, 30000, 'GYD', 'Deposito de prueba - monto distinto', now(), 'gm-deposit-review-mismatch-001');

  -- ---- case 1: viewer reads the derived receipt model ------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
  SELECT crm_comprobantes_de_operacion(v_op_id) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  v_receipts := v_result -> 'receipts';
  v_receipt0 := v_receipts -> 0;

  IF jsonb_array_length(v_receipts) IS DISTINCT FROM 1
     OR (v_receipt0 ->> 'comp_id') IS DISTINCT FROM v_comp_id
     OR (v_receipt0 ->> 'declared_amount')::numeric IS DISTINCT FROM 25000
     OR (v_receipt0 ->> 'declared_currency') IS DISTINCT FROM 'GYD'
     OR (v_receipt0 ->> 'declared_ref') IS DISTINCT FROM v_ref_main
     OR (v_receipt0 ->> 'media_url') IS NULL
     OR (v_receipt0 ->> 'message_id') IS NULL
     OR (v_receipt0 -> 'matched_deposit') IS DISTINCT FROM 'null'::jsonb
     OR (v_result ->> 'can_verify') IS DISTINCT FROM 'true'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected 1 receipt with comp_id=%, amount=25000 GYD, ref=%, media_url/message_id set, matched_deposit null, can_verify true; got %', v_comp_id, v_ref_main, v_result;
  ELSE
    RAISE NOTICE 'PASS [case 1] viewer reads the derived receipt model with one unmatched receipt and can_verify true';
  END IF;

  -- ---- case 2a: non-member -> 42501 ------------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_nonmember_user, 'role', 'authenticated')::text, true);
    PERFORM crm_comprobantes_de_operacion(v_op_id);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2a] expected 42501 for a non-member, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 2a] a non-member is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2a] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 2b: unknown operation id -> P0002 --------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_comprobantes_de_operacion(gen_random_uuid());
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2b] expected P0002 for an unknown operation id, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = 'P0002' THEN
      RAISE NOTICE 'PASS [case 2b] an unknown operation id is rejected with P0002';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 2b] expected SQLSTATE P0002, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 3: agent verifies the exact match --------------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_verificar_deposito(v_op_id, jsonb_build_array(jsonb_build_object('ref', v_ref_main, 'amount', 25000))) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT stage_id, notes INTO v_stage, v_notes FROM deals WHERE id = v_deal_id;
  SELECT deal_id, consumido_en INTO v_deposit_deal, v_deposit_cons FROM depositos_mmg WHERE trans_id = v_ref_main;

  -- Only the notify payload's NEW-row notes matter for the client-notify
  -- skip check: old_record legitimately still carries the raw
  -- pre-rewrite text (it reflects the row before this exact UPDATE), so
  -- the assertion must look at record.notes specifically, not the whole
  -- payload.
  SELECT convert_from(body, 'UTF8')::jsonb -> 'record' ->> 'notes' INTO v_body_text
    FROM net.http_request_queue
   WHERE convert_from(body, 'UTF8')::jsonb ->> 'table' = 'deals'
     AND convert_from(body, 'UTF8')::jsonb ->> 'type' = 'UPDATE'
     AND (convert_from(body, 'UTF8')::jsonb -> 'record' ->> 'id') = v_deal_id::text
   ORDER BY id DESC
   LIMIT 1;

  IF (v_result ->> 'resultado') IS DISTINCT FROM 'verificado'
     OR (v_result ->> 'stage_changed') IS DISTINCT FROM 'true'
     OR (v_result ->> 'new_status') IS DISTINCT FROM 'ready_to_transfer'
     OR v_stage IS DISTINCT FROM v_lista
     OR v_deposit_deal IS DISTINCT FROM v_deal_id
     OR v_deposit_cons IS NULL
     OR v_notes LIKE '%VERIFICADO: casa con el correo de MMG%'
     OR v_notes NOT LIKE '%VERIFICADO EN PANEL%'
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_id AND action = 'human_deposit_verification' AND created_at >= v_case_start
     )
     OR v_body_text IS NULL
     OR v_body_text LIKE '%VERIFICADO: casa con el correo de MMG%'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected resultado=verificado, stage_changed=true, new_status=ready_to_transfer, deal in LISTA, deposit consumed, notes rewritten, audit row, and a clean notify payload; got result=%, stage=%, deposit_deal=%, deposit_consumed=%, notes=%, body=%', v_result, v_stage, v_deposit_deal, v_deposit_cons, v_notes, v_body_text;
  ELSE
    RAISE NOTICE 'PASS [case 3] agent verifies the exact deposit match, moves the deal to LISTA, rewrites notes, and keeps the notify payload free of the skip substring';
  END IF;

  -- ---- case 4: read after verify — matched_deposit and consumed list --
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
  SELECT crm_comprobantes_de_operacion(v_op_id) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  v_receipts := v_result -> 'receipts';
  v_receipt0 := v_receipts -> 0;
  v_consumed := v_result -> 'consumed_deposits';

  IF (v_receipt0 -> 'matched_deposit' ->> 'trans_id') IS DISTINCT FROM v_ref_main
     OR jsonb_array_length(v_consumed) IS DISTINCT FROM 1
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected matched_deposit set and consumed_deposits length 1; got receipt=%, consumed=%', v_receipt0, v_consumed;
  ELSE
    RAISE NOTICE 'PASS [case 4] the read model reflects the matched deposit and the consumed-deposits list after verification';
  END IF;

  -- ---- case 5: amount mismatch -----------------------------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_verificar_deposito(v_op_x2_id, jsonb_build_array(jsonb_build_object('ref', v_ref_mismatch, 'amount', 25000))) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_x2_id;
  SELECT deal_id INTO v_deposit_deal FROM depositos_mmg WHERE trans_id = v_ref_mismatch;

  IF (v_result ->> 'resultado') IS NOT DISTINCT FROM 'verificado'
     OR (v_result ->> 'stage_changed') IS DISTINCT FROM 'false'
     OR v_stage IS DISTINCT FROM v_por_verificar
     OR v_deposit_deal IS NOT NULL
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_x2_id AND action = 'human_deposit_verification' AND created_at >= v_case_start
     )
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 5] expected resultado<>verificado, stage_changed=false, deal still POR_VERIFICAR, nothing consumed, audit row written; got result=%, stage=%, deposit_deal=%', v_result, v_stage, v_deposit_deal;
  ELSE
    RAISE NOTICE 'PASS [case 5] an amount mismatch leaves the deal untouched, consumes nothing, and still audits the attempt';
  END IF;

  -- ---- case 6: already-consumed trans_id -------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  SELECT crm_verificar_deposito(v_op_x3_id, jsonb_build_array(jsonb_build_object('ref', v_ref_consumed, 'amount', 10000))) INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  IF (v_result ->> 'resultado') IS DISTINCT FROM 'ya_reclamado'
     OR (v_result ->> 'stage_changed') IS DISTINCT FROM 'false'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 6] expected resultado=ya_reclamado and stage_changed=false; got %', v_result;
  ELSE
    RAISE NOTICE 'PASS [case 6] a trans_id already consumed by another deal is reported as ya_reclamado without moving the stage';
  END IF;

  -- ---- case 7a: verify by viewer -> 42501 ------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer_user, 'role', 'authenticated')::text, true);
    PERFORM crm_verificar_deposito(v_op_items_id, jsonb_build_array(jsonb_build_object('ref', '111', 'amount', 100)));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7a] expected 42501 for a viewer calling crm_verificar_deposito, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 7a] a viewer is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7a] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7b: operation already ready_to_transfer -> 22023 -----------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_verificar_deposito(v_op_ready_id, jsonb_build_array(jsonb_build_object('ref', '111', 'amount', 100)));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7b] expected 22023 for an operation already ready_to_transfer, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7b] an operation that is not awaiting deposit verification is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7b] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7c: empty items array -> 22023 ------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_verificar_deposito(v_op_items_id, '[]'::jsonb);
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7c] expected 22023 for an empty items array, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7c] an empty items array is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7c] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7d: non-positive amount -> 22023 ----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_verificar_deposito(v_op_items_id, jsonb_build_array(jsonb_build_object('ref', '111', 'amount', 0)));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7d] expected 22023 for a non-positive amount, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7d] a non-positive amount is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7d] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 7e: ref without digits -> 22023 -----------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_verificar_deposito(v_op_items_id, jsonb_build_array(jsonb_build_object('ref', 'abc', 'amount', 100)));
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 7e] expected 22023 for a ref without digits, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 7e] a ref without digits is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 7e] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8a: force by agent -> 42501 ---------------------------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
    PERFORM crm_forzar_verificacion(v_op_force_id, 'Deposito confirmado por banco');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8a] expected 42501 for an agent calling crm_forzar_verificacion, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '42501' THEN
      RAISE NOTICE 'PASS [case 8a] an agent is rejected with 42501';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8a] expected SQLSTATE 42501, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8b: force by admin with empty reason -> 22023 ---------------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
    PERFORM crm_forzar_verificacion(v_op_force_id, '');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8b] expected 22023 for an empty reason, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 8b] an empty reason is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8b] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8c: force by admin with too-short reason -> 22023 -----------
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
    PERFORM crm_forzar_verificacion(v_op_force_id, 'abc');
    PERFORM set_config('request.jwt.claims', '', true);
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8c] expected 22023 for a too-short reason, no exception raised';
  EXCEPTION WHEN OTHERS THEN
    PERFORM set_config('request.jwt.claims', '', true);
    IF SQLSTATE = '22023' THEN
      RAISE NOTICE 'PASS [case 8c] a too-short reason is rejected with 22023';
    ELSE
      v_fail_count := v_fail_count + 1;
      RAISE WARNING 'FAIL [case 8c] expected SQLSTATE 22023, got % (%)', SQLSTATE, SQLERRM;
    END IF;
  END;

  -- ---- case 8d: force by admin with a valid reason ----------------------
  v_case_start := clock_timestamp();
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  SELECT crm_forzar_verificacion(v_op_force_id, 'Deposito confirmado por banco') INTO v_result;
  PERFORM set_config('request.jwt.claims', '', true);

  SELECT stage_id, notes INTO v_stage, v_notes FROM deals WHERE id = v_deal_force_id;

  IF (v_result ->> 'new_status') IS DISTINCT FROM 'ready_to_transfer'
     OR v_stage IS DISTINCT FROM v_lista
     OR v_notes NOT LIKE '%VERIFICACION FORZADA EN PANEL: Deposito confirmado por banco%'
     OR v_notes LIKE '%VERIFICADO: casa con el correo de MMG%'
     OR NOT EXISTS (
       SELECT 1 FROM remittance_admin_audit
        WHERE row_id = v_op_force_id AND action = 'human_forced_verification'
          AND reason = 'Deposito confirmado por banco' AND created_at >= v_case_start
     )
     OR EXISTS (SELECT 1 FROM depositos_mmg WHERE deal_id = v_deal_force_id)
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 8d] expected new_status=ready_to_transfer, deal in LISTA, notes carrying the forced-verification note without the skip substring, an audited reason, and no depositos_mmg consumption; got result=%, stage=%, notes=%', v_result, v_stage, v_notes;
  ELSE
    RAISE NOTICE 'PASS [case 8d] an admin can force-verify with a valid reason, moving the deal to LISTA and auditing the reason without touching depositos_mmg';
  END IF;

  -- ---- verdict ----------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'deposit-review: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'deposit-review: ALL PASS (16 expectations)';
END $$;

ROLLBACK TO SAVEPOINT deposit_review;
