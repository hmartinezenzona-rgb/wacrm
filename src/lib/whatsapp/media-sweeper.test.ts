import { beforeEach, describe, expect, it, vi } from 'vitest';

// The sweeper claims stale pending media rows and finishes them.
// Covers: a retried row settles before the tail runs, an already-failed row
// runs the tail only, a row older than 24 h settles without a tail, the
// budget stops the loop, and a second run changes nothing.

const rpc = vi.fn();
const conversationsMaybeSingle = vi.fn();
const configMaybeSingle = vi.fn();

vi.mock('@/lib/flows/admin-client', () => ({
  supabaseAdmin: () => ({
    rpc: (...a: unknown[]) => rpc(...a),
    from: (table: string) => ({
      select: () => ({
        eq: () => ({
          maybeSingle: () =>
            table === 'conversations'
              ? conversationsMaybeSingle()
              : configMaybeSingle(),
        }),
      }),
    }),
  }),
}));

const settleInboundMedia = vi.fn();
vi.mock('@/lib/whatsapp/inbound-media', () => ({
  settleInboundMedia: (...a: unknown[]) => settleInboundMedia(...a),
}));

const runInboundTail = vi.fn();
vi.mock('@/lib/whatsapp/inbound-tail', () => ({
  runInboundTail: (...a: unknown[]) => runInboundTail(...a),
}));

vi.mock('@/lib/whatsapp/encryption', () => ({
  decrypt: (value: string) => `decrypted:${value}`,
}));

import { mediaIdFromUrl, sweepPendingMedia } from './media-sweeper';

function row(over: Partial<Record<string, unknown>> = {}) {
  return {
    id: 'msg-1',
    conversation_id: 'conv-1',
    message_id: 'wamid.1',
    media_url: '/api/whatsapp/media/meta-1',
    content_type: 'image',
    content_text: null,
    created_at: new Date().toISOString(),
    media_attempts: 1,
    accion: 'reintentar',
    ...over,
  };
}

beforeEach(() => {
  vi.clearAllMocks();
  conversationsMaybeSingle.mockResolvedValue({
    data: { account_id: 'acct-1', contact_id: 'contact-1' },
    error: null,
  });
  configMaybeSingle.mockResolvedValue({
    data: { access_token: 'tok', user_id: 'user-1' },
    error: null,
  });
  settleInboundMedia.mockResolvedValue('ready');
  rpc.mockResolvedValue({ data: [], error: null });
});

describe('mediaIdFromUrl', () => {
  it('reads the Meta id out of the legacy proxy URL', () => {
    expect(mediaIdFromUrl('/api/whatsapp/media/12345')).toBe('12345');
    expect(mediaIdFromUrl('https://x/api/whatsapp/media/abc?z=1')).toBe('abc');
  });

  it('returns null for anything else', () => {
    expect(mediaIdFromUrl('https://cdn.example.com/a.jpg')).toBeNull();
    expect(mediaIdFromUrl(null)).toBeNull();
  });
});

describe('sweepPendingMedia', () => {
  it('settles a claimed row and then runs the tail', async () => {
    rpc.mockResolvedValue({ data: [row()], error: null });

    const result = await sweepPendingMedia();

    expect(rpc).toHaveBeenCalledWith('crm_media_reclamar', { p_limit: 5 });
    expect(settleInboundMedia).toHaveBeenCalledWith({
      messageId: 'msg-1',
      mediaId: 'meta-1',
      accessToken: 'decrypted:tok',
      accountId: 'acct-1',
      contentType: 'image',
    });
    expect(result).toMatchObject({ retried: 1, settledReady: 1, dispatched: 1 });

    // Order matters: the media settled before the bot ran.
    const settleOrder = settleInboundMedia.mock.invocationCallOrder[0]!;
    const tailOrder = runInboundTail.mock.invocationCallOrder[0]!;
    expect(tailOrder).toBeGreaterThan(settleOrder);
  });

  it('counts a failed settle and still runs the tail inside the window', async () => {
    settleInboundMedia.mockResolvedValue('failed');
    rpc.mockResolvedValue({ data: [row()], error: null });

    const result = await sweepPendingMedia();

    expect(result).toMatchObject({ retried: 1, settledFailed: 1, dispatched: 1 });
  });

  it('a row already declared failed runs the tail only, no download', async () => {
    rpc.mockResolvedValue({ data: [row({ accion: 'fallida' })], error: null });

    const result = await sweepPendingMedia();

    expect(settleInboundMedia).not.toHaveBeenCalled();
    expect(runInboundTail).toHaveBeenCalledTimes(1);
    expect(result).toMatchObject({ settledFailed: 1, dispatched: 1 });
  });

  it('a row older than 24 h settles but never dispatches', async () => {
    const old = new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString();
    rpc.mockResolvedValue({ data: [row({ created_at: old })], error: null });

    const result = await sweepPendingMedia();

    expect(settleInboundMedia).toHaveBeenCalledTimes(1);
    expect(runInboundTail).not.toHaveBeenCalled();
    expect(result).toMatchObject({ settledReady: 1, skippedStale: 1, dispatched: 0 });
  });

  it('the budget stops the loop', async () => {
    rpc.mockResolvedValue({
      data: [row(), row({ id: 'msg-2', message_id: 'wamid.2' })],
      error: null,
    });
    // startedAt = 0, the first row is checked at 6 s (inside the budget),
    // the second at 12 s (past it).
    let clock = -6_000;
    const now = () => (clock += 6_000);

    const result = await sweepPendingMedia({ budgetMs: 10_000, now });

    expect(result.retried).toBe(1);
    expect(settleInboundMedia).toHaveBeenCalledTimes(1);
  });

  it('reports a claim error without throwing', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    rpc.mockResolvedValue({ data: null, error: { message: 'boom' } });

    const result = await sweepPendingMedia();
    errorSpy.mockRestore();

    expect(result).toEqual({
      retried: 0,
      settledReady: 0,
      settledFailed: 0,
      dispatched: 0,
      skippedStale: 0,
    });
  });

  it('a claimed row with no account context is left for the next sweep', async () => {
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
    conversationsMaybeSingle.mockResolvedValue({ data: null, error: null });
    rpc.mockResolvedValue({ data: [row()], error: null });

    const result = await sweepPendingMedia();
    warn.mockRestore();

    expect(settleInboundMedia).not.toHaveBeenCalled();
    expect(runInboundTail).not.toHaveBeenCalled();
    expect(result.retried).toBe(1);
  });
});
