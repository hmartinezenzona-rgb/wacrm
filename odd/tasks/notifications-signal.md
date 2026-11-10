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
- [x] T2 Panel: "No es del negocio" / "Reactivar" button and visible state in the chat; API route; tests
- [x] T3 Migration 365: daily digest for the four technical types (stop per-run rows, one digest per profile per day),
      schedule (reuse the existing mechanism: pg_cron or the n8n watcher), notifications page label/icon; assertions
- [x] T4 Staging: apply, related assertions, panel on staging for the owner to try (browser click-through NOT done: no browser tool in that session; DB-level equivalent done)
- [ ] T5 Production (needs go-ahead): migrations, panel publish, schedule

## Acceptance criteria
- A chat marked "No es del negocio" produces no unanswered-chat alert until the customer writes again.
- One customer message left unanswered -> one alert (one per profile), never re-created after it was read.
- Technical notifications arrive as one daily summary per profile, not one row per run.
- deal_incidencia and envio_sin_beneficiario behave exactly as today.

## Progress / evidence
- 2026-11-10: audit done (read-only; counts above).
- T1 commit d0b761d. Live bodies (staging = production md5) of cerebro_avisar_chats_atascados/mensajes_fallidos/mensajes_perdidos/remesas_abiertas_viejas confirmed equal before redefining. RED: assertion without 364 -> "FAIL [1 crm_marcar_no_negocio exists]". GREEN: 364 + assertion dry run -> 27 ok lines, ALL PASS (rolled back on purpose). Design notes: detection loop moved unchanged into _cerebro_atascados_detectar (testable outside business hours); chat_atascado_max_dias default 7; p_repetir_min and *_repetir_* keys no longer used; backfill marks current backlog as already alerted; the n8n watcher only does SELECT * so function results are not consumed.
- T2 commit b69f1a9. RED: not-business-control.test.tsx failed to load (module missing). GREEN: 5 tests pass; tsc clean; eslint clean on touched files (3 pre-existing errors elsewhere: notifications/page.tsx:83, use-ausencia.test.tsx, use-media-src.ts); related suites (inbox, i18n, dashboard pages, lib/inbox) 779 pass, 27 timeouts in conversation-list/notifications page tests under parallel load, those files pass 29/29 alone. Design: direct supabase.rpc from the client like the status/assignment controls (no API route); header button + banner with Reactivar.
- T3 commit 1cea6f1. RED: digest assertion without 365 -> "FAIL [1 cerebro_resumen_diario exists]"; page test "shows the daily summary with its badge" failed. GREEN: 365 + assertion -> 25 ok lines, ALL PASS (rolled back on purpose); page tests 10/10, tsc clean, eslint on page.tsx only the pre-existing setState-in-effect error. Mechanism: BEFORE INSERT trigger diverts the four types into notification_digest_items (emitters untouched; their ROW_COUNT now 0, n8n only SELECTs it); cerebro_resumen_diario() via pg_cron 'resumen-diario-notificaciones' at 12:30 UTC Mon-Sat (08:30 Guyana). Deviation to confirm with owner: the actionable "Nueva promocion de Etecsa detectada" notice is exempt (still immediate); the failed-read notice is digested.

- T4 (2026-11-10). Staging already had 364 and 365 applied (all objects present: not_business_* columns, crm_marcar_no_negocio, _cerebro_atascados_detectar, cerebro_resumen_diario, notification_digest_items, trigger zzz_notifications_to_digest, pg_cron 'resumen-diario-notificaciones' 30 12 * * 1-6 active); staging records no schema_migrations rows, so `aplicar` was not repeated. `relacionadas --ya-aplicada`: 364 TOTAL 46 SAME 44 DIFF 2 (notifications-not-business = expected, base lacks 364; delivery-feed-evidence = same fixture failure on both sides, only the uuid differs). 365 first run TOTAL 46 SAME 40 DIFF 6: expected notifications-digest, delivery-feed-evidence (same as above) and 4 real regressions of the digest trigger: promo-read-failure, outbox-partes, stale-operations-alert, deals-free-views-and-inert-edits [4]. They assert the emitters' own notifications rows, which 365 now diverts. Fix: those four assertions switch the diversion trigger off inside their rolled-back transaction (guards untouched). Rerun: TOTAL 4 SAME 4 DIFF 0; outbox-partes and promo-read-failure ALL PASS. Pre-existing on base (unchanged): deals-free-views 3 failed expectations, stale-operations-alert case 1 text, guard12-matrix, promo-read-failure was clean. avisos-atascados.sql now also inspects _cerebro_atascados_detectar (364 moved the loop): SAME/ALL PASS.
- T4 DB check with a PRUEBA fixture (5990253 0901, cleaned up): as an owner/admin profile, crm_marcar_no_negocio(true) -> no_negocio true with who/when; (false) -> cleared; marked again, inserting a customer message cleared it (trigger); a mensaje_fallido insert went to notification_digest_items (0 notifications rows), cerebro_resumen_diario() returned 1 and created type resumen_diario "Resumen tecnico del dia: 1 aviso" (rolled back). Panel components and notifications page vitest: 41 files / 660 tests pass. Cleanup: limpieza.sql dry run then real; fixture conversation 0 rows, no PRUEBA digest or notification rows (one older PRUEBA contact from 2026-10-14 is not from this run).

## Next step
T5 production needs the owner's go-ahead: migrations 364 then 365 (previa/aplicar/verificar), panel publish, confirm the pg_cron digest job. Owner to confirm: the Etecsa new-promotion notice stays immediate; and try the button/banner/digest page in the staging panel.
