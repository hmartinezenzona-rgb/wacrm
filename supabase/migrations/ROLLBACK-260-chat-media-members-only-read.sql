-- =====================================================================
-- ROLLBACK 260: chat-media rows readable by everyone again (023's policy). No data changes.
-- =====================================================================

DROP POLICY IF EXISTS "Members can read chat media" ON storage.objects;

DROP POLICY IF EXISTS "Chat media is publicly readable" ON storage.objects;
CREATE POLICY "Chat media is publicly readable"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'chat-media');
