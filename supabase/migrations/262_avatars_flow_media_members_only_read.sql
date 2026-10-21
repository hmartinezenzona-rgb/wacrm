-- =====================================================================
-- 262: avatars / flow-media, no anonymous listing.
--
-- 008 and 016 gave SELECT on these storage.objects rows to everyone, so the publishable key in the panel could LIST
-- every avatar and every flow media file. Reads by URL never needed it: both buckets stay public (avatars are meant to
-- be seen, and Meta fetches flow media by link) and /object/public URLs are served without these row policies.
-- Now:
--   - avatars: a user reads only the rows of their own folder (`<auth.uid()>/...`), which the profile form's
--     upsert needs; same predicate as 008's write policies.
--   - flow-media: a member reads the rows of their account folder or their legacy per-user folder; same predicate
--     as 020's write policies.
-- Same change as 260 for chat-media.
--
-- ROLLBACK: ROLLBACK-262-avatars-flow-media-members-only-read.sql
-- Guarded by supabase/staging/assertions/avatars-flow-media-members-only-read.sql
-- =====================================================================

DROP POLICY IF EXISTS "Avatars are publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "Users can read their own avatar" ON storage.objects;
CREATE POLICY "Users can read their own avatar"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "Flow media is publicly readable" ON storage.objects;
DROP POLICY IF EXISTS "Members can read flow media" ON storage.objects;
CREATE POLICY "Members can read flow media"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'flow-media'
    AND (
      EXISTS (
        SELECT 1 FROM public.profiles p
        WHERE p.user_id = auth.uid()
          AND ('account-' || p.account_id::text) = (storage.foldername(name))[1]
      )
      OR auth.uid()::text = (storage.foldername(name))[1]
    )
  );
