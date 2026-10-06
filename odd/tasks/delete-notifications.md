# Feature: delete notifications

## Objective
A user can delete their own notifications: one at a time (an X on each) or all at once ("Borrar todas", with a
confirmation, unread ones included).

## Problem
Notifications pile up and never go away. public.notifications is per user (user_id) with RLS policies only for SELECT
and UPDATE (auth.uid() = user_id). With no DELETE policy a delete matches no row, and the /notifications page has no
delete control (it only marks as read). The page already handles realtime DELETE events.

## Why (owner, 2026-10-06)
"me gustaria que se puedan borrar las notificaciones, actualmente se acumulan y no se quitan". Choice: "Una a una +
borrar todas". Confirmation on "Borrar todas" added by Claude (it also removes unread ones), stated to the owner.

## Scope
- DB, migration 220 (+ ROLLBACK-220, staging first): RLS policy notifications_delete FOR DELETE TO authenticated
  USING (auth.uid() = user_id). No other change.
- App (/notifications page and whatever shows the unread count / header list):
  - an X per notification (does not trigger the row's click/navigation), optimistic removal, error toast + reload on
    failure;
  - "Borrar todas" next to "mark all read", disabled when the list is empty, behind a confirmation dialog; deletes only
    the caller's rows (RLS) — filter by the user's own rows like the page's other queries;
  - the unread badge stays correct after deletes (realtime DELETE or refetch);
  - new copy through messages/en.json + messages/es.json (parity test must stay green).
- Out of scope: automatic cleanup, the existing hard-coded English on this page (listed in spanish-ui.md).

## Constraints
- A user can never delete another user's notifications (RLS). anon gets nothing new.
- Production only with the owner's go-ahead (DB via gate script, then app), together with the Spanish UI release.

## TDD
Strict TDD on (user config). Runners: staging assertion via psql-staging.sh (BEGIN ... ROLLBACK); app via vitest.

## Tasks
- [x] T1 RED: staging assertion delete-notifications.sql (owner deletes own row: gone; deleting another user's row:
  0 rows affected and still there; anon cannot delete) — fails before 220. Migration 220 + ROLLBACK-220 on staging,
  round trip checked; GREEN.
- [x] T2 App: X per notification and "Borrar todas" with confirmation; badge stays right; i18n en/es; vitest RED then
  GREEN; typecheck, lint, full suite.
- [x] T3 Staging deploy (Spanish UI + this); owner's look (2026-10-06: "pasalo a produccion").
- [x] T4 Production with the owner's go-ahead: DB 220 via gate script, then the app (also releases spanish-ui T4).

## Acceptance criteria
- After 220 and the app change, the owner removes one notification or all of them and they stay gone after a reload;
  another user's notifications are untouched.

## Progress
- 2026-10-06 document created. Delivery strategy: ask-on-risk.

- 2026-10-06 T1 done on staging (commit 92313a2): assertion supabase/staging/assertions/delete-notifications.sql (4 cases + unfiltered delete).
  - RED before 220, as is and no promo: `case 1: deleting an own notification affected 0 rows, expected 1`.
  - Round trip in one rolled-back transaction: policy count 0 -> 1 (DELETE, qual `(auth.uid() = user_id)`) -> 0. Applied to staging with
    schema_migrations row 220 `220_notifications_delete_policy`. GREEN after: `ALL PASS (rolled back on purpose)` as is and no promo;
    leftovers 0. notifications has REPLICA IDENTITY FULL ('f') and is in supabase_realtime, so DELETE events carry the whole old row.
- 2026-10-06 T2 done: page (X per row with aria-label, "Borrar todas" next to "Mark all as read" with a Dialog confirmation, optimistic,
  toast + reload on error), catalog namespace Notifications (en/es). Unread badge hook now RECOUNTS on a DELETE event instead of
  decrementing: realtime does not apply RLS to DELETE events, so another user's delete would have lowered this user's badge.
  - vitest RED (8 page + hook failures) then GREEN; full suite 159 files / 1985 tests pass; tsc clean; parity test green; eslint on touched
    files: only the pre-existing react-hooks/set-state-in-effect error on `load()` in the page's effect (present on HEAD, untouched).

- 2026-10-06 T3 staging deployed (owner's look pending; T3 NOT checked off): release 555535c538e9b41fd9029699d4670c7ac375ce11,
  BUILD_ID EHLM-0PiljguKp0KJGOjn, same procedure as 54df1e2 (clean prod-build worktree, docker node:20, staging-build.env with
  NEXT_PUBLIC_APP_LOCALE=es, built off oracle2). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production
  refs / 32 staging refs, sha256 OK, 2416 files. `current` -> 555535c, `anterior` -> 5959dd2; pm2 cwd = ~/wacrm-releases/current,
  restarts 64 -> 65 and stable; /login 200 locally and on the domain, serves the new BUILD_ID and "Bienvenido de nuevo".
  "Borrar todas las notificaciones" is NOT in .next/static: next-intl messages ship in the server chunks / RSC payload (78 files
  under .next/server). No DB change (220 already on staging). Rollback: relink `current` to `anterior` + `pm2 restart wacrm-staging --update-env`.

## Next step
T3 staging deploy (Spanish UI + this); owner's look.

- 2026-10-06 production app: release 555535c (BUILD_ID qeG5ojHkJArkrrcbZdzDj), owner go-ahead "pasalo a produccion". Built in prod-build with Node 20 docker + the production build env (NEXT_PUBLIC_APP_LOCALE=es added, backup .bak-20261006, file untracked): manifest production / hqztotshnlzaiziwjyzh, 114 money-path tests passed, bundle 0 staging refs / 32 production refs, sha256 OK. pm2 wacrm cwd = `current` -> release 555535c, `anterior` -> 225cba2; `/login` 200 on wacrm.onlinefreedom.site serving the new BUILD_ID and "Bienvenido de nuevo" (no "Welcome back"); .next/server has "Borrar todas las notificaciones"; pm2 restarts 25 -> 26 and stable. prod-build left clean at 555535c. Rollback: `infra/deployment/rollback-wacrm-produccion.sh`. App part of T4 only; DB 220 evidence and the T4 check are the parent's.
- 2026-10-06 T4 DB (parent): backup ~/wacrm-respaldos/produccion-20261006T124453Z.dump (sha256 ff95a51ac44b84e6...).
  Pre-check: policies notifications_select, notifications_update only; 4,932 rows. ~/cerebro-fase1/pruebas/gate118-aplicar-db.py
  with temporary zz_wu5b_exec (revoked from PUBLIC, anon, authenticated, service_role): ensayo adds notifications_delete
  (DELETE, auth.uid() = user_id); ida-y-vuelta back to select + update only; aplicar OK (schema_migrations
  20261006124712 220_notifications_delete_policy); probar delete-notifications ALL PASS (forced rollback). Helper dropped
  (count 0); notifications_delete is for role authenticated; rows still 4,932.
- 2026-10-06 parent: production /login 200, BUILD_ID qeG5ojHkJArkrrcbZdzDj, Spanish. The production build env backup was
  moved out of the repo to ~/.config/wacrm/wacrm.produccion.build.env.bak-20261006 (the *.bak name is not gitignored).
