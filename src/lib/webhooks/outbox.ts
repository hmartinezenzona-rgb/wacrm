// ============================================================
// Durable delivery for message.received and conversation.created.
//
// The inbound webhook used to POST to n8n in-process: when the attempts
// failed (timeout / 502 / 404 while a workflow was inactive) the event was
// lost. This outbox stores one row per endpoint BEFORE the first attempt,
// tries once inline, and leaves a failed row pending for the cron worker
// (/api/cron/webhook-outbox, every minute).
//
// A retry of message.received checks that the wamid has no session_events row
// first: if the Cerebro already processed the message, the row is marked
// skipped, so a lost response cannot make the bot answer the same message
// twice. conversation.created has no equivalent marker in the CRM, so its
// retries rely on the receiver; the CRM emits it once per new thread.
// ============================================================

import { randomUUID } from 'node:crypto';

import type { SupabaseClient } from '@supabase/supabase-js';

import { decrypt } from '@/lib/whatsapp/encryption';
import { isDeliverableUrl } from '@/lib/webhooks/ssrf';
import {
  dispatchWebhookEvent,
  MAX_CONSECUTIVE_FAILURES,
  sendOnce,
  type EndpointRow,
} from '@/lib/webhooks/deliver';
import type { WebhookEvent } from '@/lib/webhooks/events';

/** Attempts per outbox row, the inline one included. */
export const OUTBOX_MAX_ATTEMPTS = 10;

/** Lease taken while a row is being sent; matches the SQL claim lease. */
export const OUTBOX_LEASE_SECONDS = 2 * 60;

/** A row older than this is not delivered: the bot would answer a stale message. */
export const OUTBOX_MAX_AGE_SECONDS = 2 * 60 * 60;

/** Rows sent at once by the worker, so a full batch fits the route's maxDuration. */
export const OUTBOX_CONCURRENCY = 5;

/** Seconds before the next attempt, by attempt number (1 = after the first failure). */
const BACKOFF_SECONDS = [60, 120, 300, 600, 1800, 3600, 7200, 14400, 28800, 43200];

export function outboxBackoffSeconds(attempts: number): number {
  return BACKOFF_SECONDS[Math.min(Math.max(attempts - 1, 0), BACKOFF_SECONDS.length - 1)]!;
}

export interface OutboxRow {
  id: string;
  account_id: string;
  endpoint_id: string;
  event: string;
  payload: {
    id?: string;
    event?: string;
    occurred_at?: string;
    account_id?: string;
    data?: { whatsapp_message_id?: string; [key: string]: unknown };
    [key: string]: unknown;
  };
  status: string;
  attempts: number;
  created_at?: string;
}

function isoIn(seconds: number): string {
  return new Date(Date.now() + seconds * 1000).toISOString();
}

async function mark(db: SupabaseClient, id: string, patch: Record<string, unknown>): Promise<void> {
  const { error } = await db.from('webhook_outbox').update(patch).eq('id', id);
  if (error) console.error('[webhook outbox] update failed for', id, error);
}

/** The wamid was already processed by the Cerebro: a retry would duplicate the turn. */
async function alreadyProcessed(db: SupabaseClient, row: OutboxRow): Promise<boolean> {
  const wamid = row.payload?.data?.whatsapp_message_id;
  if (!wamid) return false;
  const { data, error } = await db
    .from('session_events')
    .select('id')
    .eq('whatsapp_message_id', wamid)
    .limit(1)
    .maybeSingle();
  if (error) {
    // Fail open: a read error must not silently drop the delivery; the send may duplicate, which the
    // Cerebro's own processing is the only place able to prevent. Log and continue.
    console.warn('[webhook outbox] session_events check failed for', wamid, error);
    return false;
  }
  return Boolean(data);
}

/** Seconds since the event happened (payload `occurred_at`, else the row's created_at). */
function eventAgeSeconds(row: OutboxRow): number {
  const stamp = row.payload?.occurred_at ?? row.created_at;
  if (!stamp) return 0;
  const ms = Date.parse(stamp);
  return Number.isNaN(ms) ? 0 : Math.max(0, (Date.now() - ms) / 1000);
}

