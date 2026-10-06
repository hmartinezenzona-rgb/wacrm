-- =====================================================================
-- Assertion for migration 220 (notifications_delete policy). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Fixtures build their own account, two users and their notifications.
-- Run it as: BEGIN; \i delete-notifications.sql; ROLLBACK;
-- =====================================================================
DO $$
DECLARE
  v_a      uuid := gen_random_uuid();
  v_b      uuid := gen_random_uuid();
  v_acc    uuid;
  v_hash   text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_a1     uuid;
  v_a2     uuid;
  v_a3     uuid;
  v_b1     uuid;
  v_b2     uuid;
  v_n      integer;
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  VALUES (v_a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'delnotif-a-' || v_a || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false),
         (v_b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'delnotif-b-' || v_b || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false);
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'delete notifications account', v_a) RETURNING id INTO v_acc;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role)
  VALUES (gen_random_uuid(), v_a, 'notif agent A', 'delnotif-a-' || v_a || '@test.invalid', v_acc, 'agent'),
         (gen_random_uuid(), v_b, 'notif agent B', 'delnotif-b-' || v_b || '@test.invalid', v_acc, 'agent');

  INSERT INTO notifications (account_id, user_id, title) VALUES (v_acc, v_a, 'A one')   RETURNING id INTO v_a1;
  INSERT INTO notifications (account_id, user_id, title) VALUES (v_acc, v_a, 'A two')   RETURNING id INTO v_a2;
  INSERT INTO notifications (account_id, user_id, title, read_at) VALUES (v_acc, v_a, 'A three', now()) RETURNING id INTO v_a3;
  INSERT INTO notifications (account_id, user_id, title) VALUES (v_acc, v_b, 'B one')   RETURNING id INTO v_b1;
  INSERT INTO notifications (account_id, user_id, title) VALUES (v_acc, v_b, 'B two')   RETURNING id INTO v_b2;

  -- 1. User A deletes their own notification: the row is gone.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  DELETE FROM notifications WHERE id = v_a1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RESET ROLE;
  IF v_n <> 1 THEN RAISE EXCEPTION 'case 1: deleting an own notification affected % rows, expected 1', v_n; END IF;
  IF EXISTS (SELECT 1 FROM notifications WHERE id = v_a1) THEN RAISE EXCEPTION 'case 1: the own notification is still there'; END IF;

  -- 2. User A deletes user B's notification: 0 rows, still there.
  SET LOCAL ROLE authenticated;
  DELETE FROM notifications WHERE id = v_b1;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RESET ROLE;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 2: deleting another user''s notification affected % rows, expected 0', v_n; END IF;
  IF NOT EXISTS (SELECT 1 FROM notifications WHERE id = v_b1) THEN RAISE EXCEPTION 'case 2: another user''s notification was deleted'; END IF;

  -- 3. anon deletes: nothing is deleted.
  PERFORM set_config('request.jwt.claims', '', true);
  SET LOCAL ROLE anon;
  BEGIN
    DELETE FROM notifications WHERE id IN (v_a2, v_b2);
    GET DIAGNOSTICS v_n = ROW_COUNT;
  EXCEPTION WHEN insufficient_privilege THEN
    v_n := 0;
  END;
  RESET ROLE;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 3: anon deleted % rows', v_n; END IF;
  IF (SELECT count(*) FROM notifications WHERE id IN (v_a2, v_b2)) <> 2 THEN RAISE EXCEPTION 'case 3: anon removed a notification'; END IF;

  -- 4. "Delete all" by user A removes only A's remaining rows (read and unread), B's stay.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  DELETE FROM notifications WHERE user_id = v_a;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RESET ROLE;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 4: delete all affected % rows, expected 2', v_n; END IF;
  IF (SELECT count(*) FROM notifications WHERE user_id = v_a) <> 0 THEN RAISE EXCEPTION 'case 4: some of A''s notifications remain'; END IF;
  IF (SELECT count(*) FROM notifications WHERE user_id = v_b) <> 2 THEN RAISE EXCEPTION 'case 4: B''s notifications were touched'; END IF;

  -- 4b. Even without a user filter, A's delete only reaches A's rows (RLS): B's rows survive.
  SET LOCAL ROLE authenticated;
  DELETE FROM notifications;
  RESET ROLE;
  IF (SELECT count(*) FROM notifications WHERE user_id = v_b) <> 2 THEN RAISE EXCEPTION 'case 4b: an unfiltered delete by A reached B'; END IF;

  PERFORM set_config('request.jwt.claims', '', true);
  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
