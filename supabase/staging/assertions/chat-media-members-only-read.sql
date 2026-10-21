-- =====================================================================
-- Assertion for migration 260 (chat-media: only account members can read storage.objects rows; the bucket stays
-- public so public URLs keep working). Self-reverting: one DO block that ends in RAISE EXCEPTION 'ALL PASS'.
-- Fixtures: two accounts with one member each and one storage object per account folder.
-- Run it as: BEGIN; \i chat-media-members-only-read.sql; ROLLBACK;
--
-- Cases:
--   1. anon sees no chat-media row (no listing / enumeration through the API).
--   2. A member sees the objects of their own account folder and not another account's.
--   3. A logged-in user with no account sees none.
--   4. The bucket is still public; the INSERT/UPDATE/DELETE member policies are unchanged; the old public SELECT
--      policy is gone; avatars and flow-media are untouched.
-- =====================================================================
DO $$
DECLARE
  v_u1   uuid := gen_random_uuid();
  v_u2   uuid := gen_random_uuid();
  v_u3   uuid := gen_random_uuid();
  v_acc1 uuid;
  v_acc2 uuid;
  v_hash text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_o1   uuid;
  v_o2   uuid;
  v_n    int;
  v_seen uuid[];
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'media-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_u1, v_u2, v_u3]) u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'media account 1', v_u1) RETURNING id INTO v_acc1;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'media account 2', v_u2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_u1, 'media agent 1', 'media-' || v_u1 || '@test.invalid', v_acc1, 'agent'),
    (gen_random_uuid(), v_u2, 'media agent 2', 'media-' || v_u2 || '@test.invalid', v_acc2, 'agent');
  -- v_u3 has no profile: no account.
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('chat-media', 'account-' || v_acc1 || '/1-wa-1.jpg', v_u1::text)
    RETURNING id INTO v_o1;
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('chat-media', 'account-' || v_acc2 || '/2-wa-2.jpg', v_u2::text)
    RETURNING id INTO v_o2;

  -- 1. anon
  PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  SET LOCAL ROLE anon;
  SELECT count(*) INTO v_n FROM storage.objects WHERE bucket_id = 'chat-media';
  RESET ROLE;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: anon must see no chat-media rows, saw %', v_n; END IF;

  -- 2. member of account 1
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u1, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT array_agg(id) INTO v_seen FROM storage.objects WHERE bucket_id = 'chat-media' AND id IN (v_o1, v_o2);
  RESET ROLE;
  IF v_seen IS DISTINCT FROM ARRAY[v_o1] THEN
    RAISE EXCEPTION 'case 2: member 1 must see only its own object, saw %', v_seen; END IF;

  -- 3. logged in, no account
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u3, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT count(*) INTO v_n FROM storage.objects WHERE bucket_id = 'chat-media' AND id IN (v_o1, v_o2);
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 3: a user without account must see nothing, saw %', v_n; END IF;

  -- 4. bucket and the other policies
  IF NOT (SELECT public FROM storage.buckets WHERE id = 'chat-media') THEN
    RAISE EXCEPTION 'case 4: chat-media must stay public (public URLs are used by the panel and the send path)'; END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND policyname = 'Chat media is publicly readable') THEN
    RAISE EXCEPTION 'case 4: the public SELECT policy must be gone'; END IF;
  SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage'
     AND policyname IN ('Members can upload chat media', 'Members can update chat media', 'Members can delete chat media');
  IF v_n <> 3 THEN RAISE EXCEPTION 'case 4: member write policies changed (% of 3)', v_n; END IF;
  SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage'
     AND policyname IN ('Avatars are publicly readable', 'Flow media is publicly readable');
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 4: avatars / flow-media read policies must be untouched'; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
