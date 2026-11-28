-- 400 -- Message media metadata: status, storage path, dimensions and the sweeper claim.
--
-- openspec/changes/inbox-media-performance (slice 5a, ADR-6). Everything here is additive and nullable, so the panel
-- that is live today keeps working unchanged: it reads `media_url` and ignores these columns.
--
-- Why it exists: the inbound webhook downloads WhatsApp media and then writes the message. When the download fails the
-- customer's image is lost forever, because nothing records that a media message was expected. These columns let the
-- insert point say "media pending, download later", and let the sweeper claim, retry and finally give up on it.
--
-- Guards:
--   * No BEGIN/COMMIT: the Management API applies the file as one statement batch.
--   * `media_attempts` is NOT NULL with a fast default (PG >= 11 does not rewrite the table).
--   * text + CHECK instead of an enum: the codebase already lists `content_type` and `status` this way, and an enum
--     would make the rollback and any future value harder for no gain.
--   * The CHECK is added NOT VALID and then validated in the same file: every existing row is NULL, so validation
--     costs almost nothing, but the two-step shape keeps the window short on a large table.
--   * Only the sweeper reads idx_messages_media_pending; it is not CONCURRENTLY because the batch runner applies the
--     file as one statement list and the lock is brief at this table size.
--
-- ROLLBACK-400-messages-media-metadata.sql drops every object created here.
-- Assertion: supabase/staging/assertions/messages-media-metadata.sql.

-- ─── columns ──────────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.messages
  ADD COLUMN IF NOT EXISTS media_status      text,
  ADD COLUMN IF NOT EXISTS media_path        text,
  ADD COLUMN IF NOT EXISTS media_thumb_path  text,
  ADD COLUMN IF NOT EXISTS media_mime        text,
  ADD COLUMN IF NOT EXISTS media_bytes       integer,
  ADD COLUMN IF NOT EXISTS media_width       integer,
  ADD COLUMN IF NOT EXISTS media_height      integer,
  ADD COLUMN IF NOT EXISTS media_error       text,
  ADD COLUMN IF NOT EXISTS media_claimed_at  timestamptz,
  ADD COLUMN IF NOT EXISTS media_attempts    smallint NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.messages.media_status IS
  'Pending, ready or failed media download. NULL means legacy row or not a media message.';
COMMENT ON COLUMN public.messages.media_path IS
  'Object path of the original inside the chat-media bucket.';
COMMENT ON COLUMN public.messages.media_thumb_path IS
  'Object path of the thumbnail inside the chat-media bucket, when one was produced.';
COMMENT ON COLUMN public.messages.media_error IS
  'Why the media failed, or why there is no thumbnail (thumbnail: ...).';

-- ─── status check ─────────────────────────────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.messages
  DROP CONSTRAINT IF EXISTS messages_media_status_check;
ALTER TABLE public.messages
  ADD CONSTRAINT messages_media_status_check
  CHECK (media_status IS NULL OR media_status IN ('pending', 'ready', 'failed')) NOT VALID;
ALTER TABLE public.messages
  VALIDATE CONSTRAINT messages_media_status_check;

-- ─── sweeper index ────────────────────────────────────────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_messages_media_pending
  ON public.messages (media_claimed_at)
  WHERE media_status = 'pending';

-- ─── claim function ───────────────────────────────────────────────────────────────────────────────────────────────────
-- Two jobs in one call, so a sweeper tick is a single round trip:
--   1. settle what can never succeed (attempts exhausted, or past Meta's 7-day media window) as failed;
--   2. claim up to p_limit stale pending rows for a retry, bumping their attempt counter.
-- Rows claimed less than p_stale ago are left alone, so two sweeper instances do not fight over the same message.
CREATE OR REPLACE FUNCTION public.crm_media_reclamar(
  p_limit integer DEFAULT 5,
  p_stale interval DEFAULT '5 minutes'
)
RETURNS TABLE (
  id uuid,
  conversation_id uuid,
  message_id text,
  media_url text,
  content_type text,
  content_text text,
  created_at timestamptz,
  media_attempts smallint,
  accion text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- 1. rows that can never succeed
  RETURN QUERY
  WITH settled AS (
    UPDATE messages m
       SET media_status = 'failed',
           media_error = CASE
                           WHEN m.media_attempts >= 3 THEN 'sweeper: attempts exhausted'
                           ELSE 'meta window expired'
                         END
     WHERE m.media_status = 'pending'
       AND (
         m.media_attempts >= 3
         OR m.created_at < now() - interval '7 days'
       )
    RETURNING m.id, m.conversation_id, m.message_id, m.media_url, m.content_type,
              m.content_text, m.created_at, m.media_attempts
  )
  SELECT s.id, s.conversation_id, s.message_id, s.media_url, s.content_type,
         s.content_text, s.created_at, s.media_attempts, 'fallida'::text
    FROM settled s;

  -- 2. claim stale pending rows for a retry
  RETURN QUERY
  WITH claimed AS (
    UPDATE messages m
       SET media_claimed_at = now(),
           media_attempts = m.media_attempts + 1
     WHERE m.id IN (
       SELECT c.id
         FROM messages c
        WHERE c.media_status = 'pending'
          AND c.media_claimed_at < now() - p_stale
        ORDER BY c.media_claimed_at
        LIMIT greatest(p_limit, 0)
          FOR UPDATE SKIP LOCKED
     )
    RETURNING m.id, m.conversation_id, m.message_id, m.media_url, m.content_type,
              m.content_text, m.created_at, m.media_attempts
  )
  SELECT c.id, c.conversation_id, c.message_id, c.media_url, c.content_type,
         c.content_text, c.created_at, c.media_attempts, 'reintentar'::text
    FROM claimed c;
END;
$$;

COMMENT ON FUNCTION public.crm_media_reclamar(integer, interval) IS
  'Sweeper entry point: settles media that can never succeed and claims stale pending rows for a retry.';

REVOKE ALL ON FUNCTION public.crm_media_reclamar(integer, interval) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.crm_media_reclamar(integer, interval) FROM anon;
REVOKE ALL ON FUNCTION public.crm_media_reclamar(integer, interval) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.crm_media_reclamar(integer, interval) TO service_role;
