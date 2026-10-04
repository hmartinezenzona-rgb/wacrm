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
- [ ] T1 DB `206_promo_notice.sql` (+ ROLLBACK): cerebro_promo_registrar notifies the owner and admins of the
      whatsapp_config account; it skips a promo whose `hasta` is before today (Guyana time) and registers nothing.
      Assertion `supabase/staging/assertions/promo-notice.sql`: RED on staging before, then GREEN.
- [ ] T2 CRM: a pinned promo banner in the dashboard shell while a promo is pending, with Confirm and Discard (reusing
      /api/promotions/etecsa). Vitest RED → GREEN; deploy to the staging app.
- [ ] T3 n8n: a "[STAGING] Vigilante - promociones de Etecsa" copy on the staging DB credential, every 3 h. The same
      3 h change for prod is prepared and waits for the go-ahead.
- [ ] T4 Staging end to end: inject a fake upcoming promo through cerebro_promo_revision; the owner sees the
      banner, confirms it, and the bot announces it when the test number asks about recharges.
- [ ] T5 Production, after the owner's go-ahead: 206, the app, and the 3 h cadence.

## Progress
- 2026-10-04: investigation done (Engram cerebro/etecsa-monitor-2026-10-04).
