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
 * Signatures already issued, keyed by account + object path.
 *
 * One Storage signing call costs a fixed ~100–160 ms of network no matter
 * how many paths it carries (`createSignedUrls` does the work server-side
 * in one round trip), so the win is not a smaller batch — it is not
 * paying the round trip again. Reopening a thread, or paging back into
 * history, re-signs almost nothing: entries are reused while they are
 * still comfortably valid.
 *
 * A signature is only reused when its remaining life covers the TTL the
 * caller asked for, so `expiresIn` in the response stays truthful.
 */
interface SignCacheEntry {
  signedUrl: string;
  expiresAt: number;
}

const SIGN_CACHE = new Map<string, SignCacheEntry>();

/** Bound the map so a long-lived server cannot grow it without limit. */
const SIGN_CACHE_MAX_ENTRIES = 5000;

/**
 * How much life a cached signature must still have before it is handed
 * out again. Seconds, not milliseconds of margin: a page opened right
 * after another one must reuse, and a URL must not be delivered so close
 * to expiry that the browser requests it as it dies.
 */
const SIGN_CACHE_MIN_REMAINING_MS = 5 * 60 * 1000;

/** Test-only: the cache is module state and must not leak between tests. */
export function __resetSignCache(): void {
  SIGN_CACHE.clear();
}

function cacheKey(accountId: string, path: string): string {
  return `${accountId}\u0000${path}`;
}

/**
 * The cached entry for `path`, if it still has useful life left. An
 * entry is reused while MORE than `SIGN_CACHE_MIN_REMAINING_MS` remains,
 * regardless of the TTL the caller asked for: the URL works for exactly
 * as long as Storage said, and the response reports what is left so the
 * client refreshes on time.
 */
function readCachedSignature(
  accountId: string,
  path: string,
  now: number,
): SignCacheEntry | null {
  const key = cacheKey(accountId, path);
  const entry = SIGN_CACHE.get(key);
  if (!entry) return null;
  if (entry.expiresAt - now <= SIGN_CACHE_MIN_REMAINING_MS) {
    SIGN_CACHE.delete(key);
    return null;
  }
  return entry;
}

function writeCachedSignature(
  accountId: string,
  path: string,
  signedUrl: string,
  ttlSeconds: number,
  now: number,
): void {
  if (SIGN_CACHE.size >= SIGN_CACHE_MAX_ENTRIES) {
    const oldest = SIGN_CACHE.keys().next();
    if (!oldest.done) SIGN_CACHE.delete(oldest.value);
  }
  SIGN_CACHE.set(cacheKey(accountId, path), {
    signedUrl,
    expiresAt: now + ttlSeconds * 1000,
  });
}

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

  const now = Date.now();
  const missing: string[] = [];
  const reusable = new Map<string, string>();
  // The shortest life among the URLs being returned, in ms. Fresh ones
  // start at the requested TTL; reused ones shorten it.
  let shortestRemainingMs = ttlSeconds * 1000;
  for (const path of byPath.keys()) {
    const cached = readCachedSignature(accountId, path, now);
    if (cached) {
      reusable.set(path, cached.signedUrl);
      shortestRemainingMs = Math.min(shortestRemainingMs, cached.expiresAt - now);
    } else {
      missing.push(path);
    }
  }
  const expiresIn = Math.max(1, Math.floor(shortestRemainingMs / 1000));

  const signed: Record<string, string> = {};
  const fill = (path: string, signedUrl: string): void => {
    for (const original of byPath.get(path) ?? []) signed[original] = signedUrl;
  };

  for (const [path, url] of reusable) fill(path, url);

  // Everything asked for was still valid: no Storage round trip at all.
  if (missing.length === 0) return { signed, expiresIn, ok: true };

  try {
    const { data, error } = await supabaseAdmin()
      .storage.from(CHAT_MEDIA_BUCKET)
      .createSignedUrls(missing, ttlSeconds);

    if (error || !data) {
      console.error('[chat-media] could not sign batch:', error?.message ?? 'no data');
      return { signed: reusable.size ? signed : {}, expiresIn, ok: reusable.size > 0 };
    }

    for (const row of data) {
      if (!row.signedUrl || !row.path) continue;
      fill(row.path, row.signedUrl);
      writeCachedSignature(accountId, row.path, row.signedUrl, ttlSeconds, now);
    }

    return { signed, expiresIn: ttlSeconds, ok: true };
  } catch (thrown) {
    // A rejected Storage/PostgREST promise is a signing failure, not a
    // route failure: the caller must still answer with its documented
    // fail-safe shape instead of letting the rejection escape.
    console.error(
      '[chat-media] could not sign batch:',
      thrown instanceof Error ? thrown.message : String(thrown),
    );
    return { signed: reusable.size ? signed : {}, expiresIn, ok: reusable.size > 0 };
  }
}
