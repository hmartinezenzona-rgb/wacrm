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
- [x] T1 RED: staging assertion board-status-age.sql: a status change by a non-audited writer, then an unrelated edit,
  keeps state_since at the status change; insert sets it; a no-op update does not move it; the RPC returns it.
  Observed failing on staging before 219.
- [x] T2 Migration 219 + ROLLBACK-219 on staging; T1 GREEN; operations-board.sql and read-rpc assertions still pass;
  rollback round trip checked; board vitest green.
- [x] T3 Owner check of /tablero on staging. Skipped by owner decision: staging has one operation and nothing visual changed;
  the assertions cover the number.
- [x] T4 Production DB with the owner's go-ahead.

## Acceptance criteria
- After 219, a card's age equals the time since the operation's last real status change, whoever made it.
- Same RPC signature; no app change needed; nothing else on remittance_operations behaves differently.

## Progress
- 2026-10-06 document created. Delivery strategy: ask-on-risk.
- 2026-10-06 T1 done (assertion supabase/staging/assertions/board-status-age.sql, 6 cases: insert stamp, bot status change then
  unrelated edit, same-status update, a later real change, suppressed automation completion, completed = completed_at).
  - RED on staging before 219 (as is and no promo): `case 1: state_since 2026-10-06 04:16:32.523804+00 is outside the insert window [... 32.934964, ... 32.963252]` (state_since was the transaction's updated_at).
- 2026-10-06 T2 done on staging (migration 219 recorded in schema_migrations, version 219).
  - GREEN: board-status-age.sql `ALL PASS (rolled back on purpose)` as is and with promos discarded.
  - Regressions: read-rpc.sql ALL PASS, operations-realtime.sql ALL PASS, operations-board.sql ALL PASS (as is and no promo) after one
    intended fixture change: its case 2 (audit-derived state_since) now NULLs status_changed_at on that operation, because the stamp
    correctly wins over the audit row since 219; the fallback to 214's derivation stays covered.
  - Round trip in one rolled-back transaction: function md5 pre-219 facb2cc2e6b4c7fc6ee0fb698b45a190, after 219 d09ded1e35123fcf13a506dbb9dc0427,
    after ROLLBACK-219 facb2cc2e6b4c7fc6ee0fb698b45a190; column gone, trigger gone. Backfill left remittance_operations updated_at/version untouched
    (fingerprint equal before/after); 0 NULL stamps after backfill; 0 leftovers for test phone 59900219.
  - vitest src/lib/tablero, src/components/tablero, src/app/(dashboard)/tablero: 4 files, 26 tests passed. App unchanged.
  - Decisions: trigger named trg_zz_status_changed_at so it fires after the completion guard (which can rewrite NEW.status) and the touch
    trigger; column left NULLABLE (RPC falls back to 214's derivation on NULL; a NOT NULL would make a stray explicit NULL write fail);
    completed operations keep completed_at as state_since (coalesce(completed_at, status_changed_at, updated_at)); backfill disables user
    triggers for its single UPDATE so updated_at/version/notifications do not move.

- 2026-10-06 T4 PRODUCTION (owner: "si"):
  - Backup ~/wacrm-respaldos/produccion-20261006T042334Z.dump (sha256 39cdd378c413597b...).
  - Pre-check: crm_tablero_operaciones md5 facb2cc2e6b4c7fc6ee0fb698b45a190 (= ROLLBACK-219 header), no column, no trigger.
  - ~/cerebro-fase1/pruebas/gate117-aplicar-db.py (copy of gate116; strips ROLLBACK-219's BEGIN;/COMMIT; lines) with a
    temporary zz_wu5b_exec (EXECUTE only; revoked from PUBLIC, anon, authenticated, service_role):
    - ensayo: d09ded1e35123fcf13a506dbb9dc0427 col=1 trg=1 stampfn=1 (= staging), rolled back;
    - ida-y-vuelta: facb2cc2e6b4c7fc6ee0fb698b45a190 col=0 trg=0 stampfn=0, rolled back;
    - aplicar: OK, schema_migrations 20261006042651 219_board_status_age;
    - probar: board-status-age ALL PASS, operations-board ALL PASS, read-rpc and operations-realtime no failure (forced
      rollback).
  - After: fn md5 d09ded1e..., trigger enabled, no disabled triggers on remittance_operations, 0 NULL stamps over 618
    operations, 0 leftovers, anon cannot execute the RPC, authenticated can. Helper dropped (first DROP hit an MCP
    session error and did not run; re-checked, dropped, count 0).
  - Existing open operations (6 ready_to_transfer) got their stamp from updated_at, so today's ages are unchanged; the
    fix shows from the next status change on.

## Next step
Done. Visual polish of /tablero stays open until the owner names what to change.
