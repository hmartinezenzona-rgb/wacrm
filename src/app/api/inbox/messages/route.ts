// ============================================================
// GET /api/inbox/messages
//
// One request returns a keyset page of an open conversation plus the
// signed URLs for the media that same page shows, so the browser paints
// media from this response instead of waiting for `/api/chat-media/sign`.
//
// Auth is `requireRole('viewer')` and every read uses the caller's
// RLS-scoped client — never the service role. The explicit account check
// in the membership query is the same boundary the sign route has.
//
// Cursor values are interpolated into a PostgREST `or=` filter, so both
// are validated against strict regexes and the raw `created_at` string is
// never normalised through `new Date()` (microseconds would be lost).
//
// A signing failure is NOT an error: the route answers 200 with
// `signed: {}` and the client falls back to the refresh path / proxy.
// ============================================================

import { NextResponse } from 'next/server';

import { requireRole, toErrorResponse } from '@/lib/auth/account';
import { signChatMediaUrls } from '@/lib/storage/chat-media-server';
import {
  THREAD_PAGE_MAX_LIMIT,
  THREAD_UUID_RE,
  isValidThreadCursor,
  parseThreadLimit,
  type ThreadCursor,
  type ThreadPageResponse,
} from '@/lib/inbox/thread-page';
import type { Message } from '@/types';

const NO_STORE = { 'Cache-Control': 'private, no-store' } as const;

function json(body: unknown, status = 200): NextResponse {
  return NextResponse.json(body, { status, headers: NO_STORE });
}

export async function GET(request: Request) {
  let ctx: Awaited<ReturnType<typeof requireRole>>;
  try {
    ctx = await requireRole('viewer');
  } catch (error) {
    const res = toErrorResponse(error);
    res.headers.set('Cache-Control', 'private, no-store');
    return res;
  }

  const { searchParams } = new URL(request.url);

  const conversationId = searchParams.get('conversationId') ?? '';
  if (!THREAD_UUID_RE.test(conversationId)) {
    return json({ error: 'conversationId must be a uuid' }, 400);
  }

  const limit = parseThreadLimit(searchParams.get('limit'));
  if (limit === null) {
    return json({ error: `limit must be an integer between 1 and ${THREAD_PAGE_MAX_LIMIT}` }, 400);
  }

  const rawCreatedAt = searchParams.get('beforeCreatedAt');
  const rawId = searchParams.get('beforeId');
  if ((rawCreatedAt === null) !== (rawId === null)) {
    return json({ error: 'beforeCreatedAt and beforeId are required together' }, 400);
  }

  let cursor: ThreadCursor | null = null;
  if (rawCreatedAt !== null && rawId !== null) {
    const candidate: ThreadCursor = { createdAt: rawCreatedAt, id: rawId };
    // Single source of truth: the client helper's contract decides what a
    // safe cursor is, so the route cannot drift from it.
    if (!isValidThreadCursor(candidate)) {
      return json({ error: 'invalid cursor' }, 400);
    }
    cursor = candidate;
  }

  let pageQuery = ctx.supabase
    .from('messages')
    .select('*')
    .eq('conversation_id', conversationId);
  if (cursor) {
    pageQuery = pageQuery.or(
      `created_at.lt.${cursor.createdAt},and(created_at.eq.${cursor.createdAt},id.lt.${cursor.id})`,
    );
  }
  pageQuery = pageQuery
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
    .limit(limit + 1);

  // Membership and the page run together: the account check must not add
  // a round-trip to the fetch the user is waiting on.
  const [membership, page] = await Promise.all([
    ctx.supabase
      .from('conversations')
      .select('id')
      .eq('id', conversationId)
      .eq('account_id', ctx.accountId)
      .maybeSingle(),
    pageQuery,
  ]);

  if (membership.error) {
    console.error('[inbox messages] membership query failed', membership.error);
    return json({ error: 'Could not verify conversation access' }, 500);
  }
  if (!membership.data) {
    return json({ error: 'Conversation not found' }, 404);
  }
  if (page.error) {
    console.error('[inbox messages] page query failed', page.error);
    return json({ error: 'Could not load messages' }, 500);
  }

  const rows = (page.data ?? []) as Message[];
  // The extra row is the hasMore probe; it is never part of the page.
  const hasMore = rows.length > limit;
  const pageRows = hasMore ? rows.slice(0, limit) : rows;
  const messages = pageRows.slice().reverse();
  const oldest = pageRows[pageRows.length - 1];
  const nextCursor = hasMore && oldest ? { createdAt: oldest.created_at, id: oldest.id } : null;

  const mediaUrls = messages
    .map((message) => message.media_url)
    .filter((url): url is string => typeof url === 'string' && url.length > 0);

  const { signed, expiresIn } = await signChatMediaUrls(mediaUrls, ctx.accountId);

  const body: ThreadPageResponse = { messages, hasMore, nextCursor, signed, expiresIn };
  return json(body);
}
