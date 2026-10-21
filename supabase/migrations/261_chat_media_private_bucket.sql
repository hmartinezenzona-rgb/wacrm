-- =====================================================================
-- 261: chat-media bucket private.
--
-- After 260 nobody outside the account can list the bucket, but any known or guessed /object/public/ URL still
-- opened a customer's receipt, voice note or ID photo. The panel no longer needs public URLs (release with the
-- same-origin proxy /api/chat-media/<path>, service-role reads for outbound sends and template headers, signed URLs
-- for Meta links and the v1 API), so the bucket goes private. Stored messages.media_url values keep their
-- /object/public/ shape; the app maps them at read time. Size limit, MIME types and member policies are unchanged.
-- Apply ONLY after that panel release is live.
--
-- ROLLBACK: ROLLBACK-261-chat-media-private-bucket.sql
-- Guarded by supabase/staging/assertions/chat-media-private-bucket.sql
-- =====================================================================

UPDATE storage.buckets SET public = false WHERE id = 'chat-media';