/** One attempt for a claimed row. Updates the row and returns its new state. */
export async function deliverOutboxRow(
  db: SupabaseClient,
  row: OutboxRow,
): Promise<'sent' | 'skipped' | 'pending' | 'failed'> {
  if (await alreadyProcessed(db, row)) {
    await mark(db, row.id, { status: 'skipped', sent_at: new Date().toISOString(), locked_until: null });
    return 'skipped';
  }

  // A late replay would reach the bot after the customer moved on (or after a newer message), so the
  // row gives up instead of sending. The ingestion watchdog alerts on the missing answer.
  const age = eventAgeSeconds(row);
  if (age > OUTBOX_MAX_AGE_SECONDS) {
    await mark(db, row.id, {
      status: 'failed',
      last_error: `stale event (${Math.round(age / 60)} min old, limit ${OUTBOX_MAX_AGE_SECONDS / 60} min)`,
      locked_until: null,
    });
    return 'failed';
  }

  const { data: endpoint, error } = await db
    .from('webhook_endpoints')
    .select('id, url, secret')
    .eq('id', row.endpoint_id)
    .maybeSingle();
  const ep = endpoint as EndpointRow | null;

  const fail = async (errorText: string, retryable: boolean): Promise<'pending' | 'failed'> => {
    const attempts = row.attempts + 1;
    if (!retryable || attempts >= OUTBOX_MAX_ATTEMPTS) {
      await mark(db, row.id, {
        status: 'failed', attempts, last_error: errorText, locked_until: null,
      });
      // Same endpoint health accounting as the in-process path: enough consecutive give-ups
      // auto-disable the endpoint instead of hammering a dead sink.
      const { error: failureError } = await db.rpc('record_webhook_failure', {
        endpoint_id: row.endpoint_id,
        max_failures: MAX_CONSECUTIVE_FAILURES,
      });
      if (failureError) {
        console.error('[webhook outbox] record_webhook_failure failed for', row.endpoint_id, failureError);
      }
      return 'failed';
    }
    await mark(db, row.id, {
      status: 'pending', attempts, last_error: errorText, locked_until: null,
      next_attempt_at: isoIn(outboxBackoffSeconds(attempts)),
    });
    return 'pending';
  };

  if (error || !ep) return fail('endpoint not found', false);
  if (!(await isDeliverableUrl(ep.url))) return fail('non-public delivery target', false);

  let secret: string;
  try {
    secret = decrypt(ep.secret);
  } catch {
    return fail('secret decrypt failed', false);
  }

  const outcome = await sendOnce(ep, row.event as WebhookEvent, JSON.stringify(row.payload), secret);
  if (outcome.ok) {
    // Success clears the endpoint's failure streak, as the in-process path does.
    const { error: resetError } = await db
      .from('webhook_endpoints')
      .update({ failure_count: 0, last_delivery_at: new Date().toISOString() })
      .eq('id', row.endpoint_id);
    if (resetError) console.warn('[webhook outbox] failure_count reset failed for', row.endpoint_id, resetError);
    await mark(db, row.id, {
      status: 'sent', attempts: row.attempts + 1, sent_at: new Date().toISOString(), locked_until: null,
    });
    return 'sent';
  }
  return fail(outcome.error, outcome.retryable);
}

/**
 * Store one row per endpoint for a durable event and try once inline.
 * Falls back to the old in-process delivery if the outbox insert fails.
 */
export async function dispatchEventDurably(
  db: SupabaseClient,
  accountId: string,
  event: WebhookEvent,
  data: Record<string, unknown>,
): Promise<void> {
  try {
    const { data: endpoints, error } = await db
      .from('webhook_endpoints')
      .select('id, url, secret')
      .eq('account_id', accountId)
      .eq('is_active', true)
      .contains('events', [event]);
    if (error) throw error;
    const rows = (endpoints ?? []) as EndpointRow[];
    if (rows.length === 0) return;

    const payload = {
      id: randomUUID(),
      event,
      occurred_at: new Date().toISOString(),
      account_id: accountId,
      data,
    };
    const { data: stored, error: insertError } = await db
      .from('webhook_outbox')
      .insert(rows.map((row) => ({
        account_id: accountId,
        endpoint_id: row.id,
        event,
        payload,
        // Lease the row before the inline attempt so the cron worker cannot claim the same
        // row and send it concurrently. If this process dies mid-send, the lease expires and
        // the worker reclaims the row after OUTBOX_LEASE_SECONDS.
        status: 'sending',
        locked_until: isoIn(OUTBOX_LEASE_SECONDS),
      })))
      .select('*');
    if (insertError) throw insertError;

    await Promise.allSettled(((stored ?? []) as OutboxRow[]).map((row) => deliverOutboxRow(db, row)));
  } catch (err) {
    console.error('[webhook outbox] enqueue failed; falling back to inline delivery:', err);
    await dispatchWebhookEvent(db, accountId, event, data);
  }
}

export interface FlushResult {
  claimed: number;
  sent: number;
  skipped: number;
  pending: number;
  failed: number;
}

/** Run `fn` over the items with a bounded number in flight. */
async function withConcurrency<T, R>(
  items: T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await fn(items[index]!);
    }
  });
  await Promise.all(workers);
  return results;
}

/** Called by the cron worker: purge old rows, claim due ones and attempt each. */
export async function flushWebhookOutbox(db: SupabaseClient, limit = 20): Promise<FlushResult> {
  await db
    .from('webhook_outbox')
    .delete()
    .in('status', ['sent', 'skipped'])
    .lt('sent_at', isoIn(-7 * 24 * 3600));

  const { data, error } = await db.rpc('cerebro_webhook_outbox_reclamar', { p_limit: limit });
  if (error) throw new Error(`outbox claim failed: ${error.message}`);

  const result: FlushResult = { claimed: 0, sent: 0, skipped: 0, pending: 0, failed: 0 };
  const rows = (data ?? []) as OutboxRow[];
  result.claimed = rows.length;
  const states = await withConcurrency(rows, OUTBOX_CONCURRENCY, (row) => deliverOutboxRow(db, row));
  for (const state of states) result[state] += 1;
  return result;
}
