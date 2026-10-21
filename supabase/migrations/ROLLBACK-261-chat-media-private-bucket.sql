-- =====================================================================
-- ROLLBACK 261: chat-media public again (public URLs open without a session). No data changes.
-- =====================================================================

UPDATE storage.buckets SET public = true WHERE id = 'chat-media';
