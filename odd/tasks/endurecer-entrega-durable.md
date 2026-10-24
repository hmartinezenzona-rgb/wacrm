# Harden durable delivery (outbox)

Status: live in production · Branch: feat/port-chat-operations-calculator · 2026-10-24

## Objective

Close the five risks found in the review of the durable `message.received` delivery (migration 301) before they surface in production as duplicate turns, dead endpoints hit forever, stale replies, silent outbox stalls or truncated worker batches.

## Problem

301 stores one row per endpoint before the first attempt, but:

1. the inline attempt sends without claiming the row, so the per-minute cron can claim and send the same row while the inline POST is in flight (duplicate turns when n8n is slow), and last-writer-wins can resurrect a successful row as `pending`;
2. `deliverOutboxRow` never touches `failure_count`, so an endpoint that keeps failing after the message delivery gives up is never auto-disabled (regression vs `deliverOne`);
3. backoff reaches 12 h, so a retry can reach the bot hours late (reply to a stale message, out of order with newer ones);
4. if `outbox_url` or `notify_secret` break, pings fail silently and rows die at attempt 10 with no alert;
5. 20 rows × 5 s send can exceed the route's `maxDuration` (60 s) and overlap the next ping.

## Scope

- `src/lib/webhooks/outbox.ts` and its tests.
- New migration 303: `cerebro_vigilar_outbox()` + cron every 5 minutes (admin alert via `cerebro_outbox_encolar`), rollback and staging assertion.
- No change to the webhook payload, the Cerebro contract or the endpoint model.

## Tasks

- [x] T1. Lease the rows at insert time (`status='sending'`, `locked_until=now+2 min`) so the cron cannot claim them during the inline attempt.
  - Evidence: insert payload carries `status: 'sending'` and `locked_until`; test "leases the rows before the inline attempt".
- [x] T2. Mirror `failure_count` semantics in the outbox: reset on success, `record_webhook_failure` on a final failure.
  - Evidence: tests "resets the endpoint failure streak on success" and "counts a final failure against the endpoint".
- [x] T3. Refuse stale events: a row older than 2 h (`occurred_at`, else `created_at`) is marked `failed` without sending.
  - Evidence: tests "does not deliver a stale event" and "delivers an event within the age limit".
- [x] T4. Migration 303 `cerebro_vigilar_outbox()`: alerts the admin (one per hour per conversation) about due rows not drained, expired leases and recent failures; cron every 5 minutes.
  - Evidence: staging dry-run/apply/assertion/rollback OK (`cerebro_vigilar_outbox` md5 `5bc28f149aa7`).
- [x] T5. Flush rows with a concurrency of 5 so a full batch fits `maxDuration`.
  - Evidence: `withConcurrency` in `flushWebhookOutbox`; test "drains a full batch" (10 rows).

## Checks

- `npx vitest run src/lib/webhooks/outbox.test.ts src/app/api/cron/webhook-outbox/route.test.ts` → 17 passed (2 files).
- `npx tsc --noEmit` → exit 0.
- Staging migration cycle for 303 → dry-run OK, apply OK, assertion OK, rollback OK.
- Production: 303 applied as `20261024175656` and verified (`prod=5bc28f14 stg=5bc28f14`); panel published as release `691d912`, BUILD_ID `U8zYcS9AgHw3hJbmT_ccB` (previous `0a185c7`); worker route answers 401 without the secret and both crons (`webhook-outbox`, `vigilar-outbox`) succeed.

## Verification evidence

- Production apply + panel publish done; a live test message is still pending to see the outbox row reach `sent` with the new build.
