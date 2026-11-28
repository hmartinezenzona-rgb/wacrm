import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import {
  THREAD_PAGE_DEFAULT_LIMIT,
  THREAD_PAGE_MAX_LIMIT,
  cursorFromMessage,
  fetchThreadPage,
  isValidThreadCursor,
  parseThreadLimit,
  threadCursorQuery,
} from './thread-page';

const CONV = '6d1f0b8e-2a34-4c55-8f60-1b2c3d4e5f70';
const CURSOR_ID = '0f9e8d7c-6b5a-4493-8271-0a1b2c3d4e5f';

describe('cursor and limit validation', () => {
  it.each([
    '2026-11-27T10:00:03.123456+00:00',
    '2026-11-27T10:00:03.123456Z',
    '2026-11-27 10:00:03Z',
    '2026-11-27T10:00:03+0000',
    '2026-11-27T10:00:03-05:00',
  ])('accepts the PostgREST timestamp %s', (createdAt) => {
    expect(isValidThreadCursor({ createdAt, id: CURSOR_ID })).toBe(true);
  });

  it.each([
    '2026-11-27T10:00:03.123,id.gt.1',
    '2026-11-27T10:00:03.123)x',
    '2026-11-27',
    '2026-11-27T10:00:03.' + '1'.repeat(7) + 'Z',
    'not-a-date',
  ])('rejects the injection-shaped cursor %s', (createdAt) => {
    expect(isValidThreadCursor({ createdAt, id: CURSOR_ID })).toBe(false);
  });

  it('rejects a cursor id that is not a uuid', () => {
    expect(isValidThreadCursor({ createdAt: '2026-11-27T10:00:03Z', id: 'x,id.gt.0' })).toBe(false);
  });

  it('builds the cursor from the raw message timestamp, never a Date round-trip', () => {
    const createdAt = '2026-11-27T10:00:03.123456+00:00';
    expect(cursorFromMessage({ created_at: createdAt, id: CURSOR_ID })).toEqual({ createdAt, id: CURSOR_ID });
  });

  it('serialises the cursor pair for the query string', () => {
    const cursor = { createdAt: '2026-11-27T10:00:03.123456+00:00', id: CURSOR_ID };
    const params = new URLSearchParams(threadCursorQuery(cursor));
    expect(params.get('beforeCreatedAt')).toBe(cursor.createdAt);
    expect(params.get('beforeId')).toBe(CURSOR_ID);
    expect(threadCursorQuery(null).toString()).toBe('');
  });

  it('defaults, bounds and rejects the limit', () => {
    expect(parseThreadLimit(null)).toBe(THREAD_PAGE_DEFAULT_LIMIT);
    expect(parseThreadLimit('25')).toBe(25);
    expect(parseThreadLimit(String(THREAD_PAGE_MAX_LIMIT))).toBe(THREAD_PAGE_MAX_LIMIT);
    expect(parseThreadLimit('0')).toBeNull();
    expect(parseThreadLimit('101')).toBeNull();
    expect(parseThreadLimit('2.5')).toBeNull();
    expect(parseThreadLimit('abc')).toBeNull();
  });
});

describe('fetchThreadPage', () => {
  beforeEach(() => {
    vi.useRealTimers();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('requests one page and parses the JSON response', async () => {
    const payload = {
      messages: [{ id: 'm1' }],
      hasMore: true,
      nextCursor: { createdAt: '2026-11-27T10:00:03.123456+00:00', id: CURSOR_ID },
      signed: { 'https://x/chat-media/a.jpg': 'https://signed/a' },
      expiresIn: 3600,
    };
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve(payload),
    });
    vi.stubGlobal('fetch', fetchMock);

    const page = await fetchThreadPage(CONV, { createdAt: '2026-11-27T11:00:00Z', id: CURSOR_ID }, 25);

    expect(page).toEqual(payload);
    const [url] = fetchMock.mock.calls[0] as [string];
    expect(url).toContain('/api/inbox/messages?');
    const params = new URL(url, 'http://local').searchParams;
    expect(params.get('conversationId')).toBe(CONV);
    expect(params.get('limit')).toBe('25');
    expect(params.get('beforeCreatedAt')).toBe('2026-11-27T11:00:00Z');
    expect(params.get('beforeId')).toBe(CURSOR_ID);
  });

  it('omits cursor parameters when there is no cursor', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ messages: [], hasMore: false, nextCursor: null, signed: {}, expiresIn: 3600 }),
    });
    vi.stubGlobal('fetch', fetchMock);

    await fetchThreadPage(CONV);

    const [url] = fetchMock.mock.calls[0] as [string];
    const params = new URL(url, 'http://local').searchParams;
    expect(params.has('beforeCreatedAt')).toBe(false);
    expect(params.has('beforeId')).toBe(false);
    expect(params.get('limit')).toBe(String(THREAD_PAGE_DEFAULT_LIMIT));
  });

  it('throws with the server error message when the route answers an error', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn().mockResolvedValue({
        ok: false,
        status: 404,
        json: () => Promise.resolve({ error: 'Conversation not found' }),
      }),
    );

    await expect(fetchThreadPage(CONV)).rejects.toThrow('Conversation not found');
  });
});
