// ============================================================
// Outbound webhook delivery.
//
// `dispatchWebhookEvent` finds the account's active endpoints
// subscribed to an event, signs one JSON payload, and POSTs it to
// each in parallel. It is best-effort and never throws — callers fire
// it from the inbound webhook's `after()` block, where a failed
// delivery must not affect the 200 OK returned to Meta.
//
// Delivery semantics (documented in docs/public-api.md):
//   - Up to DELIVERY_ATTEMPTS attempts per event, each with a short
//     timeout, spaced by RETRY_DELAYS_MS. Only transient failures are
//     retried (network error/timeout, 5xx, 429); any other response is
//     final. Every attempt resends the SAME payload (same `id`, so
//     receivers dedupe) with a FRESH signature timestamp (receivers that
//     keep signature nonces reject a replayed one).
//     Why: with a single attempt, a receiver that stalled for a few
//     seconds lost the event for good — the Cerebro's n8n stalled every
//     10 minutes on 2026-09-28/30 and customer messages never reached the
//     bot. The worst case (3 x 5 s + 3 s + 8 s = 26 s) fits the route's
//     `maxDuration`.
//   - An event whose attempts all failed bumps `failure_count` once;
//     once it crosses MAX_CONSECUTIVE_FAILURES the endpoint is
//     auto-disabled (`is_active = false`) so a dead sink stops being hit.
//     A success resets the counter and stamps `last_delivery_at`.
//   - Still in-process: a crash mid-retry loses the event. Durable
//     delivery would need a queue/worker (a follow-up).
// ============================================================

import { createHmac, randomUUID } from 'node:crypto';

import type { SupabaseClient } from '@supabase/supabase-js';

import { decrypt } from '@/lib/whatsapp/encryption';
import { buildSignatureHeader } from '@/lib/webhooks/sign';
import { isDeliverableUrl } from '@/lib/webhooks/ssrf';
import type { WebhookEvent } from '@/lib/webhooks/events';

/** Per-endpoint HTTP timeout. Kept short — this runs in `after()`. */
export const DELIVERY_TIMEOUT_MS = 5000;

/** Attempts per event and endpoint (the first one included). */
export const DELIVERY_ATTEMPTS = 3;

/** Wait before attempt 2, 3, ... */
export const RETRY_DELAYS_MS = [3000, 8000];

/** Auto-disable an endpoint after this many consecutive failures. */
export const MAX_CONSECUTIVE_FAILURES = 15;

export interface EndpointRow {
  id: string;
  url: string;
  secret: string;
}

/**
 * Deliver `event` (+ `data`) to every active endpoint of `accountId`
 * subscribed to it. Never throws.
 */
export async function dispatchWebhookEvent(
  db: SupabaseClient,
  accountId: string,
  event: WebhookEvent,
  data: unknown
): Promise<void> {
  try {
    const { data: rows, error } = await db
      .from('webhook_endpoints')
      .select('id, url, secret')
      .eq('account_id', accountId)
      .eq('is_active', true)
      .contains('events', [event]);

    if (error || !rows || rows.length === 0) return;

    // Sign the exact bytes we send so a receiver can recompute the
    // HMAC over the raw request body. `id` is a per-event uuid the
    // receiver can dedupe on (a retry resends it, and deliveries may
    // repeat / arrive out of order).
    const payload = JSON.stringify({
      id: randomUUID(),
      event,
      occurred_at: new Date().toISOString(),
      account_id: accountId,
      data,
    });

    await Promise.allSettled(
      (rows as EndpointRow[]).map((row) => deliverOne(db, row, event, payload))
    );
  } catch (err) {
    // Never let a delivery problem bubble into the webhook response.
    console.error('[webhooks] dispatch failed:', err);
  }
}

