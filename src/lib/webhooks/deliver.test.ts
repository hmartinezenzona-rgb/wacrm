import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

vi.mock('@/lib/whatsapp/encryption', () => ({
  decrypt: (s: string) => s,
  encrypt: (s: string) => s,
}));

// Control the SSRF guard per-test.
vi.mock('@/lib/webhooks/ssrf', () => ({
  isDeliverableUrl: vi.fn(async () => true),
}));

import { dispatchWebhookEvent, DELIVERY_ATTEMPTS, MAX_CONSECUTIVE_FAILURES } from './deliver';
import { isDeliverableUrl } from './ssrf';

interface Row {
  id: string;
  url: string;
  secret: string;
}
interface Calls {
  updates: { id: string; payload: Record<string, unknown> }[];
  rpcs: { name: string; args: Record<string, unknown> }[];
}

function makeDb(rows: Row[], calls: Calls) {
  const from = () => {
    let mode: 'select' | 'update' = 'select';
    let payload: Record<string, unknown> = {};
    let id: string | null = null;
    const b: Record<string, unknown> = {
      select: () => b,
      eq: (col: string, val: string) => {
        if (col === 'id') id = val;
        return b;
      },
      update: (p: Record<string, unknown>) => {
        mode = 'update';
        payload = p;
        return b;
      },
      contains: () => Promise.resolve({ data: rows, error: null }),
      then: (resolve: (v: unknown) => unknown) => {
        if (mode === 'update' && id) calls.updates.push({ id, payload });
        return resolve({ data: null, error: null });
      },
    };
    return b;
  };
  const rpc = (name: string, args: Record<string, unknown>) => {
    calls.rpcs.push({ name, args });
    return Promise.resolve({ data: null, error: null });
  };
  return { from, rpc } as unknown as SupabaseClient;
}

const emptyCalls = (): Calls => ({ updates: [], rpcs: [] });

