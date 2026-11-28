\set ON_ERROR_STOP on
-- (2026-10-02) Stop at the first error: run outside BEGIN ... ROLLBACK, the SAVEPOINT below fails and nothing is written (operation-receipts.sql once left staging's notify_url on a no-op this way).
-- n8n-repoint.sql — self-reverting assertion for
-- 110_n8n_fn_repoint.sql
--
-- Proves cerebro_registrar_deposito, cerebro_cruzar_deposito and
-- cerebro_cruzar_depositos write remittance_operations.status DIRECTLY,
-- not only through the legacy bridge trigger
-- (trg_sync_operacion_desde_deal, 041/060). A naive test would pass even
-- with NO repoint at all, because that trigger already mirrors
-- deals.stage_id into remittance_operations.status on every UPDATE OF
-- stage_id. So every case below DISABLES the bridge before calling the
-- function under test, and only re-enables it once every case has run.
--
-- Run against 109's un-repointed bodies (bridge disabled) this MUST FAIL
-- on the remittance_operations expectations — that is the RED this
-- assertion exists to prove. Run again after 110 is applied, it MUST
-- pass — that is the GREEN.
--
-- Coverage (see 110's header for the exact write-site line numbers):
--   case 1 — cerebro_registrar_deposito, the "movido" UPDATE deals site
--            (an existing open deal gets its first deposit note and
--            lands in "Por verificar").
--   case 2 — the SAME "movido" write site, but via the REFERENCIA
--            IMPOSIBLE (087) path, landing in "Incidencia" instead.
--   case 3 — cerebro_cruzar_deposito, called the way n8n calls it
--            directly (distinct p_stage_ok / p_stage_incidencia /
--            p_stage_esperado), an exact deposit match moving the deal
--            to "Lista para transferir".
--   case 4 — cerebro_cruzar_depositos, a 2-item burst with NO open
--            cerebro_objetivo_envio target. This is deliberate: with
--            v_n <= 1 and no target, cerebro_cruzar_depositos short-
--            circuits straight into cerebro_cruzar_deposito and never
--            reaches its OWN final `UPDATE deals` (~157 relative to its
--            CREATE OR REPLACE, ~570 absolute in 109/110) — the site
--            that actually decides the deal's landing stage for a
--            multi-deposit remittance. A burst (v_n=2) forces that
--            branch, so this case is the only one that would catch a
--            110 that dual-wrote cerebro_cruzar_deposito's own site but
--            missed cerebro_cruzar_depositos' distinct one.
--
-- NOT covered here, on purpose: the "sumado" UPDATE deals site inside
-- cerebro_registrar_deposito (~93 relative — the running-balance top-up
-- path) and the brand-new-deal INSERT path's dual-write both need
-- machinery this file deliberately does not reach for — see 110's
-- header for why (short version: the "sumado" path needs a live
-- cerebro_objetivo_envio target, a table with no versioned schema
-- anywhere in this repo's migrations, and the INSERT path's dual-write
-- structurally cannot be exercised under a disabled bridge, because
-- disabling the bridge is what stops the operation row from being
-- created in the first place — there is nothing else in
-- cerebro_registrar_deposito that creates it). 110 still adds the dual
-- write to both sites; this file just cannot be the thing that proves
-- them.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK.
-- Never COMMIT. Never run against production. Builds its own fixtures
-- (pipeline/stages via ON CONFLICT DO NOTHING, same ids as
-- deposit-review.sql) so it can run alongside or independently of the
-- other assertion files.

SAVEPOINT n8n_repoint;

DO $$
DECLARE
  v_account_id     uuid;
  v_owner_user     uuid := gen_random_uuid();
  v_dummy_hash     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_pipeline_id    CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_solicitada     CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_por_verificar  CONSTANT uuid := '3cf01654-cd27-47c1-ac92-62abf5435751';
  v_lista          CONSTANT uuid := 'f5cf87f8-b570-4d71-b6ea-a3cafd458c63';
  v_incidencia     CONSTANT uuid := 'da7b3e24-9222-4150-8be8-d7f7378e16aa';
  v_pipeline_owner uuid;

  -- case 1/2: cerebro_registrar_deposito, one conversation+deal each so
  -- v_ex (scoped to conversation_id) never crosses cases.
  v_contact_a uuid; v_conv_a uuid; v_deal_a1 uuid; v_op_a1 uuid;
  v_contact_b uuid; v_conv_b uuid; v_deal_b1 uuid; v_op_b1 uuid;

  -- case 3: cerebro_cruzar_deposito direct call.
  v_contact_c uuid; v_conv_c uuid; v_deal_c1 uuid; v_op_c1 uuid;
  v_ref_c3    CONSTANT text := '99711000000001';

  -- case 4: cerebro_cruzar_depositos burst (n=2, no objetivo target).
  v_contact_d uuid; v_conv_d uuid; v_deal_d1 uuid; v_op_d1 uuid;
  v_ref_d1    CONSTANT text := '99711000000011';
  v_ref_d2    CONSTANT text := '99711000000012';

  v_out_deal   uuid;
  v_out_accion text;
  v_stage      uuid;
  v_op_status  text;
  v_notes      text;

  v_res        text;
  v_metodo     text;
  v_todos      boolean;

  v_dep_deal   uuid;
  v_dep_cons   timestamptz;

  v_fail_count integer := 0;
BEGIN
  -- ---- fixtures ---------------------------------------------------------
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'n8n-repoint-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'n8n repoint test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'n8n repoint owner', 'n8n-repoint-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_solicitada, v_pipeline_id, 'Solicitada', 30) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_por_verificar, v_pipeline_id, 'Por verificar', 40) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_lista, v_pipeline_id, 'Lista para transferir', 50) ON CONFLICT (id) DO NOTHING;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_incidencia, v_pipeline_id, 'Incidencia', 90) ON CONFLICT (id) DO NOTHING;

  -- notify_deal_insert() / notify_deal_stage_change() (pre-existing
  -- triggers, unrelated to 110) fire on every deals INSERT / stage UPDATE
  -- and need a non-null notify_url; point them at a loopback no-op. Our
  -- own transaction never commits, so pg_net's worker never actually
  -- dispatches these.
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_url', 'http://127.0.0.1:1/n8n-repoint-noop') ON CONFLICT (clave) DO NOTHING;
  INSERT INTO cerebro_config (clave, valor) VALUES ('notify_secret', 'n8n-repoint-noop') ON CONFLICT (clave) DO NOTHING;

  -- deal A1 (case 1): open, "Solicitada" (collecting_information), no
  -- DEPOSITO/BENEFICIARIO in notes yet — the exact shape cerebro_v_ex
  -- looks for.
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000601', v_account_id) RETURNING id INTO v_contact_a;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_a, v_account_id) RETURNING id INTO v_conv_a;
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency, notes)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_solicitada, 'n8n repoint fixture a1', v_account_id, v_conv_a, v_contact_a, 0, 'GYD', 'Cliente solicito remesa')
  RETURNING id INTO v_deal_a1;
  SELECT id INTO v_op_a1 FROM remittance_operations WHERE deal_id = v_deal_a1;
  IF v_op_a1 IS NULL THEN
    RAISE EXCEPTION 'n8n-repoint: fixture setup failed — no operation created for deal %', v_deal_a1;
  END IF;

  -- deal B1 (case 2): same shape as A1, own conversation.
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000602', v_account_id) RETURNING id INTO v_contact_b;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_b, v_account_id) RETURNING id INTO v_conv_b;
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency, notes)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_solicitada, 'n8n repoint fixture b1', v_account_id, v_conv_b, v_contact_b, 0, 'GYD', 'Cliente solicito remesa')
  RETURNING id INTO v_deal_b1;
  SELECT id INTO v_op_b1 FROM remittance_operations WHERE deal_id = v_deal_b1;
  IF v_op_b1 IS NULL THEN
    RAISE EXCEPTION 'n8n-repoint: fixture setup failed — no operation created for deal %', v_deal_b1;
  END IF;

  -- deal C1 (case 3): "Por verificar", one exact-match unconsumed
  -- deposito.
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000603', v_account_id) RETURNING id INTO v_contact_c;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_c, v_account_id) RETURNING id INTO v_conv_c;
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'n8n repoint fixture c1', v_account_id, v_conv_c, v_contact_c, 18000, 'GYD')
  RETURNING id INTO v_deal_c1;
  SELECT id INTO v_op_c1 FROM remittance_operations WHERE deal_id = v_deal_c1;
  IF v_op_c1 IS NULL THEN
    RAISE EXCEPTION 'n8n-repoint: fixture setup failed — no operation created for deal %', v_deal_c1;
  END IF;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, gmail_message_id)
  VALUES (v_ref_c3, 18000, 'GYD', 'Deposito de prueba - n8n-repoint case 3', now() - interval '5 minutes', 'gm-n8n-repoint-c3-001');

  -- deal D1 (case 4): "Por verificar", TWO exact-match unconsumed
  -- depositos, no cerebro_objetivo_envio row for this conversation.
  INSERT INTO contacts (id, user_id, phone, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550000604', v_account_id) RETURNING id INTO v_contact_d;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_d, v_account_id) RETURNING id INTO v_conv_d;
  INSERT INTO deals (id, user_id, pipeline_id, stage_id, title, account_id, conversation_id, contact_id, value, currency)
  VALUES (gen_random_uuid(), v_owner_user, v_pipeline_id, v_por_verificar, 'n8n repoint fixture d1', v_account_id, v_conv_d, v_contact_d, 15000, 'GYD')
  RETURNING id INTO v_deal_d1;
  SELECT id INTO v_op_d1 FROM remittance_operations WHERE deal_id = v_deal_d1;
  IF v_op_d1 IS NULL THEN
    RAISE EXCEPTION 'n8n-repoint: fixture setup failed — no operation created for deal %', v_deal_d1;
  END IF;
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, gmail_message_id)
  VALUES (v_ref_d1, 9000, 'GYD', 'Deposito de prueba - n8n-repoint case 4a', now() - interval '5 minutes', 'gm-n8n-repoint-c4-001');
  INSERT INTO depositos_mmg (trans_id, monto, moneda, asunto, recibido_en, gmail_message_id)
  VALUES (v_ref_d2, 6000, 'GYD', 'Deposito de prueba - n8n-repoint case 4b', now() - interval '5 minutes', 'gm-n8n-repoint-c4-002');

  -- ---- THE POINT: disable the bridge before calling anything under test
  ALTER TABLE deals DISABLE TRIGGER trg_sync_operacion_desde_deal;

  -- ---- case 1: registrar_deposito, "movido" -> Por verificar ------------
  SELECT r.deal_id, r.accion INTO v_out_deal, v_out_accion
    FROM cerebro_registrar_deposito(v_conv_a, 7000, 'GYD', v_por_verificar,
                                     'DEPOSITO: 7,000 GYD - primer envio', NULL) r;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_a1;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_a1;

  IF v_out_deal IS DISTINCT FROM v_deal_a1
     OR v_out_accion IS DISTINCT FROM 'movido'
     OR v_stage IS DISTINCT FROM v_por_verificar
     OR v_op_status IS DISTINCT FROM 'deposit_verification'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] expected accion=movido, deal in Por verificar, and remittance_operations.status=deposit_verification WITH THE BRIDGE DISABLED; got accion=%, stage=%, op_status=%', v_out_accion, v_stage, v_op_status;
  ELSE
    RAISE NOTICE 'PASS [case 1] cerebro_registrar_deposito moves the open deal to Por verificar and writes remittance_operations.status directly';
  END IF;

  -- ---- case 2: registrar_deposito, REFERENCIA IMPOSIBLE -> Incidencia ---
  SELECT r.deal_id, r.accion INTO v_out_deal, v_out_accion
    FROM cerebro_registrar_deposito(v_conv_b, 6000, 'GYD', v_por_verificar,
                                     'DEPOSITO: 6,000 GYD' || chr(10) || 'Ref: 100', NULL) r;

  SELECT stage_id, notes INTO v_stage, v_notes FROM deals WHERE id = v_deal_b1;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_b1;

  IF v_out_deal IS DISTINCT FROM v_deal_b1
     OR v_out_accion IS DISTINCT FROM 'movido'
     OR v_stage IS DISTINCT FROM v_incidencia
     OR v_notes NOT LIKE '%REFERENCIA IMPOSIBLE%'
     OR v_op_status IS DISTINCT FROM 'incident'
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] expected accion=movido, deal in Incidencia with a REFERENCIA IMPOSIBLE note, and remittance_operations.status=incident WITH THE BRIDGE DISABLED; got accion=%, stage=%, op_status=%, notes=%', v_out_accion, v_stage, v_op_status, v_notes;
  ELSE
    RAISE NOTICE 'PASS [case 2] an implausible TransID forces the deal to Incidencia and writes remittance_operations.status directly';
  END IF;

  -- ---- case 3: cerebro_cruzar_deposito, exact match -> Lista ------------
  SELECT c.resultado, c.metodo INTO v_res, v_metodo
    FROM cerebro_cruzar_deposito(v_deal_c1, v_ref_c3, 18000, v_lista, v_incidencia, v_por_verificar, false) c;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_c1;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_c1;
  SELECT deal_id, consumido_en INTO v_dep_deal, v_dep_cons FROM depositos_mmg WHERE trans_id = v_ref_c3;

  IF v_res IS DISTINCT FROM 'verificado'
     OR v_stage IS DISTINCT FROM v_lista
     OR v_op_status IS DISTINCT FROM 'ready_to_transfer'
     OR v_dep_deal IS DISTINCT FROM v_deal_c1
     OR v_dep_cons IS NULL
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] expected resultado=verificado, deal in Lista para transferir, remittance_operations.status=ready_to_transfer, and the deposit consumed WITH THE BRIDGE DISABLED; got resultado=%, stage=%, op_status=%, dep_deal=%, dep_consumed=%', v_res, v_stage, v_op_status, v_dep_deal, v_dep_cons;
  ELSE
    RAISE NOTICE 'PASS [case 3] cerebro_cruzar_deposito verifies the exact match, moves the deal to Lista para transferir, and writes remittance_operations.status directly';
  END IF;

  -- ---- case 4: cerebro_cruzar_depositos, 2-item burst -> Lista ----------
  SELECT c.resultado, c.todos_verificados INTO v_res, v_todos
    FROM cerebro_cruzar_depositos(v_deal_d1, ARRAY[v_ref_d1, v_ref_d2], ARRAY[9000::numeric, 6000::numeric],
                                   v_lista, v_incidencia, v_por_verificar, false) c;

  SELECT stage_id INTO v_stage FROM deals WHERE id = v_deal_d1;
  SELECT status INTO v_op_status FROM remittance_operations WHERE id = v_op_d1;

  IF v_res IS DISTINCT FROM 'verificado'
     OR v_todos IS DISTINCT FROM true
     OR v_stage IS DISTINCT FROM v_lista
     OR v_op_status IS DISTINCT FROM 'ready_to_transfer'
     OR NOT EXISTS (SELECT 1 FROM depositos_mmg WHERE trans_id = v_ref_d1 AND deal_id = v_deal_d1 AND consumido_en IS NOT NULL)
     OR NOT EXISTS (SELECT 1 FROM depositos_mmg WHERE trans_id = v_ref_d2 AND deal_id = v_deal_d1 AND consumido_en IS NOT NULL)
  THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 4] expected resultado=verificado, todos_verificados=true, deal in Lista para transferir, remittance_operations.status=ready_to_transfer, and both deposits consumed WITH THE BRIDGE DISABLED; got resultado=%, todos=%, stage=%, op_status=%', v_res, v_todos, v_stage, v_op_status;
  ELSE
    RAISE NOTICE 'PASS [case 4] cerebro_cruzar_depositos'' OWN final write (the burst path, not delegated to cerebro_cruzar_deposito''s per-item call) moves the deal to Lista para transferir and writes remittance_operations.status directly';
  END IF;

  -- ---- re-enable the bridge before finishing -----------------------------
  ALTER TABLE deals ENABLE TRIGGER trg_sync_operacion_desde_deal;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'n8n-repoint: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'n8n-repoint: ALL PASS (4 cases)';
END $$;

-- ROLLBACK TO SAVEPOINT below undoes every statement since SAVEPOINT
-- n8n_repoint, including the ALTER TABLE ... DISABLE TRIGGER above — DDL
-- trigger enable state is transactional in Postgres — so the bridge
-- comes back enabled here whether the DO block above passed, failed a
-- real expectation, or raised on a fixture setup failure. No separate
-- re-enable statement is needed (or safe to run: a RAISE EXCEPTION
-- inside the DO block leaves this subtransaction aborted, and nothing
-- but ROLLBACK / ROLLBACK TO SAVEPOINT is valid until this line runs).
ROLLBACK TO SAVEPOINT n8n_repoint;
