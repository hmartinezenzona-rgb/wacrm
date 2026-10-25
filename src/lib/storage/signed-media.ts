// ============================================================
// Client half of the signed chat-media URLs.
//
// Every image/video/audio used to go through `/api/chat-media/<path>`,
// which costs the server an auth check, two account queries and a full
// object download per file. Instead the client asks `/api/chat-media/sign`
// once for the whole batch it is about to render and gets time-boxed URLs
// that the browser fetches straight from Supabase's CDN.
//
// Fails safe: when signing is unavailable (endpoint down, offline, not a
// chat-media URL) `resolveMediaSrc` returns the same proxy URL as before,
// so the UI never regresses to a broken asset.
// ============================================================

import { isChatMediaUrl, toChatMediaSrc } from './chat-media';

/** Must stay under the route's TTL so a URL is never used near expiry. */
const REFRESH_MARGIN_MS = 5 * 60 * 1000;

interface CacheEntry {
  signed: string;
  expiresAt: number;
}

const cache = new Map<string, CacheEntry>();

/** URLs waiting for the next flush, so one call signs them together. */
let queued = new Set<string>();
let flushTimer: ReturnType<typeof setTimeout> | null = null;
let inFlight: Promise<void> | null = null;

function isFresh(entry: CacheEntry | undefined, now: number): entry is CacheEntry {
  return !!entry && entry.expiresAt - REFRESH_MARGIN_MS > now;
}

async function flush(): Promise<void> {
  flushTimer = null;
  const urls = [...queued];
  queued = new Set();
  if (urls.length === 0) return;

  try {
    const res = await fetch('/api/chat-media/sign', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ urls }),
    });
    if (!res.ok) return;
    const data = (await res.json().catch(() => null)) as
      | { signed?: Record<string, string>; expiresIn?: number }
      | null;
    if (!data?.signed) return;
    const ttlMs = (data.expiresIn ?? 3600) * 1000;
    const expiresAt = Date.now() + ttlMs;
    for (const [original, signed] of Object.entries(data.signed)) {
      cache.set(original, { signed, expiresAt });
    }
  } catch {
    // Offline or blocked: the caller falls back to the proxy.
  }
}

/** Sign every chat-media URL in the batch that is not already cached. */
function requestSigning(urls: string[]): Promise<void> {
  for (const url of urls) queued.add(url);
  if (!flushTimer && !inFlight) {
    inFlight = new Promise<void>((resolve) => {
      // One microtask-ish window collects the components mounting together.
      flushTimer = setTimeout(() => {
        void flush().finally(() => {
          inFlight = null;
          // Anything queued while flushing goes out in the next batch.
          if (queued.size > 0) void requestSigning([]);
          resolve();
        });
      }, 10);
    });
  }
  return inFlight ?? Promise.resolve();
}

/**
 * Best URL for `url`: a signed one when available, the same-origin proxy
 * otherwise. Never throws.
 */
export async function resolveMediaSrc(url: string | null | undefined): Promise<string> {
  if (!url) return '';
  if (!isChatMediaUrl(url)) return url;

  const now = Date.now();
  const cached = cache.get(url);
  if (isFresh(cached, now)) return cached.signed;

  await requestSigning([url]);
  const signed = cache.get(url);
  return signed && isFresh(signed, Date.now()) ? signed.signed : toChatMediaSrc(url);
}

/** Test seam: forget cached URLs and any queued work. */
export function resetSignedMediaCache(): void {
  cache.clear();
  queued = new Set();
  if (flushTimer) clearTimeout(flushTimer);
  flushTimer = null;
  inFlight = null;
}
