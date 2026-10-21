// Route-level tests for GET /api/chat-media/<account-uuid>/<file>: the same-origin
// proxy for the (soon private) chat-media bucket. Session required, the first
// folder must be the caller's own account, bytes come from the service role.

import { beforeEach, describe, expect, it, vi } from 'vitest';

const requireRole = vi.fn();
const downloadChatMedia = vi.fn();

const toErrorResponse = (error: unknown) => {
  const status = (error as { status?: number }).status ?? 500;
  return new Response(JSON.stringify({ error: (error as Error).message }), { status });
};

vi.mock('@/lib/auth/account', () => ({ requireRole, toErrorResponse }));
vi.mock('@/lib/storage/chat-media-server', () => ({ downloadChatMedia }));

const ACCT = '3f2b1c7e-8a41-4c55-9d0e-6b7a1f2e3d4c';
const OTHER = '9a8b7c6d-1111-4222-8333-444455556666';
const FILE = '1700000000000-wa-123.jpg';

function ctx(accountId = ACCT) {
  return { supabase: {}, userId: 'user-a', accountId, role: 'viewer' as const };
}

function call(segments: string[], headers: Record<string, string> = {}) {
  return import('./route').then(({ GET }) =>
    GET(new Request(`http://local/api/chat-media/${segments.join('/')}`, { headers })),
  );
}

const bytes = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

beforeEach(() => {
  vi.clearAllMocks();
  requireRole.mockResolvedValue(ctx());
  downloadChatMedia.mockResolvedValue({ bytes: bytes.buffer.slice(0), contentType: 'image/jpeg' });
});

describe('GET /api/chat-media/[...path]', () => {
  it('unauthenticated -> 401 and no download', async () => {
    requireRole.mockRejectedValueOnce({ message: 'Unauthorized', status: 401 });
    expect((await call([`account-${ACCT}`, FILE])).status).toBe(401);
    expect(downloadChatMedia).not.toHaveBeenCalled();
  });

  it("another account's folder -> 403 and no download", async () => {
    const res = await call([`account-${OTHER}`, FILE]);
    expect(res.status).toBe(403);
    expect(downloadChatMedia).not.toHaveBeenCalled();
  });

  it('unsafe or malformed paths -> 400/403 and no download', async () => {
    for (const segs of [
      [`account-${ACCT}`, '..', FILE],
      [`account-${ACCT}`, 'a%5Cb'],
      [`account-${ACCT}`],
      ['other', FILE],
    ]) {
      const res = await call(segs);
      expect([400, 403]).toContain(res.status);
    }
    expect(downloadChatMedia).not.toHaveBeenCalled();
  });

  it('missing object -> 404', async () => {
    downloadChatMedia.mockResolvedValueOnce(null);
    expect((await call([`account-${ACCT}`, FILE])).status).toBe(404);
  });

  it('serves the object with its content type and private cache headers', async () => {
    const res = await call([`account-${ACCT}`, FILE]);
    expect(res.status).toBe(200);
    expect(downloadChatMedia).toHaveBeenCalledWith(`account-${ACCT}/${FILE}`);
    expect(res.headers.get('Content-Type')).toBe('image/jpeg');
    expect(res.headers.get('Cache-Control')).toBe('private, max-age=3600');
    expect(res.headers.get('X-Content-Type-Options')).toBe('nosniff');
    expect(res.headers.get('Accept-Ranges')).toBe('bytes');
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(bytes);
  });

  it('decodes percent-encoded segments before checking and downloading', async () => {
    await call([`account-${ACCT}`, '1-wa-1%20x.jpg']);
    expect(downloadChatMedia).toHaveBeenCalledWith(`account-${ACCT}/1-wa-1 x.jpg`);
  });

  it('answers a Range request with 206 and the slice', async () => {
    const res = await call([`account-${ACCT}`, FILE], { range: 'bytes=2-4' });
    expect(res.status).toBe(206);
    expect(res.headers.get('Content-Range')).toBe('bytes 2-4/10');
    expect(res.headers.get('Content-Length')).toBe('3');
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(new Uint8Array([2, 3, 4]));
  });

  it('supports open-ended and suffix ranges', async () => {
    const open = await call([`account-${ACCT}`, FILE], { range: 'bytes=8-' });
    expect(open.headers.get('Content-Range')).toBe('bytes 8-9/10');
    const suffix = await call([`account-${ACCT}`, FILE], { range: 'bytes=-3' });
    expect(suffix.headers.get('Content-Range')).toBe('bytes 7-9/10');
  });

  it('unsatisfiable range -> 416', async () => {
    const res = await call([`account-${ACCT}`, FILE], { range: 'bytes=50-60' });
    expect(res.status).toBe(416);
    expect(res.headers.get('Content-Range')).toBe('bytes */10');
  });
});
