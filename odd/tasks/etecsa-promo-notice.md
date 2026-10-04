# Feature: the ETECSA promo notice reaches the admins in time and stays visible

## Objective
When etecsa.cu announces a recharge promo, even before it starts, the business admins get a notice in the CRM that
they cannot miss. They confirm the promo there, and the bot then quotes it, or announces it as upcoming.

## Problem (investigated 2026-10-04, read-only)
- The monitor (n8n vk6aEa4bOZtl5xSz, prod only) runs every 12 h. It works: the last run, at 2026-10-04 16:00 UTC,
  succeeded, and etecsa.cu has no recharge promo today.
- The only promo since August, x5 for 21–26 Sep, was detected on the 26th, its last day (the old link filter, fixed
  that day). Osmany read the notice and nobody confirmed the promo; the confirm strip lives only on the Notifications
  page, among about 4,900 other notifications.
- cerebro_promo_registrar hard-codes production's account and three user ids. On staging it can never notify anyone,
  and a new admin in production would never get the notice.
- A promo that has already ended is still registered and notified (the 27–31 Jul promo was notified on 2026-08-20).

## Scope (owner, 2026-10-04: "hazla en staging y aplica las 3 mejoras")
1. Faster check: every 3 h instead of 12 h.
2. No notice for a promo that has already ended.
3. A pinned notice in the CRM, on every page, while a promo is pending, with Confirm and Discard.
Plus the bug that blocks the test: the recipients are the owner and admins of the business account (the account of
whatsapp_config), not hard-coded ids.
Staging first. Production needs the owner's go-ahead.

## TDD
Strict TDD is on (global CLAUDE.md). Runners: SQL assertions (self-reverting DO block that ends in RAISE EXCEPTION
'ALL PASS') for the DB, and vitest (`npm test`) for the app.

## Tasks
- [x] T1 DB `206_promo_notice.sql` (+ ROLLBACK): cerebro_promo_registrar notifies the owner and admins of the
      whatsapp_config account; it skips a promo whose `hasta` is before today (Guyana time) and registers nothing.
      Assertion `supabase/staging/assertions/promo-notice.sql`: RED on staging before, then GREEN.
- [x] T2 CRM: a pinned promo banner in the dashboard shell while a promo is pending, with Confirm and Discard (reusing
      /api/promotions/etecsa). Vitest RED → GREEN; deploy to the staging app.
- [ ] T3 n8n: a "[STAGING] Vigilante - promociones de Etecsa" copy on the staging DB credential, every 3 h. The same
      3 h change for prod is prepared and waits for the go-ahead.
- [ ] T4 Staging end to end: inject a fake upcoming promo through cerebro_promo_revision; the owner sees the
      banner, confirms it, and the bot announces it when the test number asks about recharges.
- [ ] T5 Production, after the owner's go-ahead: 206, the app, and the 3 h cadence.

## Progress
- 2026-10-04: investigation done (Engram cerebro/etecsa-monitor-2026-10-04).
- T1 (commit 179d0a9): the assertion was RED on staging before 206 ("case 1: got fallo: ... violates foreign key
  constraint notifications_account_id_fkey", the hard-coded prod account). 206 was applied to staging in one
  transaction (schema_migrations 206 / 206_promo_notice) and the assertion is ALL PASS. The rollback restores the
  previous body (prod md5 bd3c0b56e0173e32399dd73eadec1d7f, identical on staging).
- T2 (commit 2b9306a): src/hooks/use-promo-pendiente.ts (shared by the banner and the notifications page; it refetches
  on the existing 'wacrm:notification-insert' event, with no new realtime channel), src/components/layout/promo-banner.tsx
  in the dashboard shell (owner/admin only; Confirm is disabled without a price). Vitest RED (missing module) -> 6/6
  GREEN; typecheck clean; full suite 1811 passed. Lint: 1 error in notifications/page.tsx at the unchanged `load()`
  effect, pre-existing. Staging app deployed: release 2b9306a, BUILD_ID wrp5E8s6LKgOVF0Molk3B, served by the domain,
  anterior -> a43d66b.
- T3 (partial): n8n "[STAGING] Vigilante - promociones de Etecsa" okU7TYnB8R8b1OSo (copy of prod, staging DB
  credential np3egGrAcrWkOWd4, every 3 h), active. A manual MCP run (execution 326237) hung in "running"; check the
  first scheduled run. Prod backup JSON: scratchpad prod-vigilante-etecsa-20261004.json.
- T4 setup: test contact reset; the earlier staging test promo 7cd158a0 (3–6 Oct, confirmed) set to 'descartada';
  fake promo through cerebro_promo_revision: 600-1250 CUP x5, 8–11 Oct -> "detectada, pendiente de confirmar",
  notice to donhdoll@gmail.com (the staging owner). Before confirming, proxima and vigente are empty.
  Waiting for the owner to confirm in the CRM and test the bot.