beforeEach(() => {
  vi.mocked(isDeliverableUrl).mockResolvedValue(true);
  vi.stubGlobal('fetch', vi.fn());
});
afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('dispatchWebhookEvent', () => {
  it('signs + POSTs (no redirect follow) and resets failure_count on success', async () => {
    const fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 200 } as Response);
    vi.stubGlobal('fetch', fetchMock);
    const calls = emptyCalls();

    await dispatchWebhookEvent(
      makeDb([{ id: 'a', url: 'https://a.test/hook', secret: 's1' }], calls),
      'acct-1',
      'message.received',
      { x: 1 }
    );

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe('https://a.test/hook');
    expect(opts.redirect).toBe('manual');
    expect(opts.headers['X-Wacrm-Event']).toBe('message.received');
    expect(opts.headers['X-Wacrm-Signature']).toMatch(/^t=\d+,v1=[0-9a-f]{64}$/);
    // Payload carries a dedupe id.
    expect(JSON.parse(opts.body).id).toMatch(/[0-9a-f-]{36}/);
    expect(calls.updates[0]).toMatchObject({ id: 'a', payload: { failure_count: 0 } });
    expect(calls.rpcs).toHaveLength(0);
  });

  it('records one atomic failure (RPC) once every attempt errored', async () => {
    vi.useFakeTimers();
    const fetchMock = vi.fn().mockResolvedValue({ ok: false, status: 500 } as Response);
    vi.stubGlobal('fetch', fetchMock);
    const calls = emptyCalls();

    const done = dispatchWebhookEvent(
      makeDb([{ id: 'b', url: 'https://b.test/hook', secret: 's2' }], calls),
      'acct-1',
      'message.received',
      {}
    );
    await vi.runAllTimersAsync();
    await done;

    expect(fetchMock).toHaveBeenCalledTimes(DELIVERY_ATTEMPTS);
    expect(calls.rpcs).toEqual([
      {
        name: 'record_webhook_failure',
        args: { endpoint_id: 'b', max_failures: MAX_CONSECUTIVE_FAILURES },
      },
    ]);
    expect(calls.updates).toHaveLength(0);
  });

  // A receiver that stalls for a few seconds (the Cerebro's n8n did, every 10
  // minutes, on 2026-09-28/30) must not lose the customer's message: a
  // single 5 s attempt dropped it for good.
  describe('retries a transient failure', () => {
    beforeEach(() => vi.useFakeTimers());

    async function dispatchWith(fetchMock: ReturnType<typeof vi.fn>, calls: Calls) {
      vi.stubGlobal('fetch', fetchMock);
      const done = dispatchWebhookEvent(
        makeDb([{ id: 'r', url: 'https://r.test/hook', secret: 's9' }], calls),
        'acct-1',
        'message.received',
        { whatsapp_message_id: 'wamid.X' }
      );
      await vi.runAllTimersAsync();
      await done;
    }

    it('delivers on a later attempt after a timeout, with no failure recorded', async () => {
      const timeout = Object.assign(new Error('The operation was aborted due to timeout'), {
        name: 'TimeoutError',
      });
      const fetchMock = vi
        .fn()
        .mockRejectedValueOnce(timeout)
        .mockResolvedValueOnce({ ok: true, status: 200 } as Response);
      const calls = emptyCalls();

      await dispatchWith(fetchMock, calls);

      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(calls.rpcs).toHaveLength(0);
      expect(calls.updates[0]).toMatchObject({ id: 'r', payload: { failure_count: 0 } });
    });

    it('retries 5xx and 429, not other 4xx', async () => {
      const retried = vi
        .fn()
        .mockResolvedValueOnce({ ok: false, status: 503 } as Response)
        .mockResolvedValueOnce({ ok: false, status: 429 } as Response)
        .mockResolvedValueOnce({ ok: true, status: 200 } as Response);
      await dispatchWith(retried, emptyCalls());
      expect(retried).toHaveBeenCalledTimes(3);

      const rejected = vi.fn().mockResolvedValue({ ok: false, status: 401 } as Response);
      const calls = emptyCalls();
      await dispatchWith(rejected, calls);
      expect(rejected).toHaveBeenCalledTimes(1);
      expect(calls.rpcs).toHaveLength(1);
    });

    it('resends the same payload (same dedupe id), freshly signed each time', async () => {
      const fetchMock = vi
        .fn()
        .mockResolvedValueOnce({ ok: false, status: 502 } as Response)
        .mockResolvedValueOnce({ ok: true, status: 200 } as Response);

      await dispatchWith(fetchMock, emptyCalls());

      const [first, second] = fetchMock.mock.calls.map((c) => c[1]);
      expect(second.body).toBe(first.body);
      const ts = (o: { headers: Record<string, string> }) =>
        Number(o.headers['X-Wacrm-Signature'].match(/^t=(\d+),/)![1]);
      // A replayed signature is rejected by receivers that keep nonces (the
      // Cerebro does), so each attempt carries its own timestamp.
      expect(ts(second)).toBeGreaterThan(ts(first));
    });
  });

  it('blocks a non-public target (SSRF guard) without fetching', async () => {
    vi.mocked(isDeliverableUrl).mockResolvedValue(false);
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const calls = emptyCalls();

    await dispatchWebhookEvent(
      makeDb([{ id: 'c', url: 'https://127.0.0.1/hook', secret: 's3' }], calls),
      'acct-1',
      'message.received',
      {}
    );

    expect(fetchMock).not.toHaveBeenCalled();
    expect(calls.rpcs[0].name).toBe('record_webhook_failure');
  });

  it('does nothing when no endpoints are subscribed', async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
    const calls = emptyCalls();
    await dispatchWebhookEvent(makeDb([], calls), 'acct-1', 'message.received', {});
    expect(fetchMock).not.toHaveBeenCalled();
    expect(calls.rpcs).toHaveLength(0);
    expect(calls.updates).toHaveLength(0);
  });
});
