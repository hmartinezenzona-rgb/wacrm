# Durable conversation.created and message.status_updated

Status: live in production · Branch: feat/port-chat-operations-calculator · 2026-10-24

## Objective

Make all three webhook events durable. `conversation.created` and `message.status_updated` join `message.received` in the outbox, so no event is dropped after three in-process attempts.

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
- [x] T4. Route `message.status_updated` through the outbox; restrict the wamid dedupe to `message.received` (a status update must not be skipped by an unrelated `session_events` row).
  - Evidence: test "sends a status update even when the wamid has a session_event"; webhook route uses `dispatchEventDurably` for the three events.
- [x] T5. Migration 304: the claim orders `message.received` before status updates, so a burst cannot delay the bot; status rows still drain afterwards.
  - Evidence: staging dry-run/apply/assertion/rollback OK; `cerebro_webhook_outbox_reclamar` md5 `b97887fa2e6e`; production previa SEGURO.

## Checks

- `npx vitest run src/lib/webhooks/outbox.test.ts src/app/api/whatsapp/webhook/route.test.ts` → 20 passed.
- `npx tsc --noEmit` → exit 0.
- Staging migration cycle for 304 → dry-run OK, apply OK, assertion OK, rollback OK.
- Production: `previa` SEGURO; apply and panel publish pending the owner's go-ahead.

## Verification evidence

- 304 applied as `20261024181047` and verified (`prod=b97887fa stg=b97887fa`); panel published as release `8bec2b1`, BUILD_ID `1dlIy5fMy3D3pGng26RTc` (previous `bd7dfff`); worker route answers 401 without the secret.
- Live rows for `conversation.created` and `message.status_updated` appear with real traffic; the outbox was empty after the publish because no message arrived in the first minutes.
