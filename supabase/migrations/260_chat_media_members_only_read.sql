-- =====================================================================
-- 260: chat-media, only account members can read its storage.objects rows.
--
-- 023 created "Chat media is publicly readable" (SELECT to everyone on bucket chat-media). With the publishable key
-- that ships in the panel, anyone could LIST every object of the bucket (4,506 customer receipts, voice notes, ID and
-- delivery photos in production on 2026-10-21), not only open a URL they already had.
-- Now SELECT on those rows is limited to members of the account that owns the folder, with the same predicate as the
-- member INSERT/UPDATE/DELETE policies of 023. The bucket stays public: the panel, the send path (server fetch before
-- uploading to Meta) and template headers use /object/public URLs, which are served without these row policies, so
-- existing links keep working (checked by an HTTP request against staging). Making the bucket private is a later step.
--
-- ROLLBACK: ROLLBACK-260-chat-media-members-only-read.sql
-- Guarded by supabase/staging/assertions/chat-media-members-only-read.sql
-- =====================================================================

DROP POLICY IF EXISTS "Chat media is publicly readable" ON storage.objects;

DROP POLICY IF EXISTS "Members can read chat media" ON storage.objects;
CREATE POLICY "Members can read chat media"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (
    bucket_id = 'chat-media'
    AND EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.user_id = auth.uid()
        AND ('account-' || p.account_id::text) = (storage.foldername(name))[1]
    )
  );
