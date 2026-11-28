# Phase 2: funding case and allocation ledger

Status: DONE (2026-10-26): applied in production as migration 330 (version 20261026184859) and
verified 6/6. Objective: give the money a holder that is not a delivery operation. The funding case
groups verified deposits; allocations assign GYD of the case to real operations. This is the schema
foundation for the deterministic reconciliation (phase 3) and the panel UX (phase 4). It does not
change the bot or any existing function.

## Why

Phase 1 made delivery require verified funding, but the operation still holds the money: a deposit
belongs to one operation and a quote can still open operations. The external review's correction is
that money must live in a case, separate from the send. Existing operations stay as they are; new
deposits can be linked to a case, and allocations decide which operation consumes which GYD.

## Scope

In scope: `funding_case`, `case_deposits`, `funding_allocations`, `funding_movements`,
`remittance_operations.case_id`, and the six authorized functions that write them.

Out of scope: automatic case creation on deposit, deterministic reconciliation, conflict handling in
the bot, panel UX, and any backfill of history. The funding gate of 329 remains operation-based until
phase 3.

## Model

- `funding_case`: `id`, `account_id`, `conversation_id`, `status` (`open`, `allocating`, `closed`,
  `incident`), `opened_at`, `closed_at`, `created_by`, `closed_by`, `note`. One active case per
  conversation (partial unique index); multiple closed cases are allowed.
- `case_deposits`: `(case_id, deposit_trans_id)`; a verified `depositos_mmg` row belongs to at most one
  case. `depositos_mmg` remains the source of truth; the link does not copy money.
- `funding_allocations`: `case_id`, `operation_id`, `amount_gyd > 0`, `status` (`proposed`,
  `committed`, `released`), `evidence_type` (`data`, `explicit_choice`, `operator`,
  `minimum_suggestion`), unique `idempotency_key`, `created_at`, `created_by`, `released_at`,
  `release_reason`.
- `funding_movements`: append-only audit of commits and releases (`kind` = `commit`, `release`,
  `refund`, `adjustment`), amount, unique idempotency key, reason, actor.
- `remittance_operations.case_id`: nullable FK; existing rows untouched.

## Invariants (enforced by the functions)

- `disponible = verified deposits linked to the case - committed allocations`; never negative.
- A deposit can be linked only when it is consumed (verified), not voided, not discarded, and in GYD.
- An allocation requires: active case, open operation of the same conversation, no other case, amount
  within `disponible`.
- A release returns the amount to `disponible`; it is idempotent; a completed operation's allocation
  cannot be released.
- A case closes only with `disponible = 0`; a closed case accepts no links or allocations.
- Every write is idempotent through a unique key; no row is deleted.

## Functions (service_role only in phase 2)

- `funding_case_abrir(conv, actor)` → case id; returns the active case if it exists.
- `funding_case_saldo(case)` → depositado, asignado, disponible, moneda.
- `funding_deposito_vincular(case, trans_id, actor)`.
- `funding_asignar(case, operation, amount, evidence_type, idempotency_key, actor)` → allocation id.
- `funding_liberar(allocation, idempotency_key, reason, actor)`.
- `funding_case_cerrar(case, reason, actor)`.

## Tasks

- [x] T1. Assertion `funding-case.sql` with RED on the staging base (tables/functions absent).
- [x] T2. Migration 330 with the four tables, the column, RLS, comments and six functions.
- [x] T3. Staging cycle `aplicar` (dry-run, apply, assertion, rollback).
- [x] T4. Production `previa` over 330; report; wait for the go-ahead.
- [x] T5. Production `aplicar 330` after approval; `verificar`. Applied 2026-10-26 18:48:59 UTC after
      the Management API recovered; the earlier Cloudflare 502 attempts left production unchanged.
- [x] T6. Update the design/task docs and save the evidence.

## Verification

- Staging: `infra/db/staging-migracion.sh aplicar supabase/migrations/330_funding_case.sql
  supabase/staging/assertions/funding-case.sql
  supabase/migrations/ROLLBACK-330-funding-case.sql
  funding_case_abrir,funding_case_saldo,funding_deposito_vincular,funding_asignar,funding_liberar,funding_case_cerrar`
- Production: `previa` → `aplicar` → `verificar`.
- TDD mode: enabled (global `Strict TDD Mode: enabled`); runner: the SQL assertion. RED is the
  assertion failing because the functions/tables do not exist; GREEN is `ALL PASS` after 330.

## Decisions

- Table names follow `odd/design/no-service-without-data.md`: `funding_case`, `case_deposits`,
  `funding_allocations`, `funding_movements`.
- One active case per conversation in phase 2 (partial unique index); the model supports more later.
- Proposed allocations do not reserve money; only `committed` counts against `disponible`.
- Tables are RLS-protected and service_role only; the panel gets access in phase 4 with its own
  authorization checks.
- No existing function changes and no backfill: phase 2 is additive and safe to apply before phase 3.

## Evidence

- T1 (2026-10-26): the assertion on the staging base ended with
  `function funding_case_abrir(uuid, unknown) does not exist`.
- T3 (2026-10-26): `dry-run OK`, `apply OK`, `assertion OK`, `rollback OK (md5 igual al previo)`.
  Function md5 after apply: `funding_asignar a54c8a532f29`, `funding_case_abrir 77efeaaf4440`,
  `funding_case_cerrar 02a8265970c5`, `funding_case_saldo 50f69dffaa8c`,
  `funding_deposito_vincular b7c6d3ea02e1`, `funding_liberar c53e96f541a5`.
- No `relacionadas` run is needed: 330 changes no existing function and only adds a nullable column.
  The only assertion reading the whole operation row (`beneficiary-touches-operation`) takes both
  snapshots in the same migrated state, so the new null column cancels out.
- The assertion covers: idempotent open, one active case per conversation, duplicate link, unverified
  / voided / non-GYD / foreign-case deposits, idempotent allocation, key reuse with different
  arguments, over-allocation, another conversation, a completed operation, idempotent release, a
  completed operation's release, closing with a balance, closing at zero, a closed case refusing
  writes, and conservation.
- T4 (2026-10-26): `produccion-migracion.sh previa 330` → `VEREDICTO: SEGURO`; the six functions are
  `NEW` and the 64 columns/constraints/triggers/indexes of the touched tables are equal. Awaiting the
  owner's explicit go-ahead to apply.
- T5 (2026-10-26): two apply attempts stopped at the pre-check `POST /database/query -> 502`
  (Cloudflare `Bad gateway`, api.supabase.com, 18:41 and 18:42 UTC). The migration POST was never
  reached. A read-only check after each attempt: `NO-RECORD` in `schema_migrations`, all four tables
  absent, `case_id` absent, no `funding_*` function. The API outage is external; retry when it
  recovers.
- T5 (2026-10-26 18:48:59): the API recovered and `aplicar 330` returned `OK 330_funding_case
  20261026184859`; `verificar` → `VERIFICADO: 6/6 iguales`.
