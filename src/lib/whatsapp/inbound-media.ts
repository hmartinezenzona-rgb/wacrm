// ============================================================
// Settle the media of an inbound message after the row exists.
//
// Since slice 6a the webhook stores the message FIRST, with
// `media_status = 'pending'` and today's proxy `media_url`, and then
// downloads the file. That way a slow or broken Meta download can no
// longer lose the customer's message, and the bot's reply is not held
// behind a 400 KB image.
//
// Every Meta call is bounded. One retry with a short backoff, then the
// row becomes `failed` — the legacy proxy `media_url` stays exactly as
// it was, so the panel keeps trying it and behaves as it does today.
//
// Every write is guarded by `media_status = 'pending'`, so a duplicate
// delivery or a sweeper running at the same time cannot settle a row
// twice or overwrite a newer outcome.
// ============================================================

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { makeThumbnail } from '@/lib/storage/media-thumbnail';
import { downloadMedia, getMediaUrl } from '@/lib/whatsapp/meta-api';

/** Bounds for each Meta call. */
export const MEDIA_URL_TIMEOUT_MS = 10_000;
export const MEDIA_DOWNLOAD_TIMEOUT_MS = 25_000;
export const MEDIA_THUMB_TIMEOUT_MS = 20_000;

/** Backoff before the single retry. */
export const MEDIA_RETRY_BACKOFF_MS = 1_000;

/** The bucket rejects anything larger. */
export const MEDIA_MAX_BYTES = 16 * 1024 * 1024;

export const CHAT_MEDIA_BUCKET = 'chat-media';

export type SettleOutcome = 'ready' | 'failed';

export interface SettleInboundMediaArgs {
  /** `messages.id` of the row that is waiting for its media. */
  messageId: string;
  /** Meta media id (the webhook `image.id`, `video.id`, ...). */
  mediaId: string;
  accessToken: string;
  accountId: string;
  /** WhatsApp content type; only images and stickers get a thumbnail. */
  contentType: string;
  /** Overridable for tests; defaults to a real 1 s wait. */
  sleep?: (ms: number) => Promise<void>;
}

export function extFromMime(mime: string): string {
  const m = (mime || '').split(';')[0].trim().toLowerCase();
  const map: Record<string, string> = {
    'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp',
    'image/gif': 'gif', 'audio/ogg': 'ogg', 'audio/mpeg': 'mp3',
    'audio/mp4': 'm4a', 'audio/amr': 'amr', 'video/mp4': 'mp4',
    'video/3gpp': '3gp', 'application/pdf': 'pdf',
  };
  return map[m] || 'bin';
}

const defaultSleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/** One download attempt. Throws on anything that should count as a failure. */
async function attempt(
  args: SettleInboundMediaArgs,
): Promise<{
  path: string;
  mime: string;
  bytes: number;
  width: number | null;
  height: number | null;
  thumbPath: string | null;
  thumbError: string | null;
}> {
  const { url, mimeType } = await getMediaUrl({
    mediaId: args.mediaId,
    accessToken: args.accessToken,
    signal: AbortSignal.timeout(MEDIA_URL_TIMEOUT_MS),
  });

  const { buffer, contentType } = await downloadMedia({
    downloadUrl: url,
    accessToken: args.accessToken,
    signal: AbortSignal.timeout(MEDIA_DOWNLOAD_TIMEOUT_MS),
  });

  if (buffer.byteLength > MEDIA_MAX_BYTES) {
    throw new Error(`media too large: ${buffer.byteLength} bytes`);
  }

  const mime = contentType || mimeType;
  const path = `account-${args.accountId}/${Date.now()}-wa-${args.mediaId}.${extFromMime(mime)}`;

  const { error } = await supabaseAdmin()
    .storage.from(CHAT_MEDIA_BUCKET)
    .upload(path, buffer, {
      contentType: mime,
      cacheControl: '31536000',
      upsert: false,
    });
  if (error) throw error;

  let thumbPath: string | null = null;
  let thumbError: string | null = null;
  let width: number | null = null;
  let height: number | null = null;

  if (args.contentType === 'image' || args.contentType === 'sticker') {
    const thumb = await Promise.race([
      makeThumbnail(path, buffer),
      new Promise<never>((_, reject) =>
        setTimeout(
          () => reject(new Error('thumbnail timed out')),
          MEDIA_THUMB_TIMEOUT_MS,
        ),
      ),
    ]).catch((thrown: unknown) => ({
      error: thrown instanceof Error ? thrown.message : String(thrown),
    }));

    if (thumb && 'error' in thumb) {
      // Non-fatal: the message is still shown with the original.
      thumbError = `thumbnail: ${thumb.error}`;
    } else if (thumb) {
      const { error: thumbUploadError } = await supabaseAdmin()
        .storage.from(CHAT_MEDIA_BUCKET)
        .upload(thumb.path, thumb.data, {
          contentType: thumb.mime,
          cacheControl: '31536000',
          upsert: true,
        });
      if (thumbUploadError) thumbError = `thumbnail: ${thumbUploadError.message}`;
      else thumbPath = thumb.path;
      width = thumb.sourceWidth;
      height = thumb.sourceHeight;
    }
  }

  return { path, mime, bytes: buffer.byteLength, width, height, thumbPath, thumbError };
}

/**
 * Download, store and record the media of a pending message.
 *
 * Never throws: the caller only needs to know whether the row settled
 * `ready` or `failed`.
 */
export async function settleInboundMedia(
  args: SettleInboundMediaArgs,
): Promise<SettleOutcome> {
  const sleep = args.sleep ?? defaultSleep;
  const supabase = supabaseAdmin();

  let lastError: string = 'unknown error';
  for (let attemptNumber = 1; attemptNumber <= 2; attemptNumber++) {
    try {
      const stored = await attempt(args);
      const { error } = await supabase
        .from('messages')
        .update({
          media_status: 'ready',
          media_path: stored.path,
          media_thumb_path: stored.thumbPath,
          media_mime: stored.mime,
          media_bytes: stored.bytes,
          media_width: stored.width,
          media_height: stored.height,
          media_error: stored.thumbError,
        })
        .eq('id', args.messageId)
        .eq('media_status', 'pending');
      if (error) throw error;
      return 'ready';
    } catch (thrown) {
      lastError = thrown instanceof Error ? thrown.message : String(thrown);
      if (attemptNumber === 1) await sleep(MEDIA_RETRY_BACKOFF_MS);
    }
  }

  // Give up: the row says why, and `media_url` keeps the legacy proxy value
  // the panel has always used, so the bubble still tries to show something.
  await supabase
    .from('messages')
    .update({ media_status: 'failed', media_error: lastError })
    .eq('id', args.messageId)
    .eq('media_status', 'pending');

  return 'failed';
}
