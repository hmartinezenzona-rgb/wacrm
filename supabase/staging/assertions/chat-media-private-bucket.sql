-- =====================================================================
-- Assertion for migration 261 (chat-media bucket private). Self-reverting: one DO block that ends in
-- RAISE EXCEPTION 'ALL PASS'. Run it as: BEGIN; \i chat-media-private-bucket.sql; ROLLBACK;
--
-- Cases:
--   1. chat-media is not public; its size limit and allowed MIME types are unchanged.
--   2. avatars and flow-media stay public (Meta fetches flow media by link).
--   3. The member policies of 023/260 are unchanged (read, upload, update, delete).
-- =====================================================================
DO $$
DECLARE
  v_b record;
  v_n int;
BEGIN
  SELECT * INTO v_b FROM storage.buckets WHERE id = 'chat-media';
  IF v_b.public THEN RAISE EXCEPTION 'case 1: chat-media must be private'; END IF;
  IF v_b.file_size_limit IS DISTINCT FROM 16777216 OR NOT ('audio/ogg' = ANY (v_b.allowed_mime_types))
     OR NOT ('image/jpeg' = ANY (v_b.allowed_mime_types)) THEN
    RAISE EXCEPTION 'case 1: size limit / MIME types changed'; END IF;

  SELECT count(*) INTO v_n FROM storage.buckets WHERE id IN ('avatars', 'flow-media') AND public;
  IF v_n <> 2 THEN RAISE EXCEPTION 'case 2: avatars and flow-media must stay public'; END IF;

  SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'storage'
     AND policyname IN ('Members can read chat media', 'Members can upload chat media',
                        'Members can update chat media', 'Members can delete chat media');
  IF v_n <> 4 THEN RAISE EXCEPTION 'case 3: member policies changed (% of 4)', v_n; END IF;

  RAISE EXCEPTION 'ALL PASS (rolled back on purpose)';
END $$;
