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
  MAX_CONSECUTIVE_FAILURES: 15,
}));

import { sendOnce, dispatchWebhookEvent } from '@/lib/webhooks/deliver';
import {
  deliverOutboxRow,
  dispatchEventDurably,
  flushWebhookOutbox,
  outboxBackoffSeconds,
  type OutboxRow,
} from './outbox';

interface State {
  sessionEvent: { id: string } | null;
  endpoint: { id: string; url: string; secret: string } | null;
  inserted: unknown[] | null;
  insertedRows: Record<string, unknown>[];
  claimRows: OutboxRow[] | null;
  updates: { table: string; id: string; patch: Record<string, unknown> }[];
  rpcCalls: { name: string; args: Record<string, unknown> }[];
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
      update: (patch: Record<string, unknown>) => ({
        eq: (_col: string, val: string) => {
          state.updates.push({ table, id: val, patch });
          return Promise.resolve({ data: null, error: null });
        },
      }),
      insert: (rows: Record<string, unknown>[]) => {
        state.insertedRows = rows;
        return { select: () => Promise.resolve({ data: state.inserted, error: null }) };
      },
      delete: () => ({ in: () => ({ lt: () => Promise.resolve({ data: null, error: null }) }) }),
      then: (resolve: (v: unknown) => unknown) => resolve({ data: null, error: null }),
    };
    return b;
  };
  const rpc = (name: string, args?: Record<string, unknown>) => {
    state.rpcCalls.push({ name, args: args ?? {} });
    return Promise.resolve({
      data: name === 'cerebro_webhook_outbox_reclamar' ? state.claimRows : null,
      error: null,
    });
  };
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
    insertedRows: [],
    claimRows: [],
    updates: [],
    rpcCalls: [],
    ...overrides,
  };
}

function outboxUpdates(s: State) {
  return s.updates.filter((u) => u.table === 'webhook_outbox');
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
    expect(outboxUpdates(s).at(-1)?.patch).toMatchObject({ status: 'sent', attempts: 1 });
  });

  it('leaves a retryable failure pending with backoff', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: false, retryable: true, error: 'timeout' });
    const s = state();

    expect(await deliverOutboxRow(makeDb(s), row())).toBe('pending');
    const patch = outboxUpdates(s).at(-1)?.patch ?? {};
    expect(patch).toMatchObject({ status: 'pending', attempts: 1, last_error: 'timeout' });
    expect(patch.next_attempt_at).toBeTruthy();
  });

  it('fails after the last attempt', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: false, retryable: true, error: 'timeout' });
    const s = state();

    expect(await deliverOutboxRow(makeDb(s), row({ attempts: 9 }))).toBe('failed');
    expect(outboxUpdates(s).at(-1)?.patch).toMatchObject({ status: 'failed', attempts: 10 });
  });

  it('does not re-send a wamid the Cerebro already processed', async () => {
    const s = state({ sessionEvent: { id: 'se1' } });

    expect(await deliverOutboxRow(makeDb(s), row())).toBe('skipped');
    expect(sendOnce).not.toHaveBeenCalled();
    expect(outboxUpdates(s).at(-1)?.patch).toMatchObject({ status: 'skipped' });
  });

  it('resets the endpoint failure streak on success', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });
    const s = state();

    await deliverOutboxRow(makeDb(s), row());

    const endpointUpdate = s.updates.find((u) => u.table === 'webhook_endpoints');
    expect(endpointUpdate).toMatchObject({ id: 'e1', patch: { failure_count: 0 } });
  });

  it('counts a final failure against the endpoint', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: false, retryable: true, error: 'timeout' });
    const s = state();

    expect(await deliverOutboxRow(makeDb(s), row({ attempts: 9 }))).toBe('failed');

    const failure = s.rpcCalls.find((c) => c.name === 'record_webhook_failure');
    expect(failure?.args).toMatchObject({ endpoint_id: 'e1', max_failures: 15 });
  });

  it('does not deliver a stale event', async () => {
    const s = state();
    const stale = row({
      payload: {
        occurred_at: new Date(Date.now() - 3 * 3600 * 1000).toISOString(),
        data: { whatsapp_message_id: 'wamid.1' },
      },
    });

    expect(await deliverOutboxRow(makeDb(s), stale)).toBe('failed');
    expect(sendOnce).not.toHaveBeenCalled();
    expect(outboxUpdates(s).at(-1)?.patch).toMatchObject({ status: 'failed' });
    expect(String(outboxUpdates(s).at(-1)?.patch.last_error)).toContain('stale');
  });

  it('delivers an event within the age limit', async () => {
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });
    const s = state();
    const recent = row({
      payload: {
        occurred_at: new Date(Date.now() - 30 * 60 * 1000).toISOString(),
        data: { whatsapp_message_id: 'wamid.1' },
      },
    });

    expect(await deliverOutboxRow(makeDb(s), recent)).toBe('sent');
  });
});

describe('dispatchEventDurably', () => {
  it('stores one row per endpoint before the first attempt', async () => {
    const stored = [row()];
    const s = state({ inserted: stored });
    const db = makeDb(s);
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });

    await dispatchEventDurably(db, 'acct', 'message.received', { whatsapp_message_id: 'wamid.1' });

    expect(sendOnce).toHaveBeenCalledTimes(1);
    expect(outboxUpdates(s).at(-1)?.patch).toMatchObject({ status: 'sent' });
    expect(dispatchWebhookEvent).not.toHaveBeenCalled();
  });

  it('leases the rows before the inline attempt', async () => {
    const s = state({ inserted: [row()] });
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });

    await dispatchEventDurably(makeDb(s), 'acct', 'message.received', { whatsapp_message_id: 'wamid.1' });

    expect(s.insertedRows[0]).toMatchObject({ status: 'sending', event: 'message.received' });
    expect(s.insertedRows[0]?.locked_until).toBeTruthy();
  });

  it('stores and sends a conversation.created event', async () => {
    const stored = [row({ event: 'conversation.created', payload: { data: { conversation_id: 'c1' } } })];
    const s = state({ inserted: stored });
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });

    await dispatchEventDurably(makeDb(s), 'acct', 'conversation.created', {
      conversation_id: 'c1',
      contact_id: 'ct1',
    });

    expect(s.insertedRows[0]).toMatchObject({ event: 'conversation.created', status: 'sending' });
    expect(sendOnce).toHaveBeenCalledTimes(1);
    expect(outboxUpdates(s).at(-1)?.patch).toMatchObject({ status: 'sent' });
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

  it('drains a full batch', async () => {
    const rows = Array.from({ length: 10 }, (_, i) => row({ id: `o${i}` }));
    const s = state({ claimRows: rows });
    vi.mocked(sendOnce).mockResolvedValue({ ok: true });

    const result = await flushWebhookOutbox(makeDb(s));

    expect(result).toMatchObject({ claimed: 10, sent: 10 });
    expect(sendOnce).toHaveBeenCalledTimes(10);
  });
});
