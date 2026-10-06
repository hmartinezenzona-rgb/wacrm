# Feature: operations board shows the real time in the current status

## Objective
Each card on /tablero shows how long the operation has been in its CURRENT status, correct whoever changed it (a
person, the bot, or a trigger), so stuck operations stand out.

## Problem
crm_tablero_operaciones() (migration 214) has no status-changed timestamp to read. It uses completed_at, then the
latest human audit row for the status, then updated_at. The bot's status changes are not audited, and updated_at moves
on every edit, so an operation stuck 5 h in "Por verificar" shows "2 min" after any later touch.

## Why (owner, 2026-10-06: "si")
The board exists to spot operations that wait too long; a wrong age hides exactly those.

## Scope
- DB, migration 219 (+ ROLLBACK-219, staging first):
  - new column remittance_operations.status_changed_at timestamptz, set by a trigger on INSERT and whenever status
    changes (any writer);
  - one-time backfill for existing rows with the best value 214 already derives (completed_at, human audit row,
    updated_at);
  - crm_tablero_operaciones() returns state_since from status_changed_at (same signature and shape).
- App: no change expected (state_since keeps its name and type). Confirm with the existing board tests.
- Production only with the owner's go-ahead: backup, md5 pre-check, gate script, then probar.

## Constraints
- No change in who can read what (RLS, grants, the RPC's authorization).
- The trigger only stamps the timestamp: it never changes status or any other column, and does not touch updated_at
  semantics.
- Existing triggers on remittance_operations keep their behaviour (check ordering and any BEFORE UPDATE that rewrites
  status).

## TDD
Strict TDD on (user config). Runner: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK), as is and with no
promo; app via the repo's vitest for src/lib/tablero and src/components/tablero.

## Tasks
- [ ] T1 RED: staging assertion board-status-age.sql: a status change by a non-audited writer, then an unrelated edit,
  keeps state_since at the status change; insert sets it; a no-op update does not move it; the RPC returns it.
  Observed failing on staging before 219.
- [ ] T2 Migration 219 + ROLLBACK-219 on staging; T1 GREEN; operations-board.sql and read-rpc assertions still pass;
  rollback round trip checked; board vitest green.
- [ ] T3 Owner check of /tablero on staging.
- [ ] T4 Production DB with the owner's go-ahead.

## Acceptance criteria
- After 219, a card's age equals the time since the operation's last real status change, whoever made it.
- Same RPC signature; no app change needed; nothing else on remittance_operations behaves differently.

## Progress
- 2026-10-06 document created. Delivery strategy: ask-on-risk.

## Next step
T1.
