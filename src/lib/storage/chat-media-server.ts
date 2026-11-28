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
import {
  CHAT_MEDIA_BUCKET,
  assertChatMediaAccount,
  chatMediaProxyUrl,
  isChatMediaPathOfAccount,
  parseChatMediaPath,
} from '@/lib/storage/chat-media';

export interface DownloadedChatMedia {
  bytes: ArrayBuffer;
  contentType: string;
}

/**
 * Download one object of `accountId`; null when it is missing or
 * unreadable. Throws `ForeignChatMediaError` for another account's path.
 */
export async function downloadChatMedia(
  path: string,
  accountId: string,
): Promise<DownloadedChatMedia | null> {
  // Reuse the URL gate on the proxy form of the path.
  assertChatMediaAccount(chatMediaProxyUrl(path), accountId);
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
 * failure — returns the input unchanged, i.e. today's behaviour. An
 * object of another account is never signed (`ForeignChatMediaError`).
 */
export async function signChatMediaUrl<T extends string | null | undefined>(
  url: T,
  expiresInSeconds: number,
  accountId: string,
): Promise<T | string> {
  const path = assertChatMediaAccount(url, accountId);
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

/** One page's worth of signed URLs, keyed by the stored `media_url` string. */
export interface SignedChatMediaBatch {
  signed: Record<string, string>;
  expiresIn: number;
  /** False when Storage refused the batch; `signed` is empty in that case. */
  ok: boolean;
}

const DEFAULT_SIGNED_TTL_SECONDS = 3600;

/**
 * Sign a page's chat-media URLs in ONE Storage call. Paths of another
 * account and URLs that are not chat-media are skipped, never signed —
 * the same gate the sign route has always used, minus its fail-hard
 * behaviour: one corrupt row must not discard the whole page.
 */
export async function signChatMediaUrls(
  urls: string[],
  accountId: string,
  ttlSeconds: number = DEFAULT_SIGNED_TTL_SECONDS,
): Promise<SignedChatMediaBatch> {
  // Path per original URL, so two stored shapes of one object share a call.
  const byPath = new Map<string, string[]>();
  for (const url of urls) {
    if (!url) continue;
    const path = parseChatMediaPath(url);
    if (!path || !isChatMediaPathOfAccount(path, accountId)) continue;
    const originals = byPath.get(path) ?? [];
    if (!originals.includes(url)) originals.push(url);
    byPath.set(path, originals);
  }

  if (byPath.size === 0) return { signed: {}, expiresIn: ttlSeconds, ok: true };

  const { data, error } = await supabaseAdmin()
    .storage.from(CHAT_MEDIA_BUCKET)
    .createSignedUrls([...byPath.keys()], ttlSeconds);

  if (error || !data) {
    console.error('[chat-media] could not sign batch:', error?.message ?? 'no data');
    return { signed: {}, expiresIn: ttlSeconds, ok: false };
  }

  const signed: Record<string, string> = {};
  for (const row of data) {
    if (!row.signedUrl || !row.path) continue;
    for (const original of byPath.get(row.path) ?? []) {
      signed[original] = row.signedUrl;
    }
  }

  return { signed, expiresIn: ttlSeconds, ok: true };
}
