\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 398 (reseller deposits without operations).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs.
-- Run it alone on staging (wrapped by staging-migracion.sh, or by hand as
-- BEGIN; \i this file; ROLLBACK;).
--
-- RED before 398: the first reference to reseller_deposits or
-- reseller_deposit_cutover fails because neither exists yet.
--
-- Fixture: one account A with owner/admin/agent/viewer/stranger profiles,
-- a reseller tag and an admin tag; contacts r (attribution cases), r2
-- (zero-total reseller), rt (totals math + reset), c (customer), ca
-- (admin+reseller) and g (guard fixtures, untagged).
--
-- Cases:
--   1 reseller wrapper: no operation/receipt/objective/reparto, two pending
--     claims (one per receipt block), retry idempotent, fallback claim with
--     no parsable block
--   2 admin precedence: verificacion_admin, no reseller claim
--   3 customer path unchanged: delegates to cerebro_registrar_deposito and
--     creates its operation
--   4 exact TransID attribution through the cross with a NULL operation
--   5 single approximate candidate attributed as 'aproximado'
--   6 two approximate candidates: none attributed
--   7 sin_correo stays pending, later exact consumption (312) verifies it
--   8 resend (ya_reclamado) is counted once
--   9 admin consumption with no matching claim attributes nobody
--  10 forced attribution unique_violation: the consumption still succeeds
--  11 mismatch / annulled / old receipts are not consumed and stay pending
--  12 reseller_deposits only accepts pending -> verified; API roles cannot
--     write or delete; RLS by membership
--  13 totals = verified deposits + pre-cutover operations + adjustments,
--     with separate lines; post-cutover op, linked deposit, annulled and
--     freed deposit are excluded; pending claims excluded and counted
--  14 reset snapshot closes deposits; stale expected total refused
--  15 reset all skips zero-total resellers
--  16 viewer reads, agent writes refused
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_owner    uuid := gen_random_uuid();
  v_admin    uuid := gen_random_uuid();
  v_agent    uuid := gen_random_uuid();
  v_viewer   uuid := gen_random_uuid();
  v_stranger uuid := gen_random_uuid();
  v_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_acc      uuid;
  v_tag_res  uuid;
  v_tag_adm  uuid;
  v_r        uuid;
  v_r2       uuid;
  v_rt       uuid;
  v_c        uuid;
  v_ca       uuid;
  v_g        uuid;
  v_conv_r   uuid;
  v_conv_r2  uuid;
  v_conv_rt  uuid;
  v_conv_c   uuid;
  v_conv_ca  uuid;
  v_conv_g   uuid;
  v_stage    CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';   -- deposit_verification
  v_stage_ok CONSTANT uuid := '1b36b34c-1bf1-4095-9a86-5ec5ff945d2b';   -- completed
  v_stage_in CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';   -- incident
  v_t0       timestamptz;

  v_comp_a text;
  v_comp_b text;
  v_comp_c text;
  v_comp_d text;
  v_comp_e1 text;
  v_comp_e2 text;
  v_comp_f text;
  v_comp_g text;
  v_comp_h text;
  v_comp_i text;
  v_comp_j text;
  v_comp_k text;
  v_comp_fb text;
  v_note   text;

  v_deal    uuid;
  v_accion  text;
  v_esrev   boolean;
  v_sumado  boolean;
  v_res     text;
  v_metodo  text;
  v_json    jsonb;
  v_entry   jsonb;
  v_sel     jsonb;
  v_current jsonb;
  v_reset   jsonb;
  v_batch   uuid;
  v_reset_at timestamptz;
  v_count   integer;
  v_count2  integer;
  v_ops_before integer;
  v_rec_before integer;
  v_obj_before integer;
  v_rep_before integer;
  v_dep     numeric;
  v_ops     numeric;
  v_adj     numeric;
  v_cnt     integer;
  v_missing integer;
  v_closed  numeric;
  v_fixture uuid;
  v_guard   uuid;
  v_linked_op uuid;
  v_claim   record;
  v_fail    text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  v_t0 := clock_timestamp();

  v_comp_a  := 'COMP-' || substring(md5('rd-398-comp-a'), 1, 20);
  v_comp_b  := 'COMP-' || substring(md5('rd-398-comp-b'), 1, 20);
  v_comp_c  := 'COMP-' || substring(md5('rd-398-comp-c'), 1, 20);
  v_comp_d  := 'COMP-' || substring(md5('rd-398-comp-d'), 1, 20);
  v_comp_e1 := 'COMP-' || substring(md5('rd-398-comp-e1'), 1, 20);
  v_comp_e2 := 'COMP-' || substring(md5('rd-398-comp-e2'), 1, 20);
  v_comp_f  := 'COMP-' || substring(md5('rd-398-comp-f'), 1, 20);
  v_comp_g  := 'COMP-' || substring(md5('rd-398-comp-g'), 1, 20);
  v_comp_h  := 'COMP-' || substring(md5('rd-398-comp-h'), 1, 20);
  v_comp_i  := 'COMP-' || substring(md5('rd-398-comp-i'), 1, 20);
  v_comp_j  := 'COMP-' || substring(md5('rd-398-comp-j'), 1, 20);
  v_comp_k  := 'COMP-' || substring(md5('rd-398-comp-k'), 1, 20);
  v_comp_fb := 'COMP-' || substring(md5('rd-398-comp-fb'), 1, 20);

  -- ---- fixtures -------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rd398-owner-'||v_owner||'@test.invalid',       v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rd398-admin-'||v_admin||'@test.invalid',       v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rd398-agent-'||v_agent||'@test.invalid',       v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rd398-viewer-'||v_viewer||'@test.invalid',     v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_stranger, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'rd398-stranger-'||v_stranger||'@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'rd398 account', v_owner) RETURNING id INTO v_acc;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner,  'rd owner',  'rd398-owner-'||v_owner||'@test.invalid',       v_acc, 'owner'),
    (gen_random_uuid(), v_admin,  'rd admin',  'rd398-admin-'||v_admin||'@test.invalid',       v_acc, 'admin'),
    (gen_random_uuid(), v_agent,  'rd agent',  'rd398-agent-'||v_agent||'@test.invalid',       v_acc, 'agent'),
    (gen_random_uuid(), v_viewer, 'rd viewer', 'rd398-viewer-'||v_viewer||'@test.invalid',     v_acc, 'viewer');

  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner, v_acc, 'Revendedor') RETURNING id INTO v_tag_res;
  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner, v_acc, 'Admin')       RETURNING id INTO v_tag_adm;

  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_acc, '59939800001', 'rd r')  RETURNING id INTO v_r;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_acc, '59939800002', 'rd r2') RETURNING id INTO v_r2;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_acc, '59939800003', 'rd rt') RETURNING id INTO v_rt;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_acc, '59939800004', 'rd c')  RETURNING id INTO v_c;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_acc, '59939800005', 'rd ca') RETURNING id INTO v_ca;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_acc, '59939800006', 'rd g')  RETURNING id INTO v_g;

  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_r, v_tag_res);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_r2, v_tag_res);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_rt, v_tag_res);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_ca, v_tag_res);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_ca, v_tag_adm);

  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_r,  v_acc) RETURNING id INTO v_conv_r;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_r2, v_acc) RETURNING id INTO v_conv_r2;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_rt, v_acc) RETURNING id INTO v_conv_rt;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_c,  v_acc) RETURNING id INTO v_conv_c;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_ca, v_acc) RETURNING id INTO v_conv_ca;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_g,  v_acc) RETURNING id INTO v_conv_g;

  -- The cutover boundary is overridden inside this rolled-back transaction.
  UPDATE reseller_deposit_cutover SET cutover_at = v_t0;

  -- Operations are inserted by a member so 096's completion guard accepts a
  -- real 'completed' status instead of coercing it to incident.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  -- ---- 1. reseller wrapper creates no operation; one claim per block ----
  SELECT count(*) INTO v_ops_before FROM remittance_operations o WHERE o.account_id = v_acc AND o.conversation_id = v_conv_r;
  SELECT count(*) INTO v_rec_before FROM remittance_operation_receipts x WHERE x.conversation_id = v_conv_r;
  SELECT count(*) INTO v_obj_before FROM cerebro_objetivo_envio x WHERE x.conversation_id = v_conv_r;
  SELECT count(*) INTO v_rep_before FROM cerebro_reparto_planeado x WHERE x.conversation_id = v_conv_r;

  v_note := E'DEPOSITO: 1,111 GYD - APROBADA\nRef: 398398000001111\n' || v_comp_a
         || E'\n---\nDEPOSITO: 2,222 GYD - APROBADA\nRef: 398398000002222\n' || v_comp_b;

  SELECT deal_id, accion, es_revendedor, sumado INTO v_deal, v_accion, v_esrev, v_sumado
    FROM cerebro_registrar_deposito_si_cliente(v_conv_r, 3333, 'GYD', v_stage, v_note, 'COMP-outer-1');

  IF v_deal IS NOT NULL OR v_accion <> 'deposito_revendedor' OR v_esrev IS DISTINCT FROM true OR v_sumado IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'case 1: reseller result must be (NULL, deposito_revendedor, true, false), got (% %, %, %)', v_deal, v_accion, v_esrev, v_sumado;
  END IF;
  IF (SELECT count(*) FROM remittance_operations o WHERE o.account_id = v_acc AND o.conversation_id = v_conv_r) <> v_ops_before
     OR (SELECT count(*) FROM remittance_operation_receipts x WHERE x.conversation_id = v_conv_r) <> v_rec_before
     OR (SELECT count(*) FROM cerebro_objetivo_envio x WHERE x.conversation_id = v_conv_r) <> v_obj_before
     OR (SELECT count(*) FROM cerebro_reparto_planeado x WHERE x.conversation_id = v_conv_r) <> v_rep_before THEN
    RAISE EXCEPTION 'case 1: a reseller receipt must create no operation, receipt, objective or reparto rows';
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.conversation_id = v_conv_r AND r.verified_at IS NULL
     AND r.comp_id IN (v_comp_a, v_comp_b);
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'case 1: one pending claim per receipt block expected (2), got %', v_count;
  END IF;

  -- Retry with the same receipt blocks: idempotent, still two claims.
  SELECT deal_id, accion, es_revendedor, sumado INTO v_deal, v_accion, v_esrev, v_sumado
    FROM cerebro_registrar_deposito_si_cliente(v_conv_r, 3333, 'GYD', v_stage, v_note, 'COMP-outer-1');
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.conversation_id = v_conv_r AND r.verified_at IS NULL
     AND r.comp_id IN (v_comp_a, v_comp_b);
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'case 1: a retried call must not duplicate claims, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 1: reseller wrapper creates no operation and one pending claim per block';

  -- Fallback: a note with no parsable block still records one pending claim.
  SELECT count(*) INTO v_count FROM reseller_deposits r WHERE r.conversation_id = v_conv_r;
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 1234, 'GYD', v_stage, 'nota sin bloque de deposito', v_comp_fb);
  SELECT count(*) INTO v_count2 FROM reseller_deposits r WHERE r.conversation_id = v_conv_r;
  IF v_count2 <> v_count + 1 THEN
    RAISE EXCEPTION 'case 1: the fallback claim must add one pending claim, % -> %', v_count, v_count2;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM reseller_deposits r WHERE r.conversation_id = v_conv_r AND r.comp_id = v_comp_fb AND r.reference_read IS NULL AND r.amount_read = 1234) THEN
    RAISE EXCEPTION 'case 1: the fallback claim must carry the amount and no reference';
  END IF;
  RAISE NOTICE 'PASS 1b: a note with no parsable block records one pending claim from p_monto';

  -- ---- 2. admin precedence --------------------------------------------
  SELECT deal_id, accion, es_revendedor, sumado INTO v_deal, v_accion, v_esrev, v_sumado
    FROM cerebro_registrar_deposito_si_cliente(v_conv_ca, 4000, 'GYD', v_stage, 'DEPOSITO: 4,000 GYD', 'COMP-ca');
  IF v_deal IS NOT NULL OR v_accion <> 'verificacion_admin' OR v_esrev IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'case 2: admin precedence must return verificacion_admin, got (% %, %)', v_deal, v_accion, v_esrev;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r WHERE r.conversation_id = v_conv_ca;
  IF v_count <> 0 THEN RAISE EXCEPTION 'case 2: admin precedence must record no reseller claim, got %', v_count; END IF;
  RAISE NOTICE 'PASS 2: admin precedence keeps the verification-only result and no claim';

  -- ---- 3. customer path unchanged -------------------------------------
  SELECT count(*) INTO v_ops_before FROM remittance_operations o WHERE o.account_id = v_acc AND o.conversation_id = v_conv_c;
  SELECT deal_id, accion, es_revendedor, sumado INTO v_deal, v_accion, v_esrev, v_sumado
    FROM cerebro_registrar_deposito_si_cliente(v_conv_c, 4444, 'GYD', v_stage,
      E'DEPOSITO: 4,444 GYD - APROBADA\nRef: 398398000004444\n' || v_comp_k, v_comp_k);
  IF v_deal IS NULL OR v_accion <> 'creado' OR v_esrev IS DISTINCT FROM false OR v_sumado IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'case 3: a customer receipt must delegate and create its operation, got (% %, %, %)', v_deal, v_accion, v_esrev, v_sumado;
  END IF;
  IF (SELECT count(*) FROM remittance_operations o WHERE o.account_id = v_acc AND o.conversation_id = v_conv_c) <> v_ops_before + 1 THEN
    RAISE EXCEPTION 'case 3: the customer path must create exactly one operation';
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r WHERE r.conversation_id = v_conv_c;
  IF v_count <> 0 THEN RAISE EXCEPTION 'case 3: a customer receipt must record no reseller claim, got %', v_count; END IF;
  RAISE NOTICE 'PASS 3: the customer path delegates unchanged and creates its operation';

  -- ---- 4. exact TransID attribution ----------------------------------
  v_note := E'DEPOSITO: 5,000 GYD - APROBADA\nRef: 398398000005000\n' || v_comp_c;
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 5000, 'GYD', v_stage, v_note, v_comp_c);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000005000', 5000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-5000');
  SELECT resultado, metodo INTO v_res, v_metodo
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000005000'], ARRAY[5000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'verificado' OR v_metodo <> 'exacto' THEN
    RAISE EXCEPTION 'case 4: exact cross must verify, got % / %', v_res, v_metodo;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.trans_id = '398398000005000' AND d.consumido_en IS NOT NULL AND d.operation_id IS NULL) THEN
    RAISE EXCEPTION 'case 4: the deposit must be consumed with operation_id NULL';
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.reference_read = '398398000005000' AND r.verified_at IS NOT NULL
     AND r.trans_id = '398398000005000' AND r.amount_gyd = 5000 AND r.verification_method = 'exacto';
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 4: the exact claim must be verified once, got %', v_count; END IF;
  RAISE NOTICE 'PASS 4: the cross with a NULL operation consumes and attributes the exact claim';

  -- ---- 5. single approximate candidate -------------------------------
  v_note := E'DEPOSITO: 6,000 GYD - APROBADA\nRef: 398398000006001\n' || v_comp_d;
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 6000, 'GYD', v_stage, v_note, v_comp_d);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000006000', 6000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-6000');
  SELECT resultado, metodo INTO v_res, v_metodo
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000006001'], ARRAY[6000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'verificado' OR v_metodo <> 'aproximado' THEN
    RAISE EXCEPTION 'case 5: the single approximate candidate must verify, got % / %', v_res, v_metodo;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.trans_id = '398398000006000' AND r.verified_at IS NOT NULL AND r.verification_method = 'aproximado';
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 5: the claim must be verified as aproximado, got %', v_count; END IF;
  RAISE NOTICE 'PASS 5: a single approximate candidate is attributed as aproximado';

  -- ---- 6. ambiguous approximate match --------------------------------
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 7000, 'GYD', v_stage,
    E'DEPOSITO: 7,000 GYD - APROBADA\nRef: 398398000007001\n' || v_comp_e1, v_comp_e1);
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 7000, 'GYD', v_stage,
    E'DEPOSITO: 7,000 GYD - APROBADA\nRef: 398398000007002\n' || v_comp_e2, v_comp_e2);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000007000', 7000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-7000');
  SELECT resultado, metodo INTO v_res, v_metodo
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000007001'], ARRAY[7000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'verificado' THEN
    RAISE EXCEPTION 'case 6: the one deposit candidate must still be consumed, got %', v_res;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.comp_id IN (v_comp_e1, v_comp_e2) AND r.verified_at IS NULL;
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'case 6: two ambiguous approximate claims must stay pending, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 6: two approximate candidates are left unverified';

  -- ---- 7. sin_correo pending, later exact consumption (312) ----------
  v_note := E'DEPOSITO: 8,000 GYD - APROBADA\nRef: 398398000008000\n' || v_comp_f;
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 8000, 'GYD', v_stage, v_note, v_comp_f);
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000008000'], ARRAY[8000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'sin_correo' THEN
    RAISE EXCEPTION 'case 7: a missing MMG record must answer sin_correo, got %', v_res;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r WHERE r.comp_id = v_comp_f AND r.verified_at IS NULL;
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 7: the claim must stay pending after sin_correo'; END IF;

  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000008000', 8000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-8000');
  v_res := cerebro_verificar_transid('398398000008000');
  IF v_res NOT LIKE 'VERIFICADO%' THEN
    RAISE EXCEPTION 'case 7: the typed TransID must verify, got %', v_res;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.comp_id = v_comp_f AND r.verified_at IS NOT NULL AND r.trans_id = '398398000008000' AND r.verification_method = 'exacto';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'case 7: the late exact consumption must verify the pending claim, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 7: sin_correo stays pending and a later exact consumption verifies it';

  -- ---- 8. resend counted once ----------------------------------------
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000005000'], ARRAY[5000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'ya_reclamado' THEN
    RAISE EXCEPTION 'case 8: a resent receipt must answer ya_reclamado, got %', v_res;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.trans_id IN ('398398000005000', '398398000006000', '398398000008000') AND r.verified_at IS NOT NULL;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'case 8: the resend must not verify a second claim, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 8: a resent receipt is already claimed and counted once';

  -- ---- 9. admin consumption with no claim ----------------------------
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000009000', 9000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-9000');
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000009000'], ARRAY[9000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'verificado' THEN
    RAISE EXCEPTION 'case 9: the admin-style consumption must verify the deposit, got %', v_res;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r WHERE r.trans_id = '398398000009000';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'case 9: a consumption with no pending claim must attribute nobody, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 9: a consumption with no matching claim attributes nobody';

  -- ---- 10. forced attribution error: consumption still succeeds ------
  INSERT INTO reseller_deposits (account_id, contact_id, conversation_id, comp_id, reference_read,
                                 amount_read, currency_read, trans_id, amount_gyd, verification_method, verified_at)
  VALUES (v_acc, v_r, v_conv_r, 'COMP-'||substring(md5('rd-398-fixture-verified'),1,20), '398398000010000',
          10000, 'GYD', '398398000010000', 1, 'exacto', v_t0 - interval '1 hour')
  RETURNING id INTO v_fixture;

  v_note := E'DEPOSITO: 10,000 GYD - APROBADA\nRef: 398398000010000\n' || v_comp_g;
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 10000, 'GYD', v_stage, v_note, v_comp_g);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000010000', 10000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-10000');
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000010000'], ARRAY[10000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'verificado' THEN
    RAISE EXCEPTION 'case 10: an attribution error must not block the consumption, got %', v_res;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM depositos_mmg d WHERE d.trans_id = '398398000010000' AND d.consumido_en IS NOT NULL AND d.operation_id IS NULL) THEN
    RAISE EXCEPTION 'case 10: the deposit must still be consumed with operation_id NULL';
  END IF;
  SELECT count(*) INTO v_count FROM reseller_deposits r WHERE r.comp_id = v_comp_g AND r.verified_at IS NULL;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'case 10: the failed attribution must leave its claim pending, got %', v_count;
  END IF;
  DELETE FROM reseller_deposits WHERE id = v_fixture;
  RAISE NOTICE 'PASS 10: a forced unique_violation is swallowed and the consumption succeeds';

  -- ---- 11. mismatch / annulled / old receipts are not consumed -------
  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 12000, 'GYD', v_stage,
    E'DEPOSITO: 12,000 GYD - APROBADA\nRef: 398398000012000\n' || v_comp_h, v_comp_h);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000012000', 12500, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-12000');
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000012000'], ARRAY[12000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'monto_no_coincide' THEN
    RAISE EXCEPTION 'case 11: an amount mismatch must not consume, got %', v_res;
  END IF;

  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 13000, 'GYD', v_stage,
    E'DEPOSITO: 13,000 GYD - APROBADA\nRef: 398398000013000\n' || v_comp_i, v_comp_i);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id, anulado_en, motivo_anulacion)
  VALUES ('398398000013000', 13000, 'GYD', 'PRUEBA 398', 'prueba', now(), 'rd398-13000', now(), 'prueba');
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000013000'], ARRAY[13000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'deposito_anulado' THEN
    RAISE EXCEPTION 'case 11: an annulled deposit must not consume, got %', v_res;
  END IF;

  PERFORM cerebro_registrar_deposito_si_cliente(v_conv_r, 14000, 'GYD', v_stage,
    E'DEPOSITO: 14,000 GYD - APROBADA\nRef: 398398000014000\n' || v_comp_j, v_comp_j);
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id)
  VALUES ('398398000014000', 14000, 'GYD', 'PRUEBA 398', 'prueba', now() - interval '100 hours', 'rd398-14000');
  SELECT resultado INTO v_res
    FROM cerebro_cruzar_depositos(NULL, ARRAY['398398000014000'], ARRAY[14000],
                                  v_stage_ok, v_stage_in, v_stage_ok, false);
  IF v_res <> 'deposito_antiguo' THEN
    RAISE EXCEPTION 'case 11: an old deposit must not consume, got %', v_res;
  END IF;

  SELECT count(*) INTO v_count FROM reseller_deposits r
   WHERE r.comp_id IN (v_comp_h, v_comp_i, v_comp_j) AND r.verified_at IS NULL;
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'case 11: mismatch, annulled and old receipts must stay pending, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 11: mismatch, annulled and old receipts are not consumed and stay pending';

  -- ---- 12. guard and privileges on reseller_deposits -----------------
  INSERT INTO reseller_deposits (account_id, contact_id, conversation_id, comp_id, reference_read, amount_read, currency_read)
  VALUES (v_acc, v_g, v_conv_g, 'COMP-'||substring(md5('rd-398-guard'),1,20), '398398000099000', 123, 'GYD')
  RETURNING id INTO v_guard;

  BEGIN
    UPDATE reseller_deposits SET amount_read = 999 WHERE id = v_guard;
    RAISE EXCEPTION 'case 12: a non-verification update must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  BEGIN
    UPDATE reseller_deposits
       SET trans_id = 'guard-1', amount_gyd = 1, verified_at = clock_timestamp(), verification_method = 'exacto'
     WHERE id = v_guard;
    UPDATE reseller_deposits SET amount_read = 999 WHERE id = v_guard;
    RAISE EXCEPTION 'case 12: a verified row must be immutable';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  IF has_table_privilege('authenticated', 'public.reseller_deposits', 'INSERT')
     OR has_table_privilege('authenticated', 'public.reseller_deposits', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.reseller_deposits', 'DELETE')
     OR NOT has_table_privilege('authenticated', 'public.reseller_deposits', 'SELECT') THEN
    RAISE EXCEPTION 'case 12: reseller_deposits grants are wrong';
  END IF;
  IF has_table_privilege('authenticated', 'public.reseller_deposit_cutover', 'INSERT')
     OR has_table_privilege('authenticated', 'public.reseller_deposit_cutover', 'UPDATE')
     OR NOT has_table_privilege('authenticated', 'public.reseller_deposit_cutover', 'SELECT') THEN
    RAISE EXCEPTION 'case 12: reseller_deposit_cutover grants are wrong';
  END IF;
  IF has_function_privilege('authenticated', 'public._reseller_period_counts(uuid, uuid, timestamptz, timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 12: the helper must not be executable by API roles';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.cerebro_registrar_deposito_si_cliente(uuid, numeric, text, uuid, text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 12: the wrapper ACL is wrong';
  END IF;

  -- RLS: a member sees rows, a stranger sees none; API DELETE is refused.
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM reseller_deposits WHERE account_id = v_acc;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_count2 FROM reseller_deposits WHERE account_id = v_acc;
    BEGIN
      DELETE FROM reseller_deposits WHERE id = v_guard;
      RAISE EXCEPTION 'case 12: an API role must not delete a claim';
    EXCEPTION WHEN insufficient_privilege THEN NULL; END;
    RESET ROLE;
    IF v_count = 0 OR v_count2 <> 0 THEN
      RAISE EXCEPTION 'case 12: RLS must show the rows to a member and none to a stranger, got % and %', v_count, v_count2;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE;
  END;
  RAISE NOTICE 'PASS 12: pending -> verified is the only update; API roles cannot write or delete';

  -- ---- 13. totals math ------------------------------------------------
  -- Pre-cutover qualifying operations: 100 + 200 + NULL (counted as 0) +
  -- 4444 linked to a deposit (counted through the operation line only).
  INSERT INTO remittance_operations (id, status, account_id, conversation_id, contact_id, service_type,
         source_country, source_currency, destination_currency, delivery_method, quoted_source_amount, created_at, updated_at)
  VALUES (gen_random_uuid(), 'completed', v_acc, v_conv_rt, v_rt, 'remesa', 'GY', 'GYD', 'CUP', 'cuban_card', 4444, v_t0 - interval '2 days', v_t0 - interval '2 days')
  RETURNING id INTO v_linked_op;

  INSERT INTO remittance_operations (id, status, account_id, conversation_id, contact_id, service_type,
         source_country, source_currency, destination_currency, delivery_method, quoted_source_amount, created_at, updated_at)
  SELECT gen_random_uuid(), v.status, v_acc, v_conv_rt, v_rt, 'remesa',
         'GY', v.cur, 'CUP', 'cuban_card', v.amount, v.created_at, v.created_at
    FROM (VALUES
      ('deposit_received', 'GYD', 100::numeric,  v_t0 - interval '40 hours'),
      ('completed',        'GYD', 200::numeric,  v_t0 - interval '30 hours'),
      ('incident',         'GYD', NULL::numeric, v_t0 - interval '20 hours'),
      ('cancelled',        'GYD', 1000::numeric, v_t0 - interval '10 hours'),
      ('awaiting_deposit', 'GYD', 500::numeric,  v_t0 - interval '9 hours'),
      ('completed',        'USD', 2000::numeric, v_t0 - interval '8 hours'),
      ('completed',        'GYD', 3000::numeric, v_t0 + interval '1 second')
    ) v(status, cur, amount, created_at);

  -- Deposit fixtures for rt.
  INSERT INTO depositos_mmg (trans_id, monto, moneda, titular, asunto, recibido_en, gmail_message_id, consumido_en, operation_id, anulado_en)
  VALUES
    ('398398000020001', 300, 'GYD', 'PRUEBA 398', 'prueba', v_t0 - interval '2 hours', 'rd398-20001', v_t0 - interval '90 minutes', NULL, NULL),
    ('398398000020002', 700, 'GYD', 'PRUEBA 398', 'prueba', v_t0 - interval '2 hours', 'rd398-20002', v_t0 - interval '90 minutes', NULL, NULL),
    ('398398000020003', 4444, 'GYD', 'PRUEBA 398', 'prueba', v_t0 - interval '2 days', 'rd398-20003', v_t0 - interval '2 days', v_linked_op, NULL),
    ('398398000020004', 999, 'GYD', 'PRUEBA 398', 'prueba', v_t0 - interval '2 hours', 'rd398-20004', v_t0 - interval '80 minutes', NULL, v_t0 - interval '70 minutes'),
    ('398398000020005', 555, 'GYD', 'PRUEBA 398', 'prueba', v_t0 - interval '2 hours', 'rd398-20005', v_t0 - interval '60 minutes', NULL, NULL);

  INSERT INTO reseller_deposits (account_id, contact_id, conversation_id, comp_id, reference_read, amount_read,
                                 currency_read, trans_id, amount_gyd, verification_method, verified_at)
  VALUES
    (v_acc, v_rt, v_conv_rt, 'COMP-'||substring(md5('rt-d1'),1,20), '398398000020001', 300, 'GYD', '398398000020001', 300, 'exacto', v_t0 - interval '90 minutes'),
    (v_acc, v_rt, v_conv_rt, 'COMP-'||substring(md5('rt-d2'),1,20), '398398000020002', 700, 'GYD', '398398000020002', 700, 'exacto', v_t0 - interval '90 minutes'),
    (v_acc, v_rt, v_conv_rt, 'COMP-'||substring(md5('rt-d3'),1,20), '398398000020003', 4444, 'GYD', '398398000020003', 4444, 'exacto', v_t0 - interval '2 days'),
    (v_acc, v_rt, v_conv_rt, 'COMP-'||substring(md5('rt-d4'),1,20), '398398000020004', 999, 'GYD', '398398000020004', 999, 'exacto', v_t0 - interval '80 minutes'),
    (v_acc, v_rt, v_conv_rt, 'COMP-'||substring(md5('rt-d5'),1,20), '398398000020005', 555, 'GYD', '398398000020005', 555, 'exacto', v_t0 - interval '60 minutes');

  INSERT INTO reseller_total_adjustments (account_id, contact_id, amount_gyd, reason, actor, created_at)
  VALUES (v_acc, v_rt, 50, 'ajuste positivo 398', 'assertion', v_t0 - interval '5 minutes'),
         (v_acc, v_rt, -20, 'ajuste negativo 398', 'assertion', v_t0 - interval '4 minutes');

  INSERT INTO reseller_deposits (account_id, contact_id, conversation_id, comp_id, reference_read, amount_read, currency_read)
  VALUES (v_acc, v_rt, v_conv_rt, 'COMP-'||substring(md5('rt-pending'),1,20), '398398000077777', 777, 'GYD');

  -- deposits = 300 + 700 + 555 = 1555 (linked and annulled excluded)
  -- operations = 100 + 200 + NULL + 4444 = 4744 over 4 rows, 1 missing
  -- adjustments = 50 - 20 = 30
  SELECT * INTO v_claim FROM _reseller_period_counts(v_acc, v_rt, NULL, NULL) c;
  IF v_claim.deposits_gyd <> 1555 OR v_claim.deposits_count <> 3
     OR v_claim.operations_gyd <> 4744 OR v_claim.operations_count <> 4 OR v_claim.operations_missing_amount <> 1
     OR v_claim.adjustments_gyd <> 30 OR v_claim.adjustments_count <> 2
     OR v_claim.counted_gyd <> 6299 OR v_claim.total_gyd <> 6329 THEN
    RAISE EXCEPTION 'case 13: unexpected counts before freeing: %', row_to_json(v_claim);
  END IF;

  -- Free the 555 deposit: it must drop out on the next read.
  UPDATE depositos_mmg SET consumido_en = NULL WHERE trans_id = '398398000020005';
  SELECT * INTO v_claim FROM _reseller_period_counts(v_acc, v_rt, NULL, NULL) c;
  IF v_claim.deposits_gyd <> 1000 OR v_claim.deposits_count <> 2
     OR v_claim.counted_gyd <> 5744 OR v_claim.total_gyd <> 5774 THEN
    RAISE EXCEPTION 'case 13: a freed deposit must drop out, got %', row_to_json(v_claim);
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  v_json := crm_revendedores_resumen(v_acc);
  v_sel := NULL;
  FOR v_entry IN SELECT * FROM jsonb_array_elements(v_json->'resellers') LOOP
    IF v_entry->>'contact_id' = v_rt::text THEN v_sel := v_entry; END IF;
  END LOOP;
  IF v_sel IS NULL
     OR (v_sel->>'deposits_gyd')::numeric <> 1000
     OR (v_sel->>'deposits_count')::int <> 2
     OR (v_sel->>'operations_gyd')::numeric <> 4744
     OR (v_sel->>'operations_count')::int <> 4
     OR (v_sel->>'operations_missing_amount')::int <> 1
     OR (v_sel->>'adjustments_gyd')::numeric <> 30
     OR (v_sel->>'counted_gyd')::numeric <> 5744
     OR (v_sel->>'total_gyd')::numeric <> 5774 THEN
    RAISE EXCEPTION 'case 13: rt summary must be deposits 1000 / ops 4744 / adj 30 / total 5774, got %', v_sel;
  END IF;

  -- grand: r 19000 deposits + rt 1000 deposits = 20000; ops 4744; adjustments 30
  IF (v_json->'grand'->>'deposits_gyd')::numeric <> 20000
     OR (v_json->'grand'->>'deposits_count')::int <> 5
     OR (v_json->'grand'->>'operations_gyd')::numeric <> 4744
     OR (v_json->'grand'->>'adjustments_gyd')::numeric <> 30
     OR (v_json->'grand'->>'counted_gyd')::numeric <> 24744
     OR (v_json->'grand'->>'total_gyd')::numeric <> 24774
     OR (v_json->'grand'->>'resellers')::int <> 4 THEN
    RAISE EXCEPTION 'case 13: grand must be deposits 20000 / ops 4744 / adj 30 / total 24774 over 4 resellers, got %', v_json->'grand';
  END IF;

  v_json := crm_revendedor_detalle(v_rt);
  v_current := v_json->'current';
  IF (v_json->>'pending_claims')::int <> 1
     OR (v_current->>'deposits_gyd')::numeric <> 1000
     OR (v_current->>'operations_gyd')::numeric <> 4744
     OR (v_current->>'adjustments_gyd')::numeric <> 30
     OR (v_current->>'counted_gyd')::numeric <> 5744
     OR (v_current->>'total_gyd')::numeric <> 5774 THEN
    RAISE EXCEPTION 'case 13: rt detail must be deposits 1000 / ops 4744 / adj 30 / total 5774 with 1 pending claim, got %', v_json;
  END IF;
  RAISE NOTICE 'PASS 13: totals are verified deposits + pre-cutover operations + adjustments, with separate lines';

  -- ---- 14. reset snapshot closes deposits ----------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_reset := crm_revendedor_reiniciar(v_rt, 'cierre 398', 5774);
  v_reset_at := (v_reset->>'reset_at')::timestamptz;
  IF (v_reset->'closed'->>'deposits_gyd')::numeric <> 1000
     OR (v_reset->'closed'->>'operations_gyd')::numeric <> 4744
     OR (v_reset->'closed'->>'adjustments_gyd')::numeric <> 30
     OR (v_reset->'closed'->>'counted_gyd')::numeric <> 5744
     OR (v_reset->'closed'->>'total_gyd')::numeric <> 5774 THEN
    RAISE EXCEPTION 'case 14: the reset must close deposits 1000 / ops 4744 / adj 30 / total 5774, got %', v_reset;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_counter_resets r
   WHERE r.contact_id = v_rt AND r.account_id = v_acc
     AND r.closed_deposits_gyd = 1000 AND r.closed_operations_gyd = 4744
     AND r.closed_adjustments_gyd = 30 AND r.closed_total_gyd = 5774;
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 14: the marker snapshot must store the deposit part, got %', v_count; END IF;

  v_json := crm_revendedor_detalle(v_rt);
  v_current := v_json->'current';
  v_entry := v_json->'periods'->0;
  IF (v_current->>'total_gyd')::numeric <> 0
     OR jsonb_array_length(v_json->'periods') <> 1
     OR (v_entry->>'deposits_gyd')::numeric <> 1000
     OR (v_entry->>'operations_gyd')::numeric <> 4744
     OR (v_entry->>'adjustments_gyd')::numeric <> 30
     OR (v_entry->>'total_gyd')::numeric <> 5774
     OR (v_entry->>'closed_total_gyd')::numeric <> 5774
     OR (v_entry->>'closed_deposits_gyd')::numeric <> 1000 THEN
    RAISE EXCEPTION 'case 14: after reset the current total must be 0 and the closed period must show deposits 1000, got %', v_json;
  END IF;

  SELECT count(*) INTO v_count FROM reseller_counter_resets r WHERE r.contact_id = v_rt AND r.account_id = v_acc;
  BEGIN
    PERFORM crm_revendedor_reiniciar(v_rt, NULL, 1);
    RAISE EXCEPTION 'case 14: a stale expected total must raise 40001';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
  SELECT count(*) INTO v_count2 FROM reseller_counter_resets r WHERE r.contact_id = v_rt AND r.account_id = v_acc;
  IF v_count2 <> v_count THEN RAISE EXCEPTION 'case 14: the refused reset must add no marker, % -> %', v_count, v_count2; END IF;
  RAISE NOTICE 'PASS 14: the reset snapshot closes deposits and restarts the counter';

  -- ---- 15. reset all skips zero-total resellers ----------------------
  v_reset := crm_revendedores_reiniciar_todos(v_acc, 'reset all 398', NULL);
  v_batch := (v_reset->>'batch_id')::uuid;
  IF (v_reset->>'count')::int <> 1
     OR (v_reset->>'grand_total_gyd')::numeric <> 19000
     OR jsonb_array_length(v_reset->'resets') <> 1
     OR (v_reset->'resets'->0->>'contact_id') <> v_r::text
     OR (v_reset->'resets'->0->>'total_gyd')::numeric <> 19000 THEN
    RAISE EXCEPTION 'case 15: reset all must close only r (19000) in one batch, got %', v_reset;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_counter_resets r WHERE r.contact_id = v_r AND r.account_id = v_acc AND r.batch_id = v_batch;
  SELECT count(*) INTO v_count2 FROM reseller_counter_resets r WHERE r.contact_id IN (v_r2, v_rt) AND r.account_id = v_acc AND r.batch_id = v_batch;
  IF v_count <> 1 OR v_count2 <> 0 THEN
    RAISE EXCEPTION 'case 15: r needs one batch marker and the zero resellers must be skipped, got % / %', v_count, v_count2;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_counter_resets r WHERE r.contact_id = v_r AND r.account_id = v_acc AND r.closed_deposits_gyd = 19000 AND r.closed_total_gyd = 19000;
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 15: the reset-all marker must close the deposit part, got %', v_count; END IF;

  v_json := crm_revendedores_resumen(v_acc);
  IF (v_json->'grand'->>'total_gyd')::numeric <> 0 THEN
    RAISE EXCEPTION 'case 15: after reset all the grand total must be 0, got %', v_json->'grand';
  END IF;
  RAISE NOTICE 'PASS 15: reset all closes the deposit totals and skips zeros';

  -- ---- 16. reads and writes by role ----------------------------------
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent, 'role', 'authenticated')::text, true);
  v_json := crm_revendedores_resumen(v_acc);
  IF v_json IS NULL THEN RAISE EXCEPTION 'case 16: an agent must be able to read the summary'; END IF;
  BEGIN PERFORM crm_revendedor_ajustar(v_rt, 10, NULL); RAISE EXCEPTION 'case 16: an agent adjustment must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM crm_revendedor_reiniciar(v_rt, NULL, NULL); RAISE EXCEPTION 'case 16: an agent reset must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM crm_revendedores_reiniciar_todos(v_acc, NULL, NULL); RAISE EXCEPTION 'case 16: an agent reset all must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  BEGIN PERFORM crm_revendedor_ajustar(v_rt, 10, NULL); RAISE EXCEPTION 'case 16: a viewer adjustment must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  BEGIN PERFORM crm_revendedores_resumen(v_acc); RAISE EXCEPTION 'case 16: a stranger must not read the totals';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  RAISE NOTICE 'PASS 16: viewer reads, agent writes and stranger reads are refused';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
