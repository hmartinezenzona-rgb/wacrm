import { beforeEach, describe, expect, it, vi } from 'vitest';

// The route signs through the shared helper, which talks to Storage with the
// service role. Mocking only that boundary keeps the real account gate in play,
// so a foreign path is proven to stay out of `signed`.
const createSignedUrls = vi.fn();
vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({ storage: { from: () => ({ createSignedUrls }) } }),
}));

const requireRole = vi.fn();
vi.mock('@/lib/auth/account', async () => {
  const actual = await vi.importActual<typeof import('@/lib/auth/account')>('@/lib/auth/account');
  return { ...actual, requireRole: (...args: unknown[]) => requireRole(...args) };
});

import { ForbiddenError, UnauthorizedError } from '@/lib/auth/account';
import { GET } from './route';

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const FOREIGN_ACCT = '99999999-1111-4222-8333-444455556666';
const CONV = '6d1f0b8e-2a34-4c55-8f60-1b2c3d4e5f70';
const OTHER_CONV = '7e2a1c9f-3b45-4d66-9071-2c3d4e5f6071';
const CURSOR_ID = '0f9e8d7c-6b5a-4493-8271-0a1b2c3d4e5f';

const chatMediaUrl = (account: string, name: string) =>
  `https://abc.supabase.co/storage/v1/object/public/chat-media/account-${account}/${name}`;

function row(id: string, createdAt: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    conversation_id: CONV,
    sender_type: 'customer',
    content_type: 'text',
    status: 'delivered',
    created_at: createdAt,
    ...extra,
  };
}

/** Chainable PostgREST double: records calls and resolves `result` when awaited. */
function queryBuilder(result: () => unknown) {
  const calls: unknown[][] = [];
  const query: Record<string, unknown> = { calls };
  for (const method of ['select', 'eq', 'or', 'order', 'limit']) {
    query[method] = vi.fn((...args: unknown[]) => {
      calls.push([method, ...args]);
      return query;
    });
  }
  query.maybeSingle = vi.fn(() => Promise.resolve(result()));
  query.then = (onFulfilled: (value: unknown) => unknown, onRejected: (reason: unknown) => unknown) =>
    Promise.resolve(result()).then(onFulfilled, onRejected);
  return query as typeof query & { calls: unknown[][] };
}

function calledWith(query: { calls: unknown[][] }, method: string): unknown[][] {
  return query.calls.filter(([name]) => name === method);
}

let pageResult: { data: unknown; error: unknown };
let conversationResult: { data: unknown; error: unknown };
let messages: ReturnType<typeof queryBuilder>;
let conversations: ReturnType<typeof queryBuilder>;
let supabase: { from: ReturnType<typeof vi.fn> };

function request(params: Record<string, string>): Request {
  return new Request(`http://local/api/inbox/messages?${new URLSearchParams(params).toString()}`, {
    method: 'GET',
  });
}

