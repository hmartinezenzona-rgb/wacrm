// ============================================================
// Server-only access to the chat-media bucket with the service role.
//
// The bucket is moving from public to private, so anything that used to
// do an anonymous `fetch(publicUrl)` (outbound sends, template headers)
// or hand the public URL to a third party (Meta `link`, the v1 API) goes
// through here instead. Callers are responsible for authorising the
// path; these helpers only parse and fetch.
// ============================================================

import { supabaseAdmin } from '@/lib/flows/admin-client';
import { CHAT_MEDIA_BUCKET, parseChatMediaPath } from '@/lib/storage/chat-media';

export interface DownloadedChatMedia {
  bytes: ArrayBuffer;
  contentType: string;
}

/** Download one object; null when it is missing or unreadable. */
export async function downloadChatMedia(path: string): Promise<DownloadedChatMedia | null> {
  const { data, error } = await supabaseAdmin().storage.from(CHAT_MEDIA_BUCKET).download(path);
  if (error || !data) return null;
  return {
    bytes: await data.arrayBuffer(),
    contentType: data.type || 'application/octet-stream',
  };
}

/**
 * Time-limited URL for a stored chat-media URL, safe to hand to Meta or
 * an API client. Anything that is not a chat-media URL — and any signing
 * failure — returns the input unchanged, i.e. today's behaviour.
 */
export async function signChatMediaUrl<T extends string | null | undefined>(
  url: T,
  expiresInSeconds: number,
): Promise<T | string> {
  const path = parseChatMediaPath(url);
  if (!path) return url;
  const { data, error } = await supabaseAdmin()
    .storage.from(CHAT_MEDIA_BUCKET)
    .createSignedUrl(path, expiresInSeconds);
  if (error || !data?.signedUrl) {
    console.error('[chat-media] could not sign URL:', error?.message ?? 'no url returned');
    return url;
  }
  return data.signedUrl;
}
