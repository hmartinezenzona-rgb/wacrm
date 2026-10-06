# Feature: read-only operations board

## Objective
One page shows the state of every chat's operations at a glance, like the old pipeline did: columns by status, one
card per operation, a click opens the chat. Nothing can be moved from it: the panel inside each chat stays the only
place to act.

## Context (2026-10-05)
- The old deals kanban was removed on purpose at the cutover (commit 78e682d). The guard
  src/components/layout/pipelines-removed.test.ts forbids src/app/(dashboard)/pipelines/page.tsx and the old board
  components. The deals are being retired (odd/tasks/eliminate-deals.md).
- The real state lives in remittance_operations.status (collecting_information, deposit_verification,
  ready_to_transfer, transferring, incident, completed, cancelled). Each chat's panel reads it with
  crm_operaciones_de_conversacion. remittance_operations has RLS with no policies: the client reads it through
  SECURITY DEFINER RPCs.

## Owner decision (2026-10-05)
Option 1: a separate read-only board page (not a badge in the inbox list).

## Defaults chosen by Claude (stated to the owner, open to change)
- Route /tablero (next to /calculadora and /resumen); never /pipelines.
- Columns: collecting_information "Solicitada", deposit_verification "Por verificar", ready_to_transfer (and
  transferring) "Lista para transferir", incident "Incidencia", and completed in the last 24 h. Cancelled operations
  are not shown.
- Card: customer name, service (remesa, recarga, combo, visa, ...), amount in GYD, and time in the current state.
  A click opens the chat in the inbox.
- A service filter. Auto-refresh every few seconds (and on window focus). No drag and drop, no actions.
- Every account member can see it (read-only).
- Panel copy in English through messages/en.json, like the rest of the panel.

## Tasks
- [x] T1 DB `214_operations_board.sql` (+ ROLLBACK, assertion operations-board.sql).
  - New RPC `crm_tablero_operaciones()`: SECURITY DEFINER, account members only, granted to authenticated.
  - It returns the caller account's open operations plus those completed in the last 24 h: id, conversation_id,
    customer name and phone, service_type, delivery_method, status, quoted_source_amount, created_at, the time of the
    last status change, and the beneficiaries-complete flag.
- [x] T2 App:
  - the /tablero page (columns, cards, service filter, auto-refresh, the link to the chat);
  - a nav entry and i18n keys;
  - vitest tests. pipelines-removed.test.ts stays green.
- [x] T3 Staging deploy and the owner's check.
- [x] T4 Production after the go-ahead.

## TDD
Strict. SQL assertion (self-reverting DO block, fixtures independent of staging data); vitest for the app.

## Progress
- 2026-10-05 T1 done (96508b7), staging only. RED: operations-board.sql failed with "No function matches ... crm_tablero_operaciones()". Applied 214 on staging (recorded in schema_migrations). GREEN: the same assertion ended in `ERROR: ALL PASS` (BEGIN ... ROLLBACK).
  - state_since: completed -> completed_at; else the latest remittance_admin_audit row (field_name 'status') whose after->>'status' is the current status; else updated_at. The audit holds only human status changes and updated_at moves on every edit, so the fallback can under-state the age.
  - Authorization: caller's account from profiles (auth.uid()), is_account_member(viewer); 42501 otherwise. No account argument.
- 2026-10-05 T2 done (1dbb201, 6034aa1). Route /tablero, sidebar "Operations board" (Columns3) with no role gate. Data via the session client RPC (src/lib/tablero/fetch.ts), refresh every 20 s and on focus. Tests: 5 new files (board, fetch, operations-board, page, sidebar-nav): RED (modules missing / navItems not exported), then GREEN.
  - Verification: vitest of new files + pipelines-removed + inbox/operations 28 files / 398 tests pass; npm run typecheck clean; eslint on touched files clean; npm test 155 files / 1951 tests pass.
  - Not verified: nothing was seen in a browser (layout, horizontal scroll, mobile gutter); staging deploy of the app is T3.

- 2026-10-05 parent review:
  - re-ran the SQL assertion on staging (ALL PASS) and the board, tablero and layout tests (6 files, 35 tests);
  - no AI trailer in the writer's commits.
- T3 staging deploy: release 857a15c, BUILD_ID 7yqCezYoulcABvvn_0Wtk, served; the build contains the tablero route;
  0 production refs. Waiting for the owner's check in the browser.
- T3: owner check on staging: "no se ve mal, se puede mejorar pero mal no se ve, pásalo".
- T4 PRODUCTION (2026-10-05):
  - Pre-check: crm_tablero_operaciones absent in production.
  - Backup produccion-20261005T130307Z.dump (sha256 a3c68afca1acf5fb...; 2152 list entries).
  - Temp helper. gate114-aplicar-db.py: ensayo md5 facb2cc2 equal to staging; aplicar OK (schema_migrations
    20261005130555 214_operations_board).
  - probar in production: operations-board, read-rpc, combo-model and visa-model all pass.
  - Helper dropped. ACL: anon cannot execute it, authenticated can. No leftover users or contacts.
  - The ida-y-vuelta check was not needed: the rollback only drops the new function.
  - App release 8953277 (build FdUDqKgiT1j0yd39zimbv): pm2 cwd is the new release; the domain serves it; anterior ->
    bac9fa3.
- Follow-up (owner: "se puede mejorar"): visual polish later. state_since under-states the age when the system
  (not a person) changed the status.
- 2026-10-06 owner: "incidencias sea la ultima". BOARD_COLUMNS order is now requested, depositCheck, readyToTransfer,
  completed, incident. RED: 3 board tests failed on the new order; GREEN: tablero + layout vitest 7 files / 40 tests,
  tsc and eslint clean. App only (the RPC order does not matter: groupBoard maps over BOARD_COLUMNS).
