-- =====================================================================
-- Assertion for migration 262 (avatars / flow-media: no anonymous listing; buckets stay public). Self-reverting:
-- one DO block that ends in RAISE EXCEPTION 'ALL PASS'. Run it as: BEGIN; \i avatars-flow-media-members-only-read.sql; ROLLBACK;
--
-- Cases:
--   1. anon sees no avatars / flow-media rows.
--   2. A user sees their own avatar row (upsert needs it) and not another user's.
--   3. A member sees their account's flow-media rows (new and legacy per-user folder) and not another account's.
--   4. Both buckets stay public; the old public SELECT policies are gone; write policies unchanged.
-- =====================================================================
DO $$
DECLARE
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_acc1 uuid; v_acc2 uuid;
  v_hash text := '$2a$10$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234';
  v_av1 uuid; v_av2 uuid; v_f1 uuid; v_fl uuid; v_f2 uuid;
  v_n int; v_seen uuid[];
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data, is_sso_user, is_anonymous)
  SELECT u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b262-' || u || '@test.invalid', v_hash, now(), now(), now(), '{}'::jsonb, '{}'::jsonb, false, false
    FROM unnest(ARRAY[v_u1, v_u2]) u;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'b262 a', v_u1) RETURNING id INTO v_acc1;
  INSERT INTO accounts (id, name, owner_user_id) VALUES (gen_random_uuid(), 'b262 b', v_u2) RETURNING id INTO v_acc2;
  INSERT INTO profiles (id, user_id, full_name, email, account_id, account_role) VALUES
    (gen_random_uuid(), v_u1, 'b262 1', 'b262-' || v_u1 || '@test.invalid', v_acc1, 'agent'),
    (gen_random_uuid(), v_u2, 'b262 2', 'b262-' || v_u2 || '@test.invalid', v_acc2, 'agent');
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('avatars', v_u1 || '/a.png', v_u1::text) RETURNING id INTO v_av1;
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('avatars', v_u2 || '/a.png', v_u2::text) RETURNING id INTO v_av2;
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('flow-media', 'account-' || v_acc1 || '/f.png', v_u1::text) RETURNING id INTO v_f1;
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('flow-media', v_u1 || '/legacy.png', v_u1::text) RETURNING id INTO v_fl;
  INSERT INTO storage.objects (bucket_id, name, owner_id) VALUES ('flow-media', 'account-' || v_acc2 || '/f.png', v_u2::text) RETURNING id INTO v_f2;

  PERFORM set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  SET LOCAL ROLE anon;
  SELECT count(*) INTO v_n FROM storage.objects WHERE bucket_id IN ('avatars', 'flow-media');
  RESET ROLE;
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 1: anon must see no avatars/flow-media rows, saw %', v_n; END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_u1, 'role', 'authenticated')::text, true);
  SET LOCAL ROLE authenticated;
  SELECT array_agg(id ORDER BY id) INTO v_seen FROM storage.objects WHERE id IN (v_av1, v_av2);
  IF v_seen IS DISTINCT FROM ARRAY[v_av1] THEN RESET ROLE; RAISE EXCEPTION 'case 2: own avatar only, saw %', v_seen; END IF;
  SELECT count(*) INTO v_n FROM storage.objects WHERE id IN (v_f1, v_fl);
  IF v_n <> 2 THEN RESET ROLE; RAISE EXCEPTION 'case 3: member must see own account + legacy flow media, saw %', v_n; END IF;
  SELECT count(*) INTO v_n FROM storage.objects WHERE id = v_f2;
  RESET ROLE;
  PERFORM set_config('request.jwt.claims', '', true);
  IF v_n <> 0 THEN RAISE EXCEPTION 'case 3: another account''s flow media must be hidden'; END IF;

  SELECT count(*) INTO v_n FROM storage.buckets WHERE id IN ('avatars', 'flow-media') AND public;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 4: avatars and flow-media must stay public'; END IF;
  IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage'
              AND policyname IN ('Avatars are publicly readable', 'Flow media is publicly readable')) THEN
    RAISE EXCEPTION 'case 4: the public SELECT policies must be gone'; END IF;
  SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage' AND policyname IN
    ('Users can upload their own avatar', 'Users can update their own avatar', 'Users can delete their own avatar',
     'Members can upload flow media', 'Members can update flow media', 'Members can delete flow media');
  IF v_n <> 6 THEN RAISE EXCEPTION 'case 4: write policies changed (% of 6)', v_n; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