async function deliverOne(
  db: SupabaseClient,
  row: EndpointRow,
  event: WebhookEvent,
  payload: string
): Promise<void> {
  // SSRF guard: refuse to POST to a host that resolves to a private /
  // loopback / link-local address. Counts as a failure so a
  // misconfigured internal URL surfaces and eventually auto-disables.
  if (!(await isDeliverableUrl(row.url))) {
    console.warn('[webhooks] refusing non-public delivery target for', row.id);
    await recordFailure(db, row);
    return;
  }

  let secret: string;
  try {
    secret = decrypt(row.secret);
  } catch (err) {
    // A row whose secret can't be decrypted can never produce a valid
    // signature — count it as a failure so it eventually auto-disables.
    console.error('[webhooks] secret decrypt failed for', row.id, err);
    await recordFailure(db, row);
    return;
  }

  let lastError = '';
  for (let attempt = 1; attempt <= DELIVERY_ATTEMPTS; attempt++) {
    if (attempt > 1) await sleep(RETRY_DELAYS_MS[attempt - 2] ?? 0);
    const outcome = await sendOnce(row, event, payload, secret);
    if (outcome.ok) {
      // Success: clear the failure streak.
      await db
        .from('webhook_endpoints')
        .update({ failure_count: 0, last_delivery_at: new Date().toISOString() })
        .eq('id', row.id);
      return;
    }
    lastError = outcome.error;
    console.warn(
      `[webhooks] delivery to ${row.id} failed (attempt ${attempt}/${DELIVERY_ATTEMPTS}):`,
      lastError
    );
    if (!outcome.retryable) break;
  }
  console.warn(`[webhooks] giving up on delivery to ${row.id}:`, lastError);
  await recordFailure(db, row);
}

export type SendOutcome = { ok: true } | { ok: false; retryable: boolean; error: string };

/** One signed POST. Signed at send time, so every attempt has its own timestamp. */
export async function sendOnce(
  row: EndpointRow,
  event: WebhookEvent,
  payload: string,
  secret: string
): Promise<SendOutcome> {
  const tsSeconds = Math.floor(Date.now() / 1000);
  try {
    // Firma del Cerebro (n8n) — migración a HMAC en cabeceras. Durante la
    // transición el Cerebro acepta ambas formas, así que se mantiene el
    // ?secret= de la URL y se añaden las cabeceras X-Cerebro-*.
    // El secreto compartido es el mismo que ya viaja en el query string
    // (el que n8n valida hoy); CEREBRO_WEBHOOK_SECRET (env var) tiene
    // prioridad si está definida.
    let cerebroSignature: string | undefined;
    if (row.url.includes('wacrm-cerebro')) {
      const querySecret = new URL(row.url).searchParams.get('secret');
      const cerebroSecret =
        process.env.CEREBRO_WEBHOOK_SECRET ?? querySecret ?? secret;
      cerebroSignature = createHmac('sha256', cerebroSecret)
        .update(`${tsSeconds}.${payload}`)
        .digest('hex');
    }

    const res = await fetch(row.url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'X-Wacrm-Event': event,
        'X-Wacrm-Webhook-Id': row.id,
        'X-Wacrm-Signature': buildSignatureHeader(payload, secret, tsSeconds),
        ...(cerebroSignature
          ? {
              'X-Cerebro-Timestamp': String(tsSeconds),
              'X-Cerebro-Signature': `sha256=${cerebroSignature}`,
            }
          : {}),
      },
      body: payload,
      // Do NOT follow redirects — a public URL could 3xx-bounce to an
      // internal address, bypassing the SSRF check above. A 3xx is a
      // misconfiguration; treat it as a final failure.
      redirect: 'manual',
      signal: AbortSignal.timeout(DELIVERY_TIMEOUT_MS),
    });
    if (res.ok) return { ok: true };
    return {
      ok: false,
      retryable: res.status >= 500 || res.status === 429,
      error: `endpoint responded ${res.status}`,
    };
  } catch (err) {
    // Network error or timeout: the receiver may just be busy.
    return { ok: false, retryable: true, error: err instanceof Error ? err.message : String(err) };
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function recordFailure(db: SupabaseClient, row: EndpointRow): Promise<void> {
  // Atomic increment (+ auto-disable at the threshold) via a SQL
  // function — a read-modify-write here would lose increments when two
  // deliveries to the same endpoint run concurrently (e.g.
  // conversation.created + message.received for one inbound message),
  // so a dead endpoint might never reach the disable threshold.
  const { error } = await db.rpc('record_webhook_failure', {
    endpoint_id: row.id,
    max_failures: MAX_CONSECUTIVE_FAILURES,
  });
  if (error) {
    console.error('[webhooks] record_webhook_failure failed for', row.id, error);
  }
}
