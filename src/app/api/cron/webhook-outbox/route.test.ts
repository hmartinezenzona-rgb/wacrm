import { describe, it, expect, vi, beforeEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  flush: vi.fn(),
  maybeSingle: vi.fn(),
}));

vi.mock('@/lib/webhooks/outbox', () => ({
  flushWebhookOutbox: mocks.flush,
}));

vi.mock('@supabase/supabase-js', () => ({
  createClient: () => ({
    from: () => ({
      select: () => ({ eq: () => ({ maybeSingle: mocks.maybeSingle }) }),
    }),
  }),
}));

import { POST } from './route';

function request(secret?: string): Request {
  return new Request('http://local/api/cron/webhook-outbox', {
    method: 'POST',
    headers: secret === undefined ? {} : { 'x-cerebro-secret': secret },
  });
}

beforeEach(() => {
  mocks.flush.mockReset();
  mocks.maybeSingle.mockReset();
});

describe('POST /api/cron/webhook-outbox', () => {
  it('rejects a missing or wrong secret', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: { valor: 'secreto' }, error: null });

    expect((await POST(request())).status).toBe(401);
    expect((await POST(request('otro'))).status).toBe(401);
    expect(mocks.flush).not.toHaveBeenCalled();
  });

  it('flushes the outbox with the shared secret', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: { valor: 'secreto' }, error: null });
    mocks.flush.mockResolvedValue({ claimed: 2, sent: 1, skipped: 0, pending: 1, failed: 0 });

    const response = await POST(request('secreto'));

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      claimed: 2, sent: 1, skipped: 0, pending: 1, failed: 0,
    });
    expect(mocks.flush).toHaveBeenCalledTimes(1);
  });

  it('fails when the secret cannot be read', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: null, error: { message: 'boom' } });
    expect((await POST(request('secreto'))).status).toBe(500);
  });
});
