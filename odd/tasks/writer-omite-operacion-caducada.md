# The recipient writer never targets an operation that can no longer take a deposit

Status: staging green · Branch: feat/port-chat-operations-calculator · Worktree: wacrm-worktrees/mejora-legacy · 2026-11-25

## Objective

Stop a recipient write from landing on an open operation that the deposit rule (391) already refuses, so the deposit
and the recipient always end up on the same operation.

## Problem

Production 2026-11-25, conversation f0dd06de (Yais). The bot reused an unfunded operation opened on 11-23 (`9fb86ab2`)
for the Zelle recipient and the service change. When the receipt arrived, 391 refused the deposit there (no money and
older than `completar_ventana_horas`) and created a second operation (`5b0ff90e`). The recipient stayed on the old one;
the bot asked the customer for data it already had; the chat ended with two open sends and a human finished it by hand.

## Scope

- Migration 399: `_cerebro_op_puede_recibir_deposito(op)` mirrors the 391 target rule; `cerebro_escribir_bloque_beneficiario`
  (the single funnel for every recipient writer) cancels an ineligible open remesa (audited `agent_operation_cancel`)
  and lets the existing "nothing open" branch open a clean operation.
- Paused conversation: the writer raises the pause text and changes nothing (390 behaviour kept).
- Out of scope: Yais's two stranded operations (owner handles them by hand); the deposit side of 391.

## Constraints

- Strict TDD on staging: the new assertion is RED without 399 and GREEN with it; rollback restores the 390 body.
- Production only with the owner's go-ahead.

## TDD

Mode: strict, on. Runner: `infra/db/staging-migracion.sh aplicar <mig> <assertion> <rollback> <fns>`.

## Tasks

- [x] T1 Migration 399 + ROLLBACK + assertion `writer-skips-stale-operation.sql` (cases A-F), staging cycle green.
- [x] T2 Related staging assertions: no regressions.
- [ ] T3 Production: `previa`, owner go-ahead, `aplicar`, `verificar`.

## Acceptance criteria

- Stale unfunded operation: cancelled with one audit row; one clean operation receives the recipient.
- Fresh / holds money / incident / locked amount: unchanged.
- Paused: refusal, nothing cancelled, nothing opened.
- Related staging assertions unchanged (220 run, no semantic difference).

## Delivery

Forecast ~354 authored lines (migration 140 + rollback 82 + assertion 132). Below the 400 heuristic.

## Progress

- 2026-11-25 T1: RED (assertion alone through psql_staging) 5 expectations failed (A1-A3, A5, D1). First apply cycle
  failed on F1: `admin_locked_fields` is stripped unless `wacrm.origin='admin'`; the assertion now sets it. Cycle:
  dry-run OK, apply OK, assertion OK, rollback OK (md5 equal to previous). ACL: helper postgres only; writer unchanged.
- 2026-11-25 T2: `relacionadas 399 ... --ya-aplicada ROLLBACK-399` TOTAL 220, SAME 219, DIFF 1 (uuid-only differences in
  the known fixture setup errors; no semantic change).

## Next step

T3 (production), with the owner's go-ahead.
