# Phase 3: deterministic reconciliation

Status: IN PROGRESS (2026-10-26). Objective: every verified customer deposit enters the funding case
and the database, not the model, decides how much GYD of the case is assigned to each real operation.
This is the first increment (3a): the engine, the confirmed-prefix conflict state, and the wiring into
deposit verification, splits and beneficiary changes. The bot messages and the panel are phase 4.

## Why

Phase 2 created the ledger but nothing wrote to it. Money still waits on an operation, and the model
still decides when to call the split. The engine must run on every relevant change: a verified
deposit, a new recipient, a completed split, a card conflict or a voided deposit.

## Scope

In scope:
- `funding_reconciliar(conv, actor)`: opens/gets the case, links every verified customer deposit
  attributable to the conversation, detects confirmed card-prefix conflicts, and allocates the case's
  GYD to the open operations that have a service, a positive amount and complete recipient data.
- `cerebro_riel_por_prefijo` and `cerebro_op_conflicto`: the confirmed prefixes 9760 (Clasica), 9240
  (Tropical) and 9234 (CUP). Unknown prefixes never conflict.
- Calls from `cerebro_cruzar_deposito` (verified deposit) and `_repartir_envio_core` (split), plus a
  trigger on `remittance_beneficiaries` (new/updated recipient).
- An incident case on a confirmed conflict or on a deposit void that leaves the case over-allocated.
- `cerebro_fondos_operacion` uses committed allocations for a scope (operation or group) that has
  them, and keeps the linked deposits for a scope without allocations. `cerebro_saldo_operacion` stays
  on linked deposits in 3a, so the bot's deposit routing keeps the 329 behaviour. `crm_entregar_operacion`
  blocks an operation whose case is in incident.
- `funding_case_resolver(case, actor)`: an operator clears an incident after fixing the data.

Out of scope: automatic release when a split shrinks (a target decrease returns pending for review),
the full service-evidence model, bot wording, the panel, and any backfill.

## Rules

- A part is an open operation with `quoted_source_amount > 0`, a resolvable rail, complete recipient
  data (`crm_beneficiarios_completos`) and no conflict. A quote with no recipient is not a part.
- If the sum of the parts (targets minus already committed) exceeds the case's available balance, the
  engine allocates nothing and returns the shortfall. A part is never allocated partially.
- Allocations are append-only in 3a. If an operation already has more committed than its target, the
  engine returns a pending correction; an operator releases before reallocating.
- Once a scope (operation or group) has any committed allocation, allocations are its funding
  evidence; a scope without allocations keeps the linked deposits. The case-wide switch was rejected
  because it changed `cerebro_saldo_operacion` and made a full deposit wait for a recipient.
- `cerebro_saldo_operacion` is unchanged in 3a; the engine fills the case while the bot's deposit
  routing stays on the 329 behaviour.
- A confirmed card-prefix contradiction marks the whole case `incident`; no allocation and no delivery
  until an operator resolves it.
- A voided or discarded deposit that leaves `disponible < 0` marks the case `incident`.
- The engine never raises into the deposit cross or the split: those wrap the call and log a WARNING;
  the verified deposit or the split is never lost.

## Tasks

- [x] T1. Assertion `funding-reconciliacion.sql` with RED on the staging base.
- [x] T2. Migration 331: `cerebro_riel_por_prefijo`, `cerebro_op_conflicto`, `funding_reconciliar`,
      `funding_case_resolver`, the beneficiary trigger, the helper rewrites and the incident gate.
- [x] T3. Staging cycle (dry-run, apply, assertion, rollback).
- [x] T4. Related regressions for the touched functions and the beneficiary trigger.
- [x] T5. Production `previa 331`; report; wait for the go-ahead.
- [ ] T6. Production apply + verify; update docs and memory.

## Verification

- Staging: `infra/db/staging-migracion.sh aplicar supabase/migrations/331_funding_reconciliacion.sql
  supabase/staging/assertions/funding-reconciliacion.sql
  supabase/migrations/ROLLBACK-331-funding-reconciliacion.sql
  funding_reconciliar,funding_case_resolver,cerebro_riel_por_prefijo,cerebro_op_conflicto,cerebro_fondos_operacion,cerebro_saldo_operacion,crm_entregar_operacion,cerebro_cruzar_deposito,_repartir_envio_core`
- Related: `relacionadas 331 'crm_entregar_operacion|cerebro_saldo_operacion|cerebro_fondos_operacion|_repartir_envio_core|cerebro_cruzar_deposito|remittance_beneficiaries'`
  with `--ya-aplicada ROLLBACK-331-*`, skipping `funding-reconciliacion`.
- TDD: enabled; RED is the assertion failing because `funding_reconciliar` does not exist; GREEN is
  `ALL PASS` after 331.

## Evidence

- Phase 2 tables are empty in production, so the switch to allocations is behaviour-neutral until the
  engine writes its first allocation.
- The three confirmed prefixes come from the earlier card research and the design table. Any other
  prefix is unknown and never produces a conflict.
- T1 (2026-10-26): RED on the staging base: `function funding_reconciliar(uuid, unknown) does not exist`.
- T3 (2026-10-26): `dry-run OK`, `apply OK`, `assertion OK`, `rollback OK (md5 igual al previo)`.
  Functions after apply: `_repartir_envio_core 7ee7f690bbe3`, `cerebro_cruzar_deposito dee9bf32e607`,
  `cerebro_fondos_operacion c1464c07f149`, `cerebro_op_conflicto 90b4da0714da`,
  `cerebro_riel_por_prefijo 82f362254f2b`, `cerebro_saldo_operacion 2859c9af45fb`,
  `crm_entregar_operacion 11bf742731f0`, `funding_case_resolver 1aeb1779322b`,
  `funding_reconciliar 6e06439f490d`.
- The beneficiary trigger only runs when the conversation already has an active case; the case is
  created by the verified cross, so direct deposit fixtures in older assertions do not create cases.
- The engine links every open operation of the conversation to the active case even before an
  allocation; that is what lets the incident gate and the panel see the case, and the helper falls
  back to linked deposits while the case has no allocations.
- T4 (2026-10-26): the first full run had 113 SAME and 3 DIFF. Two were real (`deal-free-money-rules`
  and `split-deposit-minimums`: a full deposit on an operation without a recipient waited because
  `cerebro_saldo_operacion` had switched to case-wide allocations). The fix keeps
  `cerebro_saldo_operacion` on linked deposits and makes `cerebro_fondos_operacion` decide per scope.
  After the fix both are SAME (`split-deposit-minimums` ALL PASS; `deal-free-money-rules` fails on
  the base at case 10a, pre-existing). The third DIFF, `delivery-feed-evidence`, fails on the base
  during fixture setup with a random uuid; it is pre-existing and not caused by 331.
- Revised function md5 after the fix: `cerebro_fondos_operacion 85e83571e1ac`; the other functions
  keep the md5 listed above.
- T5 (2026-10-26): `produccion-migracion.sh previa 331` → `VEREDICTO: SEGURO`.
  `_repartir_envio_core`, `cerebro_cruzar_deposito`, `cerebro_fondos_operacion` and
  `crm_entregar_operacion` are EQUAL against the staging pre-bundle state; the five new functions are
  NEW; the 55 columns/constraints/triggers/indexes of the touched tables are equal. Awaiting the
  owner's explicit go-ahead.
