# Phase 4d: panel assign and release

Status: STAGING DONE (2026-10-26); production pending. Objective: an agent can assign GYD of the
funding case to an open operation and release a committed allocation from the panel, with the same
balance and idempotency rules as the engine.

## Why

The panel showed the case and could resolve an incident, but the operator could not act on the money
when the engine left a valid pending allocation (or needed to free money for another part).

## Scope

- Migration 334: `funding_caso_panel` now returns the open operations with service, status, quoted
  amount and committed allocation; new `funding_caso_asignar_panel` (agent) and
  `funding_caso_liberar_panel` (agent), both SECURITY DEFINER and membership-checked.
- API: `POST /api/funding-case/{caseId}/assign` and `.../release`.
- `FundingCaseBlock`: the operations list, an assign form (operation + amount + one idempotency key
  per action) and a two-step release confirmation. The returned case refreshes the block.
- SQL assertion + component tests.

Out of scope: refunds. They need an owner rule for fees and the source deposit before money leaves a
case; the movement kind `refund` remains unused.

## Rules

- `funding_asignar` enforces a positive amount, the case balance, the operation's conversation and
  status, and the idempotency key.
- `funding_liberar` refuses the allocation of a completed operation; a release is idempotent.
- The panel never bypasses the functions; the RPCs check `is_account_member(agent)` themselves.

## Tasks

- [x] T1. SQL assertion `funding-caso-acciones.sql` with RED on the staging base.
- [x] T2. Migration 334 + staging cycle.
- [x] T3. API routes, component, messages and tests.
- [x] T4. `npm run test`, `npm run typecheck`, parity and lint.
- [ ] T5. Production `previa 334`; report; wait for the go-ahead.
- [ ] T6. Apply 334, publish the panel, verify.

## Evidence

- T1 (2026-10-26): RED: `case 1: the panel does not expose operations`.
- T2: `dry-run OK`, `apply OK`, `assertion OK`, `rollback OK (md5 igual al previo)`;
  `funding_caso_panel 50a7e7891e90`, `funding_caso_asignar_panel 9efde3c82874`,
  `funding_caso_liberar_panel a4f21dc0e856`.
- T3/T4 (2026-10-26): component tests 4/4 (render, assign form, release, resolver feedback);
  typecheck clean; messages parity 4/4; eslint clean on the touched files.
- The assertion covers the operations list, assign, idempotency, over-assignment, non-member
  assign/release, release, and a completed operation's allocation.

## Decisions

- Assign uses `evidence_type = 'operator'`; the idempotency key is generated when the form opens and
  reused if the same submit is retried.
- The operations list only includes open operations of the case's conversation; a completed
  operation's allocation cannot be released.
- Refunds are deferred until the owner decides the fee and the source deposit.
