import { describe, it, expect, vi, beforeEach } from 'vitest';

const mocks = vi.hoisted(() => ({
  flush: vi.fn(),
  maybeSingle: vi.fn(),
  sweep: vi.fn(),
}));

vi.mock('@/lib/webhooks/outbox', () => ({
  flushWebhookOutbox: mocks.flush,
}));

vi.mock('@/lib/whatsapp/media-sweeper', () => ({
  sweepPendingMedia: mocks.sweep,
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
  mocks.sweep.mockReset();
  mocks.sweep.mockResolvedValue({
    retried: 0,
    settledReady: 0,
    settledFailed: 0,
    dispatched: 0,
    skippedStale: 0,
  });
});

describe('POST /api/cron/webhook-outbox', () => {
  it('rejects a missing or wrong secret', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: { valor: 'secreto' }, error: null });

    expect((await POST(request())).status).toBe(401);
    expect((await POST(request('otro'))).status).toBe(401);
    expect(mocks.flush).not.toHaveBeenCalled();
    expect(mocks.sweep).not.toHaveBeenCalled();
  });

  it('flushes the outbox with the shared secret', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: { valor: 'secreto' }, error: null });
    mocks.flush.mockResolvedValue({ claimed: 2, sent: 1, skipped: 0, pending: 1, failed: 0 });

    const response = await POST(request('secreto'));

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      claimed: 2, sent: 1, skipped: 0, pending: 1, failed: 0,
      media: { retried: 0, settledReady: 0, settledFailed: 0, dispatched: 0, skippedStale: 0 },
    });
    expect(mocks.flush).toHaveBeenCalledTimes(1);
  });

  it('sweeps stale media AFTER flushing the outbox', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: { valor: 'secreto' }, error: null });
    mocks.flush.mockResolvedValue({ claimed: 0, sent: 0, skipped: 0, pending: 0, failed: 0 });
    mocks.sweep.mockResolvedValue({
      retried: 2, settledReady: 1, settledFailed: 1, dispatched: 1, skippedStale: 0,
    });

    const response = await POST(request('secreto'));
    const body = await response.json();

    expect(body.media).toEqual({
      retried: 2, settledReady: 1, settledFailed: 1, dispatched: 1, skippedStale: 0,
    });
    expect(mocks.sweep.mock.invocationCallOrder[0]!).toBeGreaterThan(
      mocks.flush.mock.invocationCallOrder[0]!,
    );
  });

  it('fails when the secret cannot be read', async () => {
    mocks.maybeSingle.mockResolvedValue({ data: null, error: { message: 'boom' } });
    expect((await POST(request('secreto'))).status).toBe(500);
  });
});
