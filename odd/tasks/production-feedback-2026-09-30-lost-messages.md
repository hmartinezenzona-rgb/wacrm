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

## Next step
Identify the 10-minute stall (needs visibility into the hidden workflows or the n8n host), then fix
both causes. Nothing changed yet.
