-- ROLLBACK for migration 400 (message media metadata).
--
-- Order matters: the function and the index go before the columns they depend on. Everything created by 400 is removed,
-- so the schema returns to what the live panel expects. Owner approval only: the rows that used these columns lose
-- their media state, and any message left `pending` will never be swept again.

DROP FUNCTION IF EXISTS public.crm_media_reclamar(integer, interval);
DROP INDEX IF EXISTS public.idx_messages_media_pending;

ALTER TABLE public.messages
  DROP CONSTRAINT IF EXISTS messages_media_status_check;

ALTER TABLE public.messages
  DROP COLUMN IF EXISTS media_status,
  DROP COLUMN IF EXISTS media_path,
  DROP COLUMN IF EXISTS media_thumb_path,
  DROP COLUMN IF EXISTS media_mime,
  DROP COLUMN IF EXISTS media_bytes,
  DROP COLUMN IF EXISTS media_width,
  DROP COLUMN IF EXISTS media_height,
  DROP COLUMN IF EXISTS media_error,
  DROP COLUMN IF EXISTS media_claimed_at,
  DROP COLUMN IF EXISTS media_attempts;