beforeEach(() => {
  pageResult = { data: [], error: null };
  conversationResult = { data: { id: CONV }, error: null };
  messages = queryBuilder(() => pageResult);
  conversations = queryBuilder(() => conversationResult);
  supabase = {
    from: vi.fn((table: string) => (table === 'conversations' ? conversations : messages)),
  };
  requireRole.mockResolvedValue({ accountId: ACCT, supabase });
  vi.spyOn(console, 'error').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

describe('GET /api/inbox/messages authorisation', () => {
  it('requires the viewer role and an authenticated session', async () => {
    pageResult = {
      data: [row('m1', '2026-11-27T10:00:00.000000+00:00')],
      error: null,
    };
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(200);
    expect(requireRole).toHaveBeenCalledWith('viewer');
  });

  it('passes a 401 through when there is no session', async () => {
    requireRole.mockRejectedValue(new UnauthorizedError());
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(401);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
  });

  it('passes a 403 through when the role is below viewer', async () => {
    requireRole.mockRejectedValue(new ForbiddenError("This action requires the 'viewer' role or higher"));
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(403);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
  });

  it('answers 404 for a conversation of another account and signs nothing', async () => {
    conversationResult = { data: null, error: null };
    pageResult = { data: [row('m1', '2026-11-27T10:00:00.000000+00:00', { media_url: chatMediaUrl(ACCT, 'a.jpg') })], error: null };
    const res = await GET(request({ conversationId: OTHER_CONV }));
    expect(res.status).toBe(404);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
    expect(createSignedUrls).not.toHaveBeenCalled();
  });

  it('answers 500 when the membership query errors, not 404', async () => {
    conversationResult = { data: null, error: { message: 'membership query failed' } };
    pageResult = { data: [], error: null };
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(500);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
    expect(console.error).toHaveBeenCalled();
  });
});

describe('GET /api/inbox/messages validation', () => {
  it.each([
    ['missing conversationId', {}],
    ['invalid uuid', { conversationId: 'not-a-uuid' }],
    ['limit zero', { conversationId: CONV, limit: '0' }],
    ['limit over the maximum', { conversationId: CONV, limit: '101' }],
    ['only beforeCreatedAt', { conversationId: CONV, beforeCreatedAt: '2026-11-27T10:00:00.123456+00:00' }],
    ['only beforeId', { conversationId: CONV, beforeId: CURSOR_ID }],
    ['cursor with a comma', { conversationId: CONV, beforeCreatedAt: '2026-11-27T10:00:00.123,id.gt.1', beforeId: CURSOR_ID }],
    ['cursor with a parenthesis', { conversationId: CONV, beforeCreatedAt: '2026-11-27T10:00:00.123)x', beforeId: CURSOR_ID }],
    ['cursor id injection', { conversationId: CONV, beforeCreatedAt: '2026-11-27T10:00:00Z', beforeId: `${CURSOR_ID},id.gt.0` }],
  ])('rejects %s with 400', async (_label, params) => {
    const res = await GET(request(params as Record<string, string>));
    expect(res.status).toBe(400);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
    await expect(res.json()).resolves.toHaveProperty('error');
  });
});

describe('GET /api/inbox/messages page', () => {
  it('reads the account-scoped page with limit + 1 and returns it ascending', async () => {
    pageResult = {
      data: [
        row('m3', '2026-11-27T10:00:02.000000+00:00'),
        row('m2', '2026-11-27T10:00:01.000000+00:00'),
      ],
      error: null,
    };
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(200);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');

    const body = await res.json();
    expect(body.messages.map((m: { id: string }) => m.id)).toEqual(['m2', 'm3']);
    expect(body.hasMore).toBe(false);
    expect(body.nextCursor).toBeNull();
    expect(body.expiresIn).toBe(3600);

    expect(supabase.from).toHaveBeenCalledWith('conversations');
    expect(supabase.from).toHaveBeenCalledWith('messages');
    expect(calledWith(conversations, 'eq')).toEqual([
      ['eq', 'id', CONV],
      ['eq', 'account_id', ACCT],
    ]);
    expect(calledWith(messages, 'eq')).toEqual([['eq', 'conversation_id', CONV]]);
    expect(calledWith(messages, 'order')).toEqual([
      ['order', 'created_at', { ascending: false }],
      ['order', 'id', { ascending: false }],
    ]);
    expect(calledWith(messages, 'limit')).toEqual([['limit', 51]]);
  });

  it('uses the extra row for hasMore and the page cursor', async () => {
    pageResult = {
      data: [
        row('m5', '2026-11-27T10:00:05.000000+00:00'),
        row('m4', '2026-11-27T10:00:04.000000+00:00'),
        row('m3', '2026-11-27T10:00:03.000000+00:00'),
      ],
      error: null,
    };
    const res = await GET(request({ conversationId: CONV, limit: '2' }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.messages.map((m: { id: string }) => m.id)).toEqual(['m4', 'm5']);
    expect(body.hasMore).toBe(true);
    expect(body.nextCursor).toEqual({ createdAt: '2026-11-27T10:00:04.000000+00:00', id: 'm4' });
    expect(calledWith(messages, 'limit')).toEqual([['limit', 3]]);
  });

  it('builds the keyset filter from the raw cursor without reformatting it', async () => {
    const createdAt = '2026-11-27T10:00:03.123456+00:00';
    pageResult = { data: [], error: null };
    const res = await GET(
      request({ conversationId: CONV, beforeCreatedAt: createdAt, beforeId: CURSOR_ID }),
    );
    expect(res.status).toBe(200);
    expect(calledWith(messages, 'or')).toEqual([
      ['or', `created_at.lt.${createdAt},and(created_at.eq.${createdAt},id.lt.${CURSOR_ID})`],
    ]);
  });

  it('answers 500 when the page query fails', async () => {
    pageResult = { data: null, error: { message: 'boom' } };
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(500);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
  });
});

describe('GET /api/inbox/messages signed media map', () => {
  it('signs only chat-media objects of the caller account', async () => {
    const own = chatMediaUrl(ACCT, 'a.jpg');
    const ownProxy = `/api/chat-media/account-${ACCT}/a.jpg`;
    const foreign = chatMediaUrl(FOREIGN_ACCT, 'b.jpg');
    pageResult = {
      data: [
        row('m2', '2026-11-27T10:00:02.000000+00:00', { media_url: foreign }),
        row('m1', '2026-11-27T10:00:01.000000+00:00', { media_url: own }),
        row('m3', '2026-11-27T10:00:03.000000+00:00', { media_url: 'https://example.com/x.png' }),
        row('m4', '2026-11-27T10:00:04.000000+00:00', { media_url: ownProxy }),
      ],
      error: null,
    };
    createSignedUrls.mockResolvedValue({
      data: [{ path: `account-${ACCT}/a.jpg`, signedUrl: 'https://signed/a', error: null }],
      error: null,
    });

    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(200);
    const body = await res.json();

    expect(createSignedUrls).toHaveBeenCalledTimes(1);
    expect(createSignedUrls).toHaveBeenCalledWith([`account-${ACCT}/a.jpg`], 3600);
    expect(body.signed).toEqual({ [own]: 'https://signed/a', [ownProxy]: 'https://signed/a' });
    expect(body.expiresIn).toBe(3600);
  });

  it('answers 200 with an empty signed map when signing fails', async () => {
    pageResult = {
      data: [row('m1', '2026-11-27T10:00:01.000000+00:00', { media_url: chatMediaUrl(ACCT, 'a.jpg') })],
      error: null,
    };
    createSignedUrls.mockResolvedValue({ data: null, error: { message: 'boom' } });
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.signed).toEqual({});
    expect(body.expiresIn).toBe(3600);
  });

  it('answers 200 with an empty signed map when Storage rejects the signing promise', async () => {
    pageResult = {
      data: [row('m1', '2026-11-27T10:00:01.000000+00:00', { media_url: chatMediaUrl(ACCT, 'a.jpg') })],
      error: null,
    };
    createSignedUrls.mockRejectedValueOnce(new Error('storage unreachable'));
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.signed).toEqual({});
    expect(body.expiresIn).toBe(3600);
    expect(res.headers.get('Cache-Control')).toBe('private, no-store');
  });

  it('does not touch Storage when the page has no media', async () => {
    pageResult = { data: [row('m1', '2026-11-27T10:00:01.000000+00:00')], error: null };
    const res = await GET(request({ conversationId: CONV }));
    expect(res.status).toBe(200);
    await expect(res.json()).resolves.toMatchObject({ signed: {} });
    expect(createSignedUrls).not.toHaveBeenCalled();
  });
});
