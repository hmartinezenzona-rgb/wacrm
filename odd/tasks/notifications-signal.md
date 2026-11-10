# Feature: panel notifications that admins actually use (first batch)

## Objective
Cut the panel notification noise by more than half without losing any alert about a chat with money in play:
an "not business" action that silences a chat, one "unanswered chat" alert per customer message, and a daily digest
for technical notifications.

## Problem / why (audit 2026-11-10, production, last 30 days)
- 574 rows (~247 events, one row per profile, 3 profiles); 74% of all rows ever are unread; reads are bulk
  "mark all read". Every INSERT plays the same sound (src/hooks/use-notification-alerts.ts).
- `chat_atascado` (cerebro_avisar_chats_atascados, migration 323): 226 rows for 58 (user, conversation) pairs. It
  ignores status, tags, whether the team saw the chat, and business content; bot-owned assignments (377b0c8c) never
  expire, so chats like 82328ae9 (no operation, last customer message a month old) alert forever (49 rows). A read row
  is re-inserted (new sound) every 6 h. 59% of its rows are on conversations that never had an operation.
- `mensaje_fallido` 130 rows (2% read), `mensaje_perdido` 59 (3%), `remesa_abierta_vieja` 37 (8%), `promo_etecsa` 17
  (0%): 243 rows, 42% of all.
- No mechanism exists to mark a chat as not business, ignored or muted.

## Owner decisions
- 2026-11-10: start with three items: "No es del negocio" action, one unanswered-chat alert per customer message,
  daily digest of technical notifications. The rest (business-intent escalation, one live row per operation for
  envio_sin_beneficiario, sound by severity, auto-clear) is a second batch.

## Claude defaults (stated to the owner)
- "No es del negocio": a button in the chat; stores who and when on the conversation; the chat stops producing
  chat_atascado alerts; it is cleared automatically when the customer writes again (a new message reactivates
  alerts); reversible by a button. Visible state in the chat. Money alerts (deal_incidencia, envio_sin_beneficiario)
  are never silenced by it.
- Unanswered chat: at most one alert per customer message (keyed by the last customer message id), no re-alert after
  it was read; no alert when the last customer message is older than 7 days.
- Digest: mensaje_fallido, mensaje_perdido, remesa_abierta_vieja, promo_etecsa stop creating one row per run; one
  digest row per profile per day (Guyana morning, business days) with counts and the most relevant lines; a type with
  nothing to report is omitted; nothing is emitted when all are zero.

## Scope
In: SQL migrations 364+ (ROLLBACK + staging assertions), the panel button and state (component + API route +
tests), the notifications page label/icon for the digest, n8n/cron schedule for the digest; staging; production with
go-ahead (migrations, panel publish, n8n/cron each).
Out: second-batch items; Cerebro Decisor; notifier WhatsApp alerts to the admin phone.

## Constraints
- Staging first; production only with explicit go-ahead. Read LIVE bodies first. Strict TDD (SQL assertions in
  rolled-back transactions; vitest for panel code). Never execute n8n workflows. Never touch the other session's
  files. No AI attribution in commits. RDD off. Next.js in this repo has breaking changes: read
  node_modules/next/dist/docs/ before writing panel code.

## Tasks
- [x] T1 Migration 364: "not business" state on conversations (who/when), auto-clear on new customer message, RPC to
      set/clear (RLS/role checks like neighbours); chat_atascado skips ignored chats; one alert per customer message;
      7-day cutoff; ROLLBACK; assertions (TV Muares shape, sanchesirina shape still alerts once, read row not
      re-created, new customer message re-arms, ignored chat silent, customer writes -> un-ignored)
- [ ] T2 Panel: "No es del negocio" / "Reactivar" button and visible state in the chat; API route; tests
- [ ] T3 Migration 365: daily digest for the four technical types (stop per-run rows, one digest per profile per day),
      schedule (reuse the existing mechanism: pg_cron or the n8n watcher), notifications page label/icon; assertions
- [ ] T4 Staging: apply, related assertions, panel on staging for the owner to try
- [ ] T5 Production (needs go-ahead): migrations, panel publish, schedule

## Acceptance criteria
- A chat marked "No es del negocio" produces no unanswered-chat alert until the customer writes again.
- One customer message left unanswered -> one alert (one per profile), never re-created after it was read.
- Technical notifications arrive as one daily summary per profile, not one row per run.
- deal_incidencia and envio_sin_beneficiario behave exactly as today.

## Progress / evidence
- 2026-11-10: audit done (read-only; counts above).
- T1 commit d0b761d. Live bodies (staging = production md5) of cerebro_avisar_chats_atascados/mensajes_fallidos/mensajes_perdidos/remesas_abiertas_viejas confirmed equal before redefining. RED: assertion without 364 -> "FAIL [1 crm_marcar_no_negocio exists]". GREEN: 364 + assertion dry run -> 27 ok lines, ALL PASS (rolled back on purpose). Design notes: detection loop moved unchanged into _cerebro_atascados_detectar (testable outside business hours); chat_atascado_max_dias default 7; p_repetir_min and *_repetir_* keys no longer used; backfill marks current backlog as already alerted; the n8n watcher only does SELECT * so function results are not consumed.

## Next step
T1.
