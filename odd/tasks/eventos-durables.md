# Durable conversation.created

Status: live in production · Branch: feat/port-chat-operations-calculator · 2026-10-24

## Objective

Make `conversation.created` use the durable outbox, so a new thread is never lost when the in-process delivery to the Cerebro fails. `message.status_updated` stays in-process for now.

## Problem

The webhook emits `conversation.created` through `dispatchWebhookEvent`, which gives up after three attempts and drops the event. The outbox added for `message.received` (301) already stores one row per endpoint, leases the row, retries with backoff, refuses stale rows and alerts when it stalls; the event type is the only thing tying it to messages.

## Scope

- Generalize `dispatchMessageReceivedDurably` to `dispatchEventDurably(db, accountId, event, data)`.
- Use it for `conversation.created` and keep `message.received` on the same path.
- No schema change: `webhook_outbox.event` already stores the event name.
- Dedupe: `message.received` keeps the `session_events` check by wamid; `conversation.created` has no equivalent marker, so a retry may repeat it (same exposure as the current in-process retry). The CRM emits it once per new thread.

## Tasks

- [x] T1. Generalize the dispatch function and its tests; add a `conversation.created` case.
  - Evidence: `dispatchEventDurably`; test "stores and sends a conversation.created event".
- [x] T2. Route `conversation.created` through the outbox in the webhook handler; update the route test mock.
  - Evidence: webhook route calls `dispatchEventDurably` for both events.
- [x] T3. Verify: vitest + tsc, then publish the panel.
  - Evidence: 19 tests passed (outbox + webhook route); `tsc --noEmit` exit 0.

## Checks

- `npx vitest run src/lib/webhooks/outbox.test.ts src/app/api/whatsapp/webhook/route.test.ts` → 19 passed.
- `npx tsc --noEmit` → exit 0.

## Verification evidence

- Panel published as release `bd7dfff`, BUILD_ID `7naGgFp1bypU354hlSEVe` (previous `691d912`). No migration.
- `conversation.created` only fires for a new contact, so the end-to-end proof arrives with the next new thread; unit coverage is the outbox and route suites.
