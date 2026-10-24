import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { SupabaseClient } from '@supabase/supabase-js';

vi.mock('@/lib/whatsapp/encryption', () => ({
  decrypt: (s: string) => s,
  encrypt: (s: string) => s,
}));
vi.mock('@/lib/webhooks/ssrf', () => ({
  isDeliverableUrl: vi.fn(async () => true),
}));
vi.mock('@/lib/webhooks/deliver', () => ({
  sendOnce: vi.fn(),
  dispatchWebhookEvent: vi.fn(async () => undefined),
}));

import { sendOnce, dispatchWebhookEvent } from '@/lib/webhooks/deliver';
import {
  deliverOutboxRow,
  dispatchMessageReceivedDurably,
  flushWebhookOutbox,
  outboxBackoffSeconds,
  type OutboxRow,
} from './outbox';

interface State {
  sessionEvent: { id: string } | null;
  endpoint: { id: string; url: string; secret: string } | null;
  inserted: unknown[] | null;
  claimRows: OutboxRow[] | null;
  updates: { id: string; patch: Record<string, unknown> }[];
}

function makeDb(state: State) {
  const from = (table: string) => {
    const b: Record<string, unknown> = {
      select: () => b,
      eq: () => b,
      in: () => b,
      lt: () => b,
      limit: () => b,
      contains: () => Promise.resolve({ data: state.endpoint ? [state.endpoint] : [], error: null }),
      maybeSingle: () => {
        if (table === 'session_events') return Promise.resolve({ data: state.sessionEvent, error: null });
        if (table === 'webhook_endpoints') return Promise.resolve({ data: state.endpoint, error: null });
        return Promise.resolve({ data: null, error: null });
      },
      update: (patch: Record<string, unknown>) => {
        let id = '';
        const u: Record<string, unknown> = {
          eq: (_col: string, val: string) => {
            id = val;
            state.updates.push({ id, patch });
            return Promise.resolve({ data: null, error: null });
          },
        };
        return u;
      },
      insert: () => ({
        select: () => Promise.resolve({ data: state.inserted, error: null }),
      }),
      delete: () => ({ in: () => ({ lt: () => Promise.resolve({ data: null, error: null }) }) }),
      then: (resolve: (v: unknown) => unknown) => resolve({ data: null, error: null }),
    };
    return b;
  };
  const rpc = () => Promise.resolve({ data: state.claimRows, error: null });
  return { from, rpc } as unknown as SupabaseClient;
}

function row(overrides: Partial<OutboxRow> = {}): OutboxRow {
  return {
    id: 'o1',
    account_id: 'acct',
    endpoint_id: 'e1',
    event: 'message.received',
    payload: { data: { whatsapp_message_id: 'wamid.1' } },
    status: 'sending',
    attempts: 0,
    ...overrides,
  };
}

function state(overrides: Partial<State> = {}): State {
  return {
    sessionEvent: null,
    endpoint: { id: 'e1', url: 'https://n8n.test/webhook', secret: 's' },
    inserted: null,
    claimRows: [],
    updates: [],
    ...overrides,
  };
}

beforeEach(() => {
  vi.mocked(sendOnce).mockReset();
});
afterEach(() => {
  vi.unstubAllGlobals();
});

describe('outboxBackoffSeconds', () => {
  it('grows with the attempt and caps at the last step', () => {
    expect(outboxBackoffSeconds(1)).toBe(60);
    expect(outboxBackoffSeconds(3)).toBe(300);
    expect(outboxBackoffSeconds(99)).toBe(43200);
  });
});

describe('deliverOutboxRow', () => {
  it('sends and marks the row sent', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });
    const s = state();
    const db = makeDb(s);

    expect(await deliverOutboxRow(db, row())).toBe('sent');
    expect(sendOnce).toHaveBeenCalledTimes(1);
    expect(s.updates.at(-1)?.patch).toMatchObject({ status: 'sent', attempts: 1 });
  });

  it('leaves a retryable failure pending with backoff', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: false, retryable: true, error: 'timeout' });
    const s = state();

    expect(await deliverOutboxRow(makeDb(s), row())).toBe('pending');
    const patch = s.updates.at(-1)?.patch ?? {};
    expect(patch).toMatchObject({ status: 'pending', attempts: 1, last_error: 'timeout' });
    expect(patch.next_attempt_at).toBeTruthy();
  });

  it('fails after the last attempt', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: false, retryable: true, error: 'timeout' });
    const s = state();

    expect(await deliverOutboxRow(makeDb(s), row({ attempts: 9 }))).toBe('failed');
    expect(s.updates.at(-1)?.patch).toMatchObject({ status: 'failed', attempts: 10 });
  });

  it('does not re-send a wamid the Cerebro already processed', async () => {
    const s = state({ sessionEvent: { id: 'se1' } });

    expect(await deliverOutboxRow(makeDb(s), row())).toBe('skipped');
    expect(sendOnce).not.toHaveBeenCalled();
    expect(s.updates.at(-1)?.patch).toMatchObject({ status: 'skipped' });
  });
});

describe('dispatchMessageReceivedDurably', () => {
  it('stores one row per endpoint before the first attempt', async () => {
    const stored = [row()];
    const s = state({ inserted: stored });
    const db = makeDb(s);
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });

    await dispatchMessageReceivedDurably(db, 'acct', { whatsapp_message_id: 'wamid.1' });

    expect(sendOnce).toHaveBeenCalledTimes(1);
    expect(s.updates.at(-1)?.patch).toMatchObject({ status: 'sent' });
    expect(dispatchWebhookEvent).not.toHaveBeenCalled();
  });
});

describe('flushWebhookOutbox', () => {
  it('claims due rows and counts the outcomes', async () => {
    const s = state({ claimRows: [row()] });
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });

    const result = await flushWebhookOutbox(makeDb(s));

    expect(result).toMatchObject({ claimed: 1, sent: 1, skipped: 0, pending: 0, failed: 0 });
  });

  it('claims nothing when no row is due', async () => {
    const result = await flushWebhookOutbox(makeDb(state()));
    expect(result.claimed).toBe(0);
  });
});
