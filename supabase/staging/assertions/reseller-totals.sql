\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 397 (reseller totals: derived period totals,
-- append-only resets and adjustments, five RPCs).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs.
-- Run it alone on staging (wrapped by staging-migracion.sh, or by hand as
-- BEGIN; \i this file; ROLLBACK;).
--
-- RED before 397: the first reference to crm_revendedores_resumen or to
-- reseller_counter_resets fails because neither exists yet.
--
-- Fixture: account A with owner/admin/agent/viewer/stranger and account B.
--   r1 reseller (tag), r2 reseller with no activity, r3 contact with no tag,
--   rb reseller of account B.
--   Pre-reset r1 operations: six qualifying statuses 100..600, a qualifying
--   NULL amount, plus cancelled / awaiting_deposit / collecting_information /
--   non-GYD / other-contact / other-account rows that must never count.
--   After the first reset: a boundary op one microsecond BEFORE the marker
--   (excluded), one exactly AT the marker (included), two after it, and an
--   adjustment dated before the marker (belongs to the closed period).
--
-- Cases:
--   1 counts qualifying statuses only (sum, count, missing amount); viewer
--     and agent may read; a stranger is refused with 42501
--   2 detail: is_reseller, empty history before any reset
--   3 single reset records the snapshot, restarts the counter and audits
--   4 a stale expected amount raises 40001 and applies nothing
--   5 the boundary around the reset marker is half-open [start, end)
--   6 adjustments +100 / -50 change the current total and audit
--   7 closed period history: live derived total vs closed snapshot
--   8 ledger tables are append-only and not writable by API roles
--   9 reset all skips zero-total resellers, one batch, one marker per closed
--  10 stale reset-all total raises 40001 with no marker; no resellers is 0
--  11 reset and adjustments leave every operation row untouched (md5)
--  12 untag/retag keeps history; untagged contact leaves the list and grand
--  13 agent and viewer cannot write; empty period is zero
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_owner     uuid := gen_random_uuid();
  v_admin     uuid := gen_random_uuid();
  v_agent     uuid := gen_random_uuid();
  v_viewer    uuid := gen_random_uuid();
  v_stranger  uuid := gen_random_uuid();
  v_owner_b   uuid := gen_random_uuid();
  v_account   uuid;
  v_account_b uuid;
  v_tag_res   uuid;
  v_tag_res_b uuid;
  v_r1        uuid;
  v_r2        uuid;
  v_r3        uuid;
  v_rb        uuid;
  v_conv_r1   uuid;
  v_conv_r3   uuid;
  v_conv_rb   uuid;
  v_link_r1   uuid;
  v_dummy     CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';
  v_t0        timestamptz;

  v_json      jsonb;
  v_entry     jsonb;
  v_current   jsonb;
  v_reset     jsonb;
  v_reset_at  timestamptz;
  v_batch     uuid;
  v_id        uuid;
  v_grand     numeric;
  v_ops_md5   text;
  v_ops_after text;
  v_count     integer;
  v_count2    integer;
  v_msg       text;
  e           jsonb;
  i           integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  v_t0 := clock_timestamp();

  -- ---- fixtures ----
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tot397-owner-'||v_owner||'@test.invalid', v_dummy, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tot397-admin-'||v_admin||'@test.invalid', v_dummy, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent,    '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tot397-agent-'||v_agent||'@test.invalid', v_dummy, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_viewer,   '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tot397-viewer-'||v_viewer||'@test.invalid', v_dummy, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_stranger, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tot397-stranger-'||v_stranger||'@test.invalid', v_dummy, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_owner_b,  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'tot397-ownerb-'||v_owner_b||'@test.invalid', v_dummy, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'tot397 account A', v_owner) RETURNING id INTO v_account;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'tot397 account B', v_owner_b) RETURNING id INTO v_account_b;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner,    'tot owner',    'tot397-owner-'||v_owner||'@test.invalid',       v_account, 'owner'),
    (gen_random_uuid(), v_admin,    'tot admin',    'tot397-admin-'||v_admin||'@test.invalid',       v_account, 'admin'),
    (gen_random_uuid(), v_agent,    'tot agent',    'tot397-agent-'||v_agent||'@test.invalid',       v_account, 'agent'),
    (gen_random_uuid(), v_viewer,   'tot viewer',   'tot397-viewer-'||v_viewer||'@test.invalid',     v_account, 'viewer'),
    (gen_random_uuid(), v_owner_b,  'tot ownerb',   'tot397-ownerb-'||v_owner_b||'@test.invalid',    v_account_b, 'owner');

  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner, v_account, 'Revendedor') RETURNING id INTO v_tag_res;
  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner_b, v_account_b, 'Revendedor') RETURNING id INTO v_tag_res_b;

  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_account, '59939700001', 'tot r1') RETURNING id INTO v_r1;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_account, '59939700002', 'tot r2') RETURNING id INTO v_r2;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner, v_account, '59939700003', 'tot r3') RETURNING id INTO v_r3;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_b, v_account_b, '59939700004', 'tot rb') RETURNING id INTO v_rb;

  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_r1, v_tag_res) RETURNING id INTO v_link_r1;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_r2, v_tag_res);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_rb, v_tag_res_b);

  -- One conversation per contact: 320's AFTER INSERT trigger seeds
  -- cerebro_objetivo_envio from the operation's conversation_id, which
  -- carries a foreign key to conversations.
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_r1, v_account) RETURNING id INTO v_conv_r1;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner, v_r3, v_account) RETURNING id INTO v_conv_r3;
  INSERT INTO conversations (id, user_id, contact_id, account_id) VALUES (gen_random_uuid(), v_owner_b, v_rb, v_account_b) RETURNING id INTO v_conv_rb;

  -- Operations are inserted by a member so 096's completion guard accepts a
  -- real 'completed' status instead of coercing it to incident.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);

  INSERT INTO remittance_operations (id, status, account_id, conversation_id, contact_id, service_type,
         source_country, source_currency, destination_currency, delivery_method, quoted_source_amount, created_at, updated_at)
  SELECT gen_random_uuid(), v.status, v.acc, v.conv, v.contact, 'remesa',
         'GY', v.cur, 'CUP', 'cuban_card', v.amount, v.created_at, v.created_at
    FROM (VALUES
      ('deposit_received',      v_conv_r1, v_r1, v_account,   'GYD', 100::numeric,  v_t0 - interval '10 hour'),
      ('deposit_verification',  v_conv_r1, v_r1, v_account,   'GYD', 200::numeric,  v_t0 - interval '9 hour'),
      ('ready_to_transfer',     v_conv_r1, v_r1, v_account,   'GYD', 300::numeric,  v_t0 - interval '8 hour'),
      ('transferring',          v_conv_r1, v_r1, v_account,   'GYD', 400::numeric,  v_t0 - interval '7 hour'),
      ('completed',             v_conv_r1, v_r1, v_account,   'GYD', 500::numeric,  v_t0 - interval '6 hour'),
      ('incident',              v_conv_r1, v_r1, v_account,   'GYD', 600::numeric,  v_t0 - interval '5 hour'),
      ('deposit_received',      v_conv_r1, v_r1, v_account,   'GYD', NULL,          v_t0 - interval '4 hour'),
      ('cancelled',             v_conv_r1, v_r1, v_account,   'GYD', 1000::numeric, v_t0 - interval '3 hour'),
      ('awaiting_deposit',      v_conv_r1, v_r1, v_account,   'GYD', 1100::numeric, v_t0 - interval '2 hour'),
      ('collecting_information',v_conv_r1, v_r1, v_account,   'GYD', 1200::numeric, v_t0 - interval '1 hour'),
      ('completed',             v_conv_r1, v_r1, v_account,   'USD', 1300::numeric, v_t0 - interval '1 hour'),
      ('completed',             v_conv_r3, v_r3, v_account,   'GYD', 9000::numeric, v_t0 - interval '1 hour'),
      ('completed',             v_conv_rb, v_rb, v_account_b, 'GYD', 7000::numeric, v_t0 - interval '1 hour')
    ) v(status, conv, contact, acc, cur, amount, created_at);

  -- ---- 1. qualifying operations only; viewer/agent read; stranger refused ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  v_json := crm_revendedores_resumen(v_account);
  IF (v_json->'grand'->>'total_gyd')::numeric <> 2100
     OR (v_json->'grand'->>'operations_gyd')::numeric <> 2100
     OR (v_json->'grand'->>'adjustments_gyd')::numeric <> 0
     OR (v_json->'grand'->>'resellers')::int <> 2 THEN
    RAISE EXCEPTION 'case 1: grand must be 2100 over 2 resellers, got %', v_json->'grand';
  END IF;
  IF jsonb_array_length(v_json->'resellers') <> 2 THEN
    RAISE EXCEPTION 'case 1: exactly r1 and r2 must be listed (r3 and rb excluded), got %', v_json->'resellers';
  END IF;
  IF (v_json->'resellers'->0->>'contact_id') <> v_r1::text THEN
    RAISE EXCEPTION 'case 1: the list must be ordered by total DESC with r1 first, got %', v_json->'resellers';
  END IF;
  v_entry := NULL;
  FOR e IN SELECT * FROM jsonb_array_elements(v_json->'resellers') LOOP
    IF e->>'contact_id' = v_r1::text THEN v_entry := e; END IF;
  END LOOP;
  IF v_entry IS NULL
     OR (v_entry->>'operations_gyd')::numeric <> 2100
     OR (v_entry->>'operations_count')::int <> 7
     OR (v_entry->>'operations_missing_amount')::int <> 1
     OR (v_entry->>'adjustments_gyd')::numeric <> 0
     OR (v_entry->>'period_start') IS NOT NULL THEN
    RAISE EXCEPTION 'case 1: r1 must be 2100 / 7 ops / 1 missing / no adjustments / first period, got %', v_entry;
  END IF;
  RAISE NOTICE 'PASS 1: qualifying statuses only; viewer reads the summary';

  -- agent reads too
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent, 'role', 'authenticated')::text, true);
  v_json := crm_revendedores_resumen(v_account);
  IF (v_json->'grand'->>'total_gyd')::numeric <> 2100 THEN
    RAISE EXCEPTION 'case 1: an agent must be able to read the grand total, got %', v_json->'grand';
  END IF;

  -- a stranger is refused
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM crm_revendedores_resumen(v_account);
    RAISE EXCEPTION 'case 1: a stranger must not read the account totals';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  RAISE NOTICE 'PASS 1b: agent reads; stranger refused with 42501';

  -- ---- 2. detail before any reset ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  v_json := crm_revendedor_detalle(v_r1);
  IF (v_json->>'is_reseller')::boolean IS DISTINCT FROM true
     OR (v_json->'current'->>'total_gyd')::numeric <> 2100
     OR jsonb_array_length(v_json->'current'->'adjustments') <> 0
     OR jsonb_array_length(v_json->'periods') <> 0 THEN
    RAISE EXCEPTION 'case 2: fresh detail must be 2100 with no adjustments and no history, got %', v_json;
  END IF;
  RAISE NOTICE 'PASS 2: detail basics before any reset';

  -- ---- 3. single reset records the snapshot and restarts the counter ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_reset := crm_revendedor_reiniciar(v_r1, 'cierre de prueba', 2100);
  v_reset_at := (v_reset->>'reset_at')::timestamptz;
  IF (v_reset->'closed'->>'operations_gyd')::numeric <> 2100
     OR (v_reset->'closed'->>'adjustments_gyd')::numeric <> 0
     OR (v_reset->'closed'->>'total_gyd')::numeric <> 2100 THEN
    RAISE EXCEPTION 'case 3: the reset must close 2100 with no adjustments, got %', v_reset;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_counter_resets WHERE contact_id = v_r1 AND account_id = v_account;
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 3: expected one marker, got %', v_count; END IF;
  v_json := crm_revendedores_resumen(v_account);
  IF (v_json->'grand'->>'total_gyd')::numeric <> 0 THEN
    RAISE EXCEPTION 'case 3: after reset the grand total must be 0, got %', v_json->'grand';
  END IF;
  RAISE NOTICE 'PASS 3: reset closes the period and restarts the counter';

  -- ---- 4. a stale expected amount is refused and applies nothing ----
  BEGIN
    PERFORM crm_revendedor_reiniciar(v_r1, NULL, 999);
    RAISE EXCEPTION 'case 4: a stale expected amount must raise 40001';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
  SELECT count(*) INTO v_count FROM reseller_counter_resets WHERE contact_id = v_r1 AND account_id = v_account;
  IF v_count <> 1 THEN RAISE EXCEPTION 'case 4: the refused reset must not add a marker, got %', v_count; END IF;
  RAISE NOTICE 'PASS 4: stale expected amount refused with 40001 and nothing applied';

  -- ---- 5. half-open boundary around the reset marker ----
  INSERT INTO remittance_operations (id, status, account_id, conversation_id, contact_id, service_type,
         source_country, source_currency, destination_currency, delivery_method, quoted_source_amount, created_at, updated_at)
  SELECT gen_random_uuid(), v.status, v_account, v_conv_r1, v_r1, 'remesa',
         'GY', 'GYD', 'CUP', 'cuban_card', v.amount, v.created_at, v.created_at
    FROM (VALUES
      ('completed',        99999::numeric, v_reset_at - interval '1 microsecond'),  -- BEFORE marker: excluded
      ('deposit_received', 50::numeric,    v_reset_at),                            -- AT marker: included
      ('completed',        60::numeric,    v_reset_at + interval '1 microsecond'),
      ('incident',         70::numeric,    v_reset_at + interval '2 microsecond')
    ) v(status, amount, created_at);
  -- An adjustment dated before the marker belongs to the closed period.
  INSERT INTO reseller_total_adjustments (account_id, contact_id, amount_gyd, reason, actor, created_at)
  VALUES (v_account, v_r1, 5000, 'ajuste del periodo cerrado', 'assertion', v_reset_at - interval '1 microsecond');

  v_json := crm_revendedor_detalle(v_r1);
  v_current := v_json->'current';
  IF (v_current->>'operations_gyd')::numeric <> 180
     OR (v_current->>'operations_count')::int <> 3
     OR (v_current->>'adjustments_gyd')::numeric <> 0
     OR (v_current->>'total_gyd')::numeric <> 180 THEN
    RAISE EXCEPTION 'case 5: the post-reset period must be 180 over 3 ops and exclude the boundary-before op, got %', v_current;
  END IF;
  RAISE NOTICE 'PASS 5: half-open [start, end) boundary around the reset marker';

  -- ---- 6. adjustments change the current total and audit ----
  v_reset := crm_revendedor_ajustar(v_r1, 100, 'ajuste positivo');
  IF (v_reset->>'total_before_gyd')::numeric <> 180 OR (v_reset->>'total_after_gyd')::numeric <> 280 THEN
    RAISE EXCEPTION 'case 6: +100 must move 180 -> 280, got %', v_reset;
  END IF;
  v_reset := crm_revendedor_ajustar(v_r1, -50, NULL);
  IF (v_reset->>'total_before_gyd')::numeric <> 280 OR (v_reset->>'total_after_gyd')::numeric <> 230 THEN
    RAISE EXCEPTION 'case 6: -50 must move 280 -> 230, got %', v_reset;
  END IF;
  SELECT count(*) INTO v_count FROM remittance_admin_audit
   WHERE action = 'human_reseller_adjustment' AND account_id = v_account AND actor = v_admin::text;
  IF v_count <> 2 THEN RAISE EXCEPTION 'case 6: two adjustment audit rows expected, got %', v_count; END IF;
  BEGIN
    PERFORM crm_revendedor_ajustar(v_r1, 0, NULL);
    RAISE EXCEPTION 'case 6: a zero adjustment must be refused';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL; END;
  RAISE NOTICE 'PASS 6: signed adjustments change the total, audit, and zero is refused';

  -- ---- 7. closed period history: live total vs closed snapshot ----
  v_json := crm_revendedor_detalle(v_r1);
  v_current := v_json->'current';
  IF (v_current->>'operations_gyd')::numeric <> 180
     OR (v_current->>'adjustments_gyd')::numeric <> 50
     OR (v_current->>'adjustments_count')::int <> 2
     OR (v_current->>'total_gyd')::numeric <> 230
     OR jsonb_array_length(v_current->'adjustments') <> 2
     OR (v_current->'adjustments'->0->>'amount_gyd')::numeric <> -50 THEN
    RAISE EXCEPTION 'case 7: current must be 180 ops + 50 adj = 230 with adjustments newest first, got %', v_current;
  END IF;
  IF jsonb_array_length(v_json->'periods') <> 1 THEN
    RAISE EXCEPTION 'case 7: exactly one closed period expected, got %', v_json->'periods';
  END IF;
  v_entry := v_json->'periods'->0;
  IF (v_entry->>'operations_gyd')::numeric <> 102099
     OR (v_entry->>'adjustments_gyd')::numeric <> 5000
     OR (v_entry->>'total_gyd')::numeric <> 107099
     OR (v_entry->>'closed_total_gyd')::numeric <> 2100
     OR (v_entry->>'start') IS NOT NULL
     OR (v_entry->>'end')::timestamptz <> v_reset_at
     OR v_entry->>'reason' <> 'cierre de prueba'
     OR v_entry->>'reset_by_name' <> 'tot admin' THEN
    RAISE EXCEPTION 'case 7: closed period must be live 107099 (2100 + the boundary-before 99999 + 5000 adj) / snapshot 2100 with actor and reason, got %', v_entry;
  END IF;
  RAISE NOTICE 'PASS 7: history shows the live closed total and the closed snapshot';

  -- ---- 8. append-only ledger and API privileges ----
  BEGIN
    UPDATE reseller_total_adjustments SET reason = 'tampered' WHERE contact_id = v_r1;
    RAISE EXCEPTION 'case 8: update of an adjustment must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  IF has_table_privilege('authenticated', 'public.reseller_total_adjustments', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.reseller_total_adjustments', 'DELETE')
     OR has_table_privilege('authenticated', 'public.reseller_total_adjustments', 'INSERT')
     OR NOT has_table_privilege('authenticated', 'public.reseller_total_adjustments', 'SELECT') THEN
    RAISE EXCEPTION 'case 8: adjustment table grants are wrong';
  END IF;
  IF has_table_privilege('authenticated', 'public.reseller_counter_resets', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.reseller_counter_resets', 'DELETE')
     OR has_table_privilege('authenticated', 'public.reseller_counter_resets', 'INSERT')
     OR NOT has_table_privilege('authenticated', 'public.reseller_counter_resets', 'SELECT') THEN
    RAISE EXCEPTION 'case 8: reset table grants are wrong';
  END IF;
  IF NOT has_function_privilege('authenticated', 'public.crm_revendedores_resumen(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crm_revendedores_resumen(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.crm_revendedor_ajustar(uuid, numeric, text)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._reseller_period_totals(uuid, uuid, timestamptz, timestamptz)', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 8: RPC/helper grants are wrong';
  END IF;

  -- RLS: a member sees the rows, a stranger sees none.
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
    SET LOCAL ROLE authenticated;
    SELECT count(*) INTO v_count FROM reseller_total_adjustments WHERE contact_id = v_r1;
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_stranger, 'role', 'authenticated')::text, true);
    SELECT count(*) INTO v_count2 FROM reseller_total_adjustments WHERE contact_id = v_r1;
    RESET ROLE;
    IF v_count <> 3 OR v_count2 <> 0 THEN
      RAISE EXCEPTION 'case 8: RLS must show 3 adjustments to a member and 0 to a stranger, got % and %', v_count, v_count2;
    END IF;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RAISE;
  END;
  RAISE NOTICE 'PASS 8: append-only ledger, no write grants, RLS by membership';

  -- ---- 9/10. reset all skips zeros, one batch; stale total refused ----
  v_ops_md5 := (SELECT md5(string_agg(o::text, '|' ORDER BY o.id)) FROM remittance_operations o WHERE o.account_id = v_account);

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  v_reset := crm_revendedores_reiniciar_todos(v_account, 'reset total', 230);
  v_batch := (v_reset->>'batch_id')::uuid;
  IF (v_reset->>'count')::int <> 1
     OR (v_reset->>'grand_total_gyd')::numeric <> 230
     OR v_batch IS NULL
     OR jsonb_array_length(v_reset->'resets') <> 1
     OR (v_reset->'resets'->0->>'contact_id') <> v_r1::text
     OR (v_reset->'resets'->0->>'total_gyd')::numeric <> 230 THEN
    RAISE EXCEPTION 'case 9: reset all must close only r1 (230) in one batch, got %', v_reset;
  END IF;
  SELECT count(*) INTO v_count FROM reseller_counter_resets WHERE contact_id = v_r1 AND account_id = v_account AND batch_id = v_batch;
  SELECT count(*) INTO v_count2 FROM reseller_counter_resets WHERE contact_id = v_r2 AND account_id = v_account;
  IF v_count <> 1 OR v_count2 <> 0 THEN
    RAISE EXCEPTION 'case 9: r1 needs one batch marker and r2 (zero) must be skipped, got % / %', v_count, v_count2;
  END IF;
  SELECT count(*) INTO v_count FROM remittance_admin_audit
   WHERE action = 'human_reseller_counter_reset' AND account_id = v_account AND actor = v_admin::text
     AND after->>'batch_id' = v_batch::text;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'case 9: the reset-all marker must be audited with its batch id, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 9: reset all skips zero-total resellers and shares one batch';

  v_json := crm_revendedores_resumen(v_account);
  IF (v_json->'grand'->>'total_gyd')::numeric <> 0 THEN
    RAISE EXCEPTION 'case 9: after reset all the grand total must be 0, got %', v_json->'grand';
  END IF;

  SELECT count(*) INTO v_count FROM reseller_counter_resets WHERE account_id = v_account;
  BEGIN
    PERFORM crm_revendedores_reiniciar_todos(v_account, NULL, 999);
    RAISE EXCEPTION 'case 10: a stale reset-all total must raise 40001';
  EXCEPTION WHEN SQLSTATE '40001' THEN NULL; END;
  SELECT count(*) INTO v_count2 FROM reseller_counter_resets WHERE account_id = v_account;
  IF v_count2 <> v_count THEN
    RAISE EXCEPTION 'case 10: the refused reset all must add no marker, % -> %', v_count, v_count2;
  END IF;
  v_reset := crm_revendedores_reiniciar_todos(v_account, NULL, 0);
  IF (v_reset->>'count')::int <> 0 OR jsonb_array_length(v_reset->'resets') <> 0 THEN
    RAISE EXCEPTION 'case 10: reset all over zeros must write nothing, got %', v_reset;
  END IF;
  RAISE NOTICE 'PASS 10: stale reset-all refused; all-zero reset all writes nothing';

  -- ---- 11. operations untouched by resets and adjustments ----
  v_ops_after := (SELECT md5(string_agg(o::text, '|' ORDER BY o.id)) FROM remittance_operations o WHERE o.account_id = v_account);
  IF v_ops_after IS DISTINCT FROM v_ops_md5 THEN
    RAISE EXCEPTION 'case 11: resets/adjustments must not change any operation row (% vs %)', v_ops_md5, v_ops_after;
  END IF;
  RAISE NOTICE 'PASS 11: operation rows are byte-identical before and after the writes';

  -- ---- 12. untag/retag keeps history ----
  PERFORM set_config('request.jwt.claims', '', true);
  DELETE FROM contact_tags WHERE id = v_link_r1;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  v_json := crm_revendedores_resumen(v_account);
  IF jsonb_array_length(v_json->'resellers') <> 1
     OR (v_json->'resellers'->0->>'contact_id') <> v_r2::text
     OR (v_json->'grand'->>'resellers')::int <> 1 THEN
    RAISE EXCEPTION 'case 12: an untagged contact must leave the list and grand, got %', v_json;
  END IF;
  v_json := crm_revendedor_detalle(v_r1);
  IF (v_json->>'is_reseller')::boolean IS DISTINCT FROM false
     OR jsonb_array_length(v_json->'periods') <> 2 THEN
    RAISE EXCEPTION 'case 12: an untagged contact keeps its history but is_reseller is false, got %', v_json;
  END IF;
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_r1, v_tag_res);
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  v_json := crm_revendedor_detalle(v_r1);
  IF (v_json->>'is_reseller')::boolean IS DISTINCT FROM true
     OR jsonb_array_length(v_json->'periods') <> 2
     OR jsonb_array_length((crm_revendedores_resumen(v_account))->'resellers') <> 2 THEN
    RAISE EXCEPTION 'case 12: retagging must restore the same history, got %', v_json;
  END IF;
  RAISE NOTICE 'PASS 12: untag removes the contact from the list; retag restores the same history';

  -- ---- 13. agents and viewers cannot write; empty period is zero ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent, 'role', 'authenticated')::text, true);
  BEGIN PERFORM crm_revendedor_ajustar(v_r1, 10, NULL); RAISE EXCEPTION 'case 13: agent adjustment must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM crm_revendedor_reiniciar(v_r1, NULL, NULL); RAISE EXCEPTION 'case 13: agent reset must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  BEGIN PERFORM crm_revendedores_reiniciar_todos(v_account, NULL, NULL); RAISE EXCEPTION 'case 13: agent reset all must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_viewer, 'role', 'authenticated')::text, true);
  BEGIN PERFORM crm_revendedor_ajustar(v_r1, 10, NULL); RAISE EXCEPTION 'case 13: viewer adjustment must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;

  v_json := crm_revendedor_detalle(v_r2);
  IF (v_json->'current'->>'total_gyd')::numeric <> 0
     OR jsonb_array_length(v_json->'periods') <> 0
     OR (v_json->>'is_reseller')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'case 13: a reseller with no activity must read zero and no history, got %', v_json;
  END IF;
  RAISE NOTICE 'PASS 13: writes are admin-only; an empty period reads zero';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
