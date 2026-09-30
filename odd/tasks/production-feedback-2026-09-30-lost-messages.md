# Lost customer messages between WaCRM and the n8n Cerebro (investigation)

## Objective
Find and fix at the root why some inbound customer messages never reach the bot (user asked for the
cause, not a patch).

## Evidence (2026-09-30)
- Staging USD test: the card message `9012 1234 4321 1234` (12:10:41 UTC) is in `messages` and
  `whatsapp_webhook_log` (procesado = true) but has no `session_events` row and no n8n execution.
  The bot only saw the phone, so it kept asking for the card; the beneficiary never completed, so the
  panel showed nothing (partial data sits in `cerebro_beneficiario_parcial`, which the panel does not
  read).
- Staging Supabase edge logs: `webhook_endpoints` lookup at 12:10:42.649, then
  `rpc/record_webhook_failure` at 12:10:47.723 — exactly the 5 s `DELIVERY_TIMEOUT_MS` in
  `src/lib/webhooks/deliver.ts`. The POST to n8n timed out; delivery is at-most-once with no retry.
- Production: 9 customer messages in 14 days without a `session_event` (rising: 3 on 09-28, 4 on
  09-29), including a burst with a phone, an image and "5000 a esta tarjeta". The production edge
  logs of the last 24 h show `record_webhook_failure` at 13:10:55, 20:20:55, 20:20:58 and 20:21:00 on
  09-29 — one per lost message, each ~5-7 s after it.
- n8n stalls every 10 minutes: the 30-second schedule of "Cerebro - Enviador del outbox"
  (`K4ijL3NzmY1VX7XI`) fires on time except at XX:X1:00, where it starts 5-15 s late (10:41:05,
  10:51:06, 11:01:05, 11:11:06, 11:21:07, 11:31:08, 11:41:09, 11:51:05, 12:01:15, 12:11:10). Other
  schedules due at X0:46-X1:00 fire late together. Every lost message falls inside such a window
  (12:10:42, 13:10:48, 20:20:49-54). No execution visible through the MCP runs during the stall.
- Active workflows whose executions the MCP cannot see (availableInMCP = false): Vigilante - envios
  sin beneficiario, Resumen de correos - Conector YCloud, Vigilante - depositos sin cruzar,
  Vigilante - envios incompletos, Limpieza Abandonos - Remesas Ya, Vigilante - mensajes de clientes
  perdidos, Vigilante - ingesta de depositos MMG. The 10-minute stall source is likely one of these
  or the host itself (n8n on Easypanel).

## Two root causes
1. Environment: something stalls the n8n process for 5-15 s every 10 minutes. Not identified yet.
2. Design: WaCRM hands each message to the bot exactly once, 5 s timeout, no retry, no
   reconciliation. Any stall of the receiver silently drops a customer message.

## Hidden workflows cleared (2026-09-30, after MCP access was enabled)
- The seven vigilantes/connector and "Limpieza Abandonos - Remesas Ya" (`RdYJq4FbSAP2XeFu`,
  folder production/ai_agent, legacy, every 6 h) are not the cause. The 10-minute ones finish in
  under a second at X0:01-X0:02 and X0:38. The 12:30 stall (12:30:50-12:31:12) had no execution
  at all, and two MCP calls to n8n returned 502 inside it (12:30:48, 12:31:11): n8n answers
  nobody during the stall.
- Remaining suspect: the host (another service or a 10-minute system task starving n8n). Read-only
  investigation instructions handed to Hermes (on the same VPS); waiting for the report.

## Root cause found (Hermes host report, 2026-09-30, verified)
- VPS: 1 vCPU, 1.9 GiB RAM (956 MiB in swap), n8n 2.39.8 on SQLite (~700 MB), no container limits,
  no n8n env tuning. No system cron, backup or kernel event every 10 minutes; no OOM.
- Live capture 12:50:38-12:50:57: n8n at 94-99% of the only vCPU, RAM +238 MB, `/healthz` up to
  7.9 s, swap up to 27 MB/s, disk up to 95 MB/s.
- Culprit: "Cerebro - Recolector de tokens" (production `iF0K3MpyXhjD58HJ` + staging
  `j1SrhNxDe2SZhVbE`), every 10 minutes. Verified in its definition: HTTP GET to the instance's OWN
  public API `/api/v1/executions?workflowId=jEzlVLCLUaJhVwzs&status=success&includeData=true&limit=25`
  with a 120 s timeout, then a Code node walking all that run data. It has
  `saveDataSuccessExecution: none`, which is why its runs never showed up in the MCP execution
  search. Hermes also saw runs stuck in `running` for over 13 minutes, overlapping the next ones.
- It was added by this project (observability work, `odd/tasks/cerebro-observability-quality.md`)
  on 2026-09-26 (staging) / 09-27 (production); lost messages in production rose right after
  (3 on 09-28, 4 on 09-29).
- Hermes also blames "Vigilante - ingesta de depositos MMG" (10-14 s per run). Not accepted as a
  cause: its own work is ~3 s of Gmail I/O (12:30 run took 2 s); the long runs are its trivial
  Postgres node inflated by the stall.

## Fix 1 applied — collector deactivated (2026-09-30 12:57 UTC, user go-ahead)
Both "Recolector de tokens" workflows unpublished (production `iF0K3MpyXhjD58HJ`, staging
`j1SrhNxDe2SZhVbE`); verified `active: false`. Reversible (publish again). Cost: token counts in
`cerebro_telemetria_turno` stop filling until the collector is redesigned (read one finished
execution at a time, never 25 full executions through the public API).

Verified on the first window after deactivation (13:00:25-13:01:40 UTC): every schedule fired on
its own second (outbox 13:01:00.052, vigilante :46.031, :52.019, the X0:58-X0:59 group on time),
the MMG ingest vigilante took 1.4 s. No stall. Before: 5-25 s late every 10 minutes.

## Fix 2 — delivery retries (2026-09-30, user go-ahead)
- [x] T2.1 `src/lib/webhooks/deliver.ts`: up to 3 attempts (5 s timeout each, 3 s then 8 s apart,
  worst case 26 s inside the webhook's `after()`). Retries network errors, timeouts, 5xx and 429;
  any other response is final. Same payload (same `id`), fresh signature timestamp per attempt,
  since the Cerebro rejects a replayed signature (`Replay?` node). One `record_webhook_failure` per
  event only when all attempts failed. `docs/public-api.md` updated.
  Retrying is safe for the Cerebro: `Guardar evento` dedupes by (conversation, wamid) and
  `Evento nuevo?` stops a duplicate.
  TDD (vitest, `npx vitest run src/lib/webhooks/`): RED 4 failing (single attempt), GREEN 29/29;
  `tsc --noEmit` and eslint clean.
- [ ] T2.2 Deploy to the staging app and re-run the USD test; then production with go-ahead.
- Known limit: still in-process; a crash mid-retry loses the event (durable queue = follow-up).

## Next step
Fix 2 — WaCRM delivery must not drop a message on one timeout (retry with backoff and/or
reconciliation). Fix 3 — host sizing (user decision). Redesign the token collector.
