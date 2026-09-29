-- objetivo-requiere-compromiso.sql — self-reverting assertion for
-- 148_objetivo_requiere_compromiso.sql
--
-- Proves the A3 fix: a bare quote (cerebro_fijar_objetivo called with no
-- beneficiary and no receipt on the conversation) must not persist a
-- cerebro_objetivo_envio row. Once a real commitment signal exists
-- (a vigente beneficiary, or a comprobantes_hashes row for the contact's
-- phone), the same call must persist exactly as before (075's behavior).
--
-- RED (against 072-147): case 1 FAILS — a bare quote creates the row.
-- GREEN (after 148): case 1 PASSES (no row); cases 2 and 3 (beneficiary
--   present / receipt present) still create the row — no regression.
--
-- MUST run inside an already-open transaction that ends in ROLLBACK
-- (docker exec -i wacrm-ensayo psql -U supabase_admin -d postgres,
-- wrapped in BEGIN ... \i 148 ... \i this file ... ROLLBACK, or against
-- real staging the same way). Never COMMIT. Never run against
-- production. Builds its own account/contact/conversation fixtures.

SAVEPOINT objetivo_requiere_compromiso;

DO $$
DECLARE
  v_account_id  uuid;
  v_owner_user  uuid := gen_random_uuid();
  v_dummy_hash  CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_fail_count  integer := 0;

  v_pipeline_id CONSTANT uuid := '78220927-0745-45a8-ba08-a1b33734dbf1';
  v_solicitada  CONSTANT uuid := '96cd4fec-21ec-4fe4-8b7f-2cc00f9ff109';
  v_pipeline_owner uuid;

  -- case 1: bare quote, no commitment
  v_contact_a  uuid; v_conv_a uuid;
  -- case 2: beneficiary already vigente
  v_contact_b  uuid; v_conv_b uuid; v_deal_b uuid; v_op_b uuid;
  -- case 3: receipt already sent (comprobantes_hashes by phone)
  v_contact_c  uuid; v_conv_c uuid;

  v_result     record;
  v_filas      integer;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'objetivo-compromiso-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'objetivo compromiso test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'objetivo compromiso owner', 'objetivo-compromiso-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner');

  SELECT account_id INTO v_pipeline_owner FROM pipelines WHERE id = v_pipeline_id;
  IF v_pipeline_owner IS NULL THEN
    INSERT INTO pipelines (id, user_id, name, account_id) VALUES (v_pipeline_id, v_owner_user, 'Remesas', v_account_id);
  END IF;
  INSERT INTO pipeline_stages (id, pipeline_id, name, "position") VALUES (v_solicitada, v_pipeline_id, 'Solicitada', 10) ON CONFLICT (id) DO NOTHING;

  -- ===========================================================================
  -- CASE 1 — bare quote, no beneficiary, no receipt: must NOT create anything
  -- ===========================================================================
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550001301', 'Objetivo Compromiso Cliente A', v_account_id) RETURNING id INTO v_contact_a;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_a, v_account_id) RETURNING id INTO v_conv_a;

  SELECT * INTO v_result FROM cerebro_fijar_objetivo(v_conv_a, 100, 'USD');
  SELECT count(*) INTO v_filas FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_a;

  IF v_filas <> 0 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 1] a bare quote (no beneficiary, no receipt) created a target: rows=%, accion=%', v_filas, v_result.accion;
  ELSE
    RAISE NOTICE 'PASS [case 1] a bare quote creates no cerebro_objetivo_envio row (accion=%)', v_result.accion;
  END IF;

  -- ===========================================================================
  -- CASE 2 — a vigente beneficiary already exists on this conversation's
  -- operation: the quote must still set the target (no regression).
  -- ===========================================================================
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550001302', 'Objetivo Compromiso Cliente B', v_account_id) RETURNING id INTO v_contact_b;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_b, v_account_id) RETURNING id INTO v_conv_b;
  INSERT INTO deals (user_id, account_id, contact_id, conversation_id, pipeline_id, stage_id, title, value, currency, status)
  VALUES (v_owner_user, v_account_id, v_contact_b, v_conv_b, v_pipeline_id, v_solicitada, 'Remesa +objetivocompromiso-b', 0, 'GYD', 'open')
  RETURNING id INTO v_deal_b;
  SELECT id INTO v_op_b FROM remittance_operations WHERE deal_id = v_deal_b;
  IF v_op_b IS NULL THEN
    RAISE EXCEPTION 'objetivo-requiere-compromiso: fixture setup failed — no operation for deal %', v_deal_b;
  END IF;
  INSERT INTO remittance_beneficiaries (operation_id, beneficiary_type, zelle_account, name, status, position)
  VALUES (v_op_b, 'zelle', 'compromiso-b@example.com', 'Cliente Compromiso B', 'vigente', 1);

  SELECT * INTO v_result FROM cerebro_fijar_objetivo(v_conv_b, 100, 'USD');
  SELECT count(*) INTO v_filas FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_b;

  IF v_filas <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 2] a quote WITH a vigente beneficiary should still set the target: rows=%, accion=%', v_filas, v_result.accion;
  ELSE
    RAISE NOTICE 'PASS [case 2] a quote with a vigente beneficiary still sets the target (accion=%)', v_result.accion;
  END IF;

  -- ===========================================================================
  -- CASE 3 — a receipt (comprobantes_hashes) already exists for this
  -- contact's phone: the quote must still set the target (no regression).
  -- ===========================================================================
  INSERT INTO contacts (id, user_id, phone, name, account_id) VALUES (gen_random_uuid(), v_owner_user, '15550001303', 'Objetivo Compromiso Cliente C', v_account_id) RETURNING id INTO v_contact_c;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_user, v_contact_c, v_account_id) RETURNING id INTO v_conv_c;
  INSERT INTO comprobantes_hashes (hash_imagen, cliente_whatsapp, comp_id, whatsapp_message_id)
  VALUES ('objetivo-compromiso-hash-c', '15550001303', 'COMP-objetivocompromisoc00001', 'wamid.objetivocompromisoc');

  SELECT * INTO v_result FROM cerebro_fijar_objetivo(v_conv_c, 100, 'USD');
  SELECT count(*) INTO v_filas FROM cerebro_objetivo_envio WHERE conversation_id = v_conv_c;

  IF v_filas <> 1 THEN
    v_fail_count := v_fail_count + 1;
    RAISE WARNING 'FAIL [case 3] a quote WITH a receipt already sent should still set the target: rows=%, accion=%', v_filas, v_result.accion;
  ELSE
    RAISE NOTICE 'PASS [case 3] a quote with a receipt already sent still sets the target (accion=%)', v_result.accion;
  END IF;

  -- ---- verdict ------------------------------------------------------------
  IF v_fail_count > 0 THEN
    RAISE EXCEPTION 'objetivo-requiere-compromiso: % expectation(s) FAILED — see WARNINGs above', v_fail_count;
  END IF;

  RAISE NOTICE 'objetivo-requiere-compromiso: ALL PASS';
END $$;

ROLLBACK TO SAVEPOINT objetivo_requiere_compromiso;
