\set ON_ERROR_STOP on
-- =====================================================================
-- Assertion for migration 396 (only an owner or admin may add or remove
-- the "Revendedor" contact tag when a user session exists).
-- Self-reverting: BEGIN ... ROLLBACK is in this file; any failure RAISEs.
-- Run it alone on staging (wrapped by staging-migracion.sh, or by hand as
-- BEGIN; \i this file; ROLLBACK;).
--
-- RED before 396: case 2 fails because today an agent's INSERT of the
-- reseller tag succeeds (there is no guard trigger yet), so the expected
-- 42501 never happens.
--
-- Cases:
--   1 no user session (migration / service role) may insert and delete
--     the reseller tag
--   2 an agent INSERT of the reseller tag is refused with SQLSTATE 42501,
--     a readable message and HINT reseller_tag_admin_only; no row
--   3 an agent DELETE of the reseller tag is refused and the row remains
--   4 an admin INSERT succeeds and writes one human_reseller_tag_added
--     audit row carrying the actor
--   5 an owner DELETE succeeds and writes one human_reseller_tag_removed
--     audit row carrying the actor
--   6 an agent still adds and removes a NON-reseller tag, with no
--     reseller audit row
--   7 an agent re-inserting an existing (contact_id, tag_id) pair is
--     allowed (no state change, no duplicate audit)
--   8 an agent may delete the whole contact; the cascade is allowed
--   9 an agent UPDATE that moves a reseller tag is refused
--  10 an agent no-op UPDATE of a reseller tag row is allowed
--  11 deleting the reseller tag definition cascades without a guard
--     failure
--  12 the trigger exists with the right timing/events and the function is
--     not executable by API roles
-- =====================================================================
BEGIN;

