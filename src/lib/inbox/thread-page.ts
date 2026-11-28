// ============================================================
// Cursor contracts and the client helper for GET /api/inbox/messages.
//
// The route returns one page of messages together with the signed URLs
// of the media that page shows, so the first paint needs no second
// signing round-trip. The client sends back the RAW `created_at` string
// it received: normalising it through `new Date().toISOString()` would
// truncate microseconds and the keyset would then skip or repeat
// messages that share a millisecond.
// ============================================================

import type { Message } from '@/types';

export interface ThreadCursor {
  /** Raw PostgREST timestamp, exactly as it came back. */
  createdAt: string;
  id: string;
}

export interface ThreadPageResponse {
  /** Chronological ascending, ready for rendering. */
  messages: Message[];
  /** Exact from the `limit + 1` probe. */
  hasMore: boolean;
  /** Oldest row of this page when `hasMore`; the next request starts after it. */
  nextCursor: ThreadCursor | null;
  /** Key = stored `media_url`, or the proxy form of a thumbnail path. */
  signed: Record<string, string>;
  /** Seconds; 3600, never longer. */
  expiresIn: number;
}

export const THREAD_PAGE_DEFAULT_LIMIT = 50;
export const THREAD_PAGE_MAX_LIMIT = 100;

export const THREAD_UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * PostgREST timestamp shape. Interpolated into an `or=` filter string, so
 * commas, parentheses and dots outside the fraction are refused.
 */
export const THREAD_CURSOR_CREATED_AT_RE =
  /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}(:?\d{2})?)$/;

export function isValidThreadCursor(cursor: ThreadCursor): boolean {
  return THREAD_CURSOR_CREATED_AT_RE.test(cursor.createdAt) && THREAD_UUID_RE.test(cursor.id);
}

/** Build the cursor from a row without touching its timestamp. */
export function cursorFromMessage(message: Pick<Message, 'created_at' | 'id'>): ThreadCursor {
  return { createdAt: message.created_at, id: message.id };
}

/** The cursor pair as query parameters; empty when there is no cursor. */
export function threadCursorQuery(cursor: ThreadCursor | null | undefined): URLSearchParams {
  const params = new URLSearchParams();
  if (!cursor) return params;
  params.set('beforeCreatedAt', cursor.createdAt);
  params.set('beforeId', cursor.id);
  return params;
}

/** `limit` from the query string: default when absent, null when invalid. */
export function parseThreadLimit(raw: string | null): number | null {
  if (raw === null || raw === '') return THREAD_PAGE_DEFAULT_LIMIT;
  const limit = Number(raw);
  if (!Number.isInteger(limit) || limit < 1 || limit > THREAD_PAGE_MAX_LIMIT) return null;
  return limit;
}

/** Fetch one page plus its signed media map. Throws on a non-2xx answer. */
export async function fetchThreadPage(
  conversationId: string,
  cursor?: ThreadCursor,
  limit?: number,
): Promise<ThreadPageResponse> {
  const params = new URLSearchParams({ conversationId });
  params.set('limit', String(limit ?? THREAD_PAGE_DEFAULT_LIMIT));
  for (const [key, value] of threadCursorQuery(cursor)) params.set(key, value);

  const res = await fetch(`/api/inbox/messages?${params.toString()}`, {
    headers: { Accept: 'application/json' },
    credentials: 'same-origin',
  });
  const body = (await res.json().catch(() => null)) as
    | (ThreadPageResponse & { error?: string })
    | null;

  if (!res.ok) {
    const message =
      body && typeof body.error === 'string'
        ? body.error
        : `Thread page request failed (${res.status})`;
    throw new Error(message);
  }

  return body as ThreadPageResponse;
}
