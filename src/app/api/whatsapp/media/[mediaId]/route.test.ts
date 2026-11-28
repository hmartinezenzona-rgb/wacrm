// Route-level tests for GET /api/whatsapp/media/[mediaId]: streams Meta media for the
// shared inbox. The media id must belong to a message of the caller's own account, and
// the response must not be publicly cacheable.

import { beforeEach, describe, expect, it, vi } from 'vitest';

const { createClient, getMediaUrl, downloadMedia } = vi.hoisted(() => ({
  createClient: vi.fn(),
  getMediaUrl: vi.fn(),
  downloadMedia: vi.fn(),
}));

vi.mock('@/lib/supabase/server', () => ({ createClient }));
vi.mock('@/lib/whatsapp/meta-api', () => ({ getMediaUrl, downloadMedia }));
vi.mock('@/lib/whatsapp/encryption', () => ({ decrypt: (v: string) => `dec:${v}` }));

interface Opts {
  user?: { id: string } | null;
  accountId?: string | null;
  config?: { access_token: string } | null;
  /** Result of each successive messages lookup (exact match, then wa-<id> pattern). */
  messageHits?: boolean[];
}

function chain(result: unknown) {
  const b: Record<string, unknown> = {};
  for (const m of ['select', 'eq', 'like', 'limit']) b[m] = vi.fn(() => b);
  b.maybeSingle = vi.fn(async () => result);
  b.single = vi.fn(async () => result);
  b.then = (resolve: (v: unknown) => unknown) => Promise.resolve(result).then(resolve);
  return b;
}

function supabaseFor(opts: Opts) {
  const hits = [...(opts.messageHits ?? [])];
  const messageQueries: Array<Record<string, ReturnType<typeof vi.fn>>> = [];
  const from = vi.fn((table: string) => {
    if (table === 'profiles') {
      return chain({
        data: opts.accountId === null ? null : { account_id: opts.accountId ?? 'acct-1' },
      });
    }
    if (table === 'whatsapp_config') {
      return chain({
        data: opts.config === undefined ? { access_token: 'enc' } : opts.config,
        error: null,
      });
    }
    if (table === 'messages') {
      const q = chain({ data: hits.shift() ? [{ id: 'm1' }] : [], error: null });
      messageQueries.push(q as never);
      return q;
    }
    throw new Error(`unexpected table ${table}`);
  });
  const client = {
    auth: {
      getUser: vi.fn(async () => ({
        data: { user: opts.user === undefined ? { id: 'u1' } : opts.user },
        error: null,
      })),
    },
    from,
  };
  createClient.mockResolvedValue(client);
  return { client, messageQueries };
}

async function get(mediaId = '123456') {
  const { GET } = await import('./route');
  return GET(new Request(`http://local/api/whatsapp/media/${mediaId}`), {
    params: Promise.resolve({ mediaId }),
  });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(console, 'error').mockImplementation(() => {});
  getMediaUrl.mockResolvedValue({ url: 'https://meta/dl', mimeType: 'image/jpeg' });
  downloadMedia.mockResolvedValue({ buffer: Buffer.from([1, 2]), contentType: 'image/jpeg' });
});

describe('GET /api/whatsapp/media/[mediaId]', () => {
  it('unauthenticated -> 401', async () => {
    supabaseFor({ user: null });
    expect((await get()).status).toBe(401);
  });

  it('media referenced by a stored wa-<id> file name of the account -> 200, private cache', async () => {
    const { messageQueries } = supabaseFor({ messageHits: [false, true] });
    const res = await get('123456');
    expect(res.status).toBe(200);
    expect(res.headers.get('Cache-Control')).toBe('private, max-age=3600');
    expect(getMediaUrl).toHaveBeenCalledWith({ mediaId: '123456', accessToken: 'dec:enc' });
    // Scoped to the caller's account through the conversation, and parameterized.
    expect(messageQueries[1].eq).toHaveBeenCalledWith('conversations.account_id', 'acct-1');
    expect(messageQueries[1].like).toHaveBeenCalledWith('media_url', '%wa-123456.%');
  });

  it('media referenced by the proxy URL form -> 200', async () => {
    const { messageQueries } = supabaseFor({ messageHits: [true] });
    expect((await get('123456')).status).toBe(200);
    expect(messageQueries[0].eq).toHaveBeenCalledWith('media_url', '/api/whatsapp/media/123456');
  });

  it("media of another account (no referencing message) -> 404, Meta never called", async () => {
    supabaseFor({ messageHits: [false, false] });
    expect((await get('999')).status).toBe(404);
    expect(getMediaUrl).not.toHaveBeenCalled();
    expect(downloadMedia).not.toHaveBeenCalled();
  });

  it('media id with unexpected characters -> 404 before any lookup', async () => {
    const { client } = supabaseFor({ messageHits: [true] });
    expect((await get('1%25;drop')).status).toBe(404);
    expect(client.from).not.toHaveBeenCalledWith('messages');
    expect(getMediaUrl).not.toHaveBeenCalled();
  });

  it('profile without an account -> 403', async () => {
    supabaseFor({ accountId: null });
    expect((await get()).status).toBe(403);
  });
});