DO $$
DECLARE
  v_owner_user uuid := gen_random_uuid();
  v_admin_user uuid := gen_random_uuid();
  v_agent_user uuid := gen_random_uuid();
  v_account_id uuid;
  v_dummy_hash CONSTANT text := '$2a$10$abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK';

  v_tag_res     uuid;
  v_tag_res2    uuid;
  v_tag_other   uuid;

  v_c1 uuid; v_c2 uuid; v_c3 uuid; v_c4 uuid; v_c5 uuid; v_c6 uuid;

  v_link      uuid;
  v_link2     uuid;
  v_link3     uuid;
  v_link5     uuid;
  v_link_other uuid;
  v_link_res2 uuid;

  v_msg     text;
  v_hint    text;
  v_audit   integer;
  v_count   integer;
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);

  -- ---- fixtures: one account with owner, admin and agent profiles ----
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password,
                          email_confirmed_at, created_at, updated_at,
                          raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES
    (v_owner_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'guard396-owner-' || v_owner_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_admin_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'guard396-admin-' || v_admin_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
    (v_agent_user, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
     'guard396-agent-' || v_agent_user || '@test.invalid', v_dummy_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);

  INSERT INTO accounts (id, name, owner_user_id)
  VALUES (gen_random_uuid(), 'guard396 test account', v_owner_user)
  RETURNING id INTO v_account_id;

  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_owner_user, 'guard396 owner', 'guard396-owner-' || v_owner_user || '@test.invalid', v_account_id, 'owner'),
    (gen_random_uuid(), v_admin_user, 'guard396 admin', 'guard396-admin-' || v_admin_user || '@test.invalid', v_account_id, 'admin'),
    (gen_random_uuid(), v_agent_user, 'guard396 agent', 'guard396-agent-' || v_agent_user || '@test.invalid', v_account_id, 'agent');

  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner_user, v_account_id, 'Revendedor') RETURNING id INTO v_tag_res;
  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner_user, v_account_id, 'revendedor') RETURNING id INTO v_tag_res2;
  INSERT INTO tags (user_id, account_id, name) VALUES (v_owner_user, v_account_id, 'Otro') RETURNING id INTO v_tag_other;

  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_user, v_account_id, '59903962001', 'guard396 c1') RETURNING id INTO v_c1;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_user, v_account_id, '59903962002', 'guard396 c2') RETURNING id INTO v_c2;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_user, v_account_id, '59903962003', 'guard396 c3') RETURNING id INTO v_c3;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_user, v_account_id, '59903962004', 'guard396 c4') RETURNING id INTO v_c4;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_user, v_account_id, '59903962005', 'guard396 c5') RETURNING id INTO v_c5;
  INSERT INTO contacts (id, user_id, account_id, phone, name) VALUES (gen_random_uuid(), v_owner_user, v_account_id, '59903962006', 'guard396 c6') RETURNING id INTO v_c6;

  -- ---- 1. the trusted no-session path is never blocked ----
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c1, v_tag_res) RETURNING id INTO v_link;
  DELETE FROM contact_tags WHERE id = v_link;
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c1, v_tag_res) RETURNING id INTO v_link;
  RAISE NOTICE 'PASS 1: no session may insert and delete the reseller tag';

  -- ---- 2. agent INSERT is refused with a readable 42501 ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  BEGIN
    INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c2, v_tag_res);
    RAISE EXCEPTION 'case 2: an agent INSERT of the reseller tag must be refused';
  EXCEPTION WHEN insufficient_privilege THEN
    GET STACKED DIAGNOSTICS v_msg = MESSAGE_TEXT, v_hint = PG_EXCEPTION_HINT;
    IF v_msg NOT LIKE '%owner or admin%' OR v_msg NOT LIKE '%Revendedor%'
       OR v_hint IS DISTINCT FROM 'reseller_tag_admin_only' THEN
      RAISE EXCEPTION 'case 2: expected a readable 42501 naming owner/admin and the Revendedor tag, got message=% hint=%', v_msg, v_hint;
    END IF;
  END;
  IF EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_c2 AND tag_id = v_tag_res) THEN
    RAISE EXCEPTION 'case 2: the refused agent INSERT must leave no row';
  END IF;
  RAISE NOTICE 'PASS 2: agent INSERT refused with 42501 / % and no row created', v_hint;

  -- ---- 3. agent DELETE is refused and the row remains ----
  BEGIN
    DELETE FROM contact_tags WHERE id = v_link;
    RAISE EXCEPTION 'case 3: an agent DELETE of the reseller tag must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE id = v_link) THEN
    RAISE EXCEPTION 'case 3: the refused agent DELETE must leave the row in place';
  END IF;
  RAISE NOTICE 'PASS 3: agent DELETE refused and the row remains';

  -- ---- 4. admin INSERT succeeds and writes the added audit row ----
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c2, v_tag_res) RETURNING id INTO v_link2;
  SELECT count(*) INTO v_count
    FROM remittance_admin_audit
   WHERE action = 'human_reseller_tag_added'
     AND table_name = 'contact_tags'
     AND row_id = v_link2
     AND account_id = v_account_id
     AND actor = v_admin_user::text
     AND after ->> 'contact_id' = v_c2::text
     AND after ->> 'tag_id' = v_tag_res::text
     AND after ->> 'tag_name' = 'Revendedor';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'case 4: one human_reseller_tag_added audit row by the admin is expected, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 4: admin INSERT succeeds and audits human_reseller_tag_added';

  -- ---- 5. owner DELETE succeeds and writes the removed audit row ----
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c3, v_tag_res) RETURNING id INTO v_link3;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_user, 'role', 'authenticated')::text, true);
  DELETE FROM contact_tags WHERE id = v_link3;
  SELECT count(*) INTO v_count
    FROM remittance_admin_audit
   WHERE action = 'human_reseller_tag_removed'
     AND table_name = 'contact_tags'
     AND row_id = v_link3
     AND account_id = v_account_id
     AND actor = v_owner_user::text
     AND before ->> 'contact_id' = v_c3::text
     AND before ->> 'tag_id' = v_tag_res::text
     AND after IS NULL;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'case 5: one human_reseller_tag_removed audit row by the owner is expected, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS 5: owner DELETE succeeds and audits human_reseller_tag_removed';

  -- ---- 6. other tags keep their agent permissions, no reseller audit ----
  SELECT count(*) INTO v_audit FROM remittance_admin_audit WHERE action IN ('human_reseller_tag_added', 'human_reseller_tag_removed');
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c4, v_tag_other) RETURNING id INTO v_link_other;
  DELETE FROM contact_tags WHERE id = v_link_other;
  IF (SELECT count(*) FROM remittance_admin_audit WHERE action IN ('human_reseller_tag_added', 'human_reseller_tag_removed')) <> v_audit THEN
    RAISE EXCEPTION 'case 6: adding/removing a non-reseller tag must not write reseller audit rows';
  END IF;
  RAISE NOTICE 'PASS 6: agent still adds and removes other tags without reseller audit rows';

  -- ---- 7. agent re-inserting an existing pair is allowed (no state change) ----
  SELECT count(*) INTO v_audit FROM remittance_admin_audit WHERE action IN ('human_reseller_tag_added', 'human_reseller_tag_removed');
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c2, v_tag_res) ON CONFLICT (contact_id, tag_id) DO NOTHING;
  IF (SELECT count(*) FROM contact_tags WHERE contact_id = v_c2 AND tag_id = v_tag_res) <> 1 THEN
    RAISE EXCEPTION 'case 7: an existing pair must stay a single row';
  END IF;
  IF (SELECT count(*) FROM remittance_admin_audit WHERE action IN ('human_reseller_tag_added', 'human_reseller_tag_removed')) <> v_audit THEN
    RAISE EXCEPTION 'case 7: re-inserting an existing pair must not write an audit row';
  END IF;
  RAISE NOTICE 'PASS 7: agent re-insert of an existing pair is allowed and unaudited';

  -- ---- 8. agent contact delete cascades without a guard failure ----
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c5, v_tag_res) RETURNING id INTO v_link5;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_agent_user, 'role', 'authenticated')::text, true);
  DELETE FROM contacts WHERE id = v_c5;
  IF EXISTS (SELECT 1 FROM contacts WHERE id = v_c5)
     OR EXISTS (SELECT 1 FROM contact_tags WHERE contact_id = v_c5) THEN
    RAISE EXCEPTION 'case 8: deleting the contact must remove it and its tag links';
  END IF;
  RAISE NOTICE 'PASS 8: agent contact delete cascades without a guard failure';

  -- ---- 9. agent UPDATE that moves a reseller tag is refused ----
  BEGIN
    UPDATE contact_tags SET contact_id = v_c6 WHERE id = v_link;
    RAISE EXCEPTION 'case 9: an agent UPDATE moving the reseller tag must be refused';
  EXCEPTION WHEN insufficient_privilege THEN NULL; END;
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE id = v_link AND contact_id = v_c1) THEN
    RAISE EXCEPTION 'case 9: the refused UPDATE must leave the row on its contact';
  END IF;
  RAISE NOTICE 'PASS 9: agent UPDATE moving the reseller tag refused';

  -- ---- 10. agent no-op UPDATE is allowed ----
  UPDATE contact_tags SET contact_id = contact_id, tag_id = tag_id WHERE id = v_link;
  IF NOT EXISTS (SELECT 1 FROM contact_tags WHERE id = v_link) THEN
    RAISE EXCEPTION 'case 10: a no-op UPDATE must keep the row';
  END IF;
  RAISE NOTICE 'PASS 10: agent no-op UPDATE allowed';

  -- ---- 11. deleting the tag definition cascades without a guard failure ----
  PERFORM set_config('request.jwt.claims', '', true);
  INSERT INTO contact_tags (contact_id, tag_id) VALUES (v_c1, v_tag_res2) RETURNING id INTO v_link_res2;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin_user, 'role', 'authenticated')::text, true);
  DELETE FROM tags WHERE id = v_tag_res2;
  IF EXISTS (SELECT 1 FROM tags WHERE id = v_tag_res2)
     OR EXISTS (SELECT 1 FROM contact_tags WHERE id = v_link_res2) THEN
    RAISE EXCEPTION 'case 11: deleting the tag definition must remove it and its links';
  END IF;
  RAISE NOTICE 'PASS 11: tag definition delete cascades; the already-gone tag row is not a reseller match';

  -- ---- 12. trigger shape and grants ----
  PERFORM set_config('request.jwt.claims', '', true);
  IF NOT EXISTS (
    SELECT 1
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
     WHERE c.relname = 'contact_tags'
       AND t.tgname = 'contact_tags_reseller_guard'
       AND NOT t.tgisinternal
       AND (t.tgtype & 4) <> 0   -- INSERT
       AND (t.tgtype & 16) <> 0  -- UPDATE
       AND (t.tgtype & 8) <> 0   -- DELETE
       AND (t.tgtype & 1) <> 0   -- ROW
       AND (t.tgtype & 2) <> 0   -- BEFORE
  ) THEN
    RAISE EXCEPTION 'case 12: contact_tags_reseller_guard must be a BEFORE INSERT OR UPDATE OR DELETE ROW trigger';
  END IF;
  IF has_function_privilege('anon', 'public.contact_tags_reseller_guard()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.contact_tags_reseller_guard()', 'EXECUTE') THEN
    RAISE EXCEPTION 'case 12: the guard function must not be executable by anon or authenticated';
  END IF;
  RAISE NOTICE 'PASS 12: trigger shape and function grants';

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;

ROLLBACK;
