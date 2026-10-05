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
- [ ] T3 Staging deploy and the owner's check.
- [ ] T4 Production after the go-ahead.

## TDD
Strict. SQL assertion (self-reverting DO block, fixtures independent of staging data); vitest for the app.

## Progress
- 2026-10-05 T1 done (96508b7), staging only. RED: operations-board.sql failed with "No function matches ... crm_tablero_operaciones()". Applied 214 on staging (recorded in schema_migrations). GREEN: the same assertion ended in `ERROR: ALL PASS` (BEGIN ... ROLLBACK).
  - state_since: completed -> completed_at; else the latest remittance_admin_audit row (field_name 'status') whose after->>'status' is the current status; else updated_at. The audit holds only human status changes and updated_at moves on every edit, so the fallback can under-state the age.
  - Authorization: caller's account from profiles (auth.uid()), is_account_member(viewer); 42501 otherwise. No account argument.
- 2026-10-05 T2 done (1dbb201, 6034aa1). Route /tablero, sidebar "Operations board" (Columns3) with no role gate. Data via the session client RPC (src/lib/tablero/fetch.ts), refresh every 20 s and on focus. Tests: 5 new files (board, fetch, operations-board, page, sidebar-nav): RED (modules missing / navItems not exported), then GREEN.
  - Verification: vitest of new files + pipelines-removed + inbox/operations 28 files / 398 tests pass; npm run typecheck clean; eslint on touched files clean; npm test 155 files / 1951 tests pass.
  - Not verified: nothing was seen in a browser (layout, horizontal scroll, mobile gutter); staging deploy of the app is T3.

