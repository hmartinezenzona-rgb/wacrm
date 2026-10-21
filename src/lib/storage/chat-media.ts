// ============================================================
// chat-media URL helpers (pure, safe in client and server code).
//
// Stored `messages.media_url` values keep the shape they were written
// with — `https://<ref>.supabase.co/storage/v1/object/public/chat-media/<path>`.
// Once the bucket is private that URL stops working, so every place that
// DISPLAYS media maps it through `toChatMediaSrc` to the same-origin
// proxy `/api/chat-media/<path>` (session + account check). While the
// bucket is still public the proxy serves the same bytes, so the app
// behaves identically either way.
// ============================================================

export const CHAT_MEDIA_BUCKET = 'chat-media';
export const CHAT_MEDIA_PROXY_PREFIX = '/api/chat-media/';

const STORAGE_PATH_RE =
  /^\/storage\/v1\/object\/(?:public|sign|authenticated)\/chat-media\/(.+)$/;
const FIRST_FOLDER_RE =
  /^account-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Validate an already-decoded object path. Only `account-<uuid>/…`
 * paths with plain segments are accepted: no traversal, no backslashes,
 * no empty segments.
 */
export function isSafeChatMediaPath(path: string): boolean {
  if (!path || path.includes('\\')) return false;
  const segments = path.split('/');
  if (segments.length < 2) return false;
  if (!FIRST_FOLDER_RE.test(segments[0])) return false;
  return segments.every((s) => s !== '' && s !== '.' && s !== '..');
}

/**
 * Extract the object path from a chat-media URL (public, signed or
 * same-origin proxy shape). Returns null for anything else, including
 * chat-media URLs whose path fails `isSafeChatMediaPath`.
 */
export function parseChatMediaPath(url: string | null | undefined): string | null {
  if (!url) return null;
  // Not `new URL(...).pathname`: the URL parser would silently collapse
  // `..` segments and hide the traversal attempt we want to refuse.
  const pathname = url.replace(/^https?:\/\/[^/?#]+/i, '').split(/[?#]/)[0];
  const raw = pathname.startsWith(CHAT_MEDIA_PROXY_PREFIX)
    ? pathname.slice(CHAT_MEDIA_PROXY_PREFIX.length)
    : STORAGE_PATH_RE.exec(pathname)?.[1];
  if (!raw) return null;

  let path: string;
  try {
    path = raw.split('/').map(decodeURIComponent).join('/');
  } catch {
    return null;
  }
  return isSafeChatMediaPath(path) ? path : null;
}

/** A server read/sign was asked for an object outside the caller's account. */
export class ForeignChatMediaError extends Error {
  constructor() {
    super('chat-media object belongs to another account');
    this.name = 'ForeignChatMediaError';
  }
}

/** True when the object path sits under `account-<accountId>/`. */
export function isChatMediaPathOfAccount(path: string, accountId: string | undefined): boolean {
  return !!accountId && path.split('/')[0] === `account-${accountId}`;
}

/**
 * Gate for every service-role read of chat-media: returns the object
 * path when `url` is a chat-media URL of `accountId`, null when it is not
 * a chat-media URL at all (nothing to scope), and throws
 * `ForeignChatMediaError` (logging once) for another account's object or
 * when the account is unknown — fail closed.
 */
export function assertChatMediaAccount(
  url: string | null | undefined,
  accountId: string | undefined,
): string | null {
  const path = parseChatMediaPath(url);
  if (!path) return null;
  if (!isChatMediaPathOfAccount(path, accountId)) {
    console.error('[chat-media] refused a server read outside the sending account');
    throw new ForeignChatMediaError();
  }
  return path;
}

export function isChatMediaUrl(url: string | null | undefined): boolean {
  return parseChatMediaPath(url) !== null;
}

/** Same-origin proxy URL for an object path. */
export function chatMediaProxyUrl(path: string): string {
  return CHAT_MEDIA_PROXY_PREFIX + path.split('/').map(encodeURIComponent).join('/');
}

/**
 * The `src`/`href` to use when DISPLAYING a stored media URL: chat-media
 * URLs go through the authenticated proxy, everything else (Meta proxy
 * URLs, blob: previews, external links, null) passes through unchanged.
 */
export function toChatMediaSrc<T extends string | null | undefined>(url: T): T | string {
  const path = parseChatMediaPath(url);
  return path ? chatMediaProxyUrl(path) : url;
}
