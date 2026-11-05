# One "Completar envío" for a mixed send paid with one deposit

## Problem

A mixed send (`remittance_operations.mixed_group_id`) is split into one operation per service (Zelle + CUP card,
recarga + remesa, Mexico + CUP...). Each operation has its own "Completar" in the chat's operations panel, even when one
verified deposit pays the whole send. Production 2026-10-29: all 6 mixed groups were paid with a single deposit and the
admin completed each part separately. Same-service recipients are already one operation with several beneficiaries.

## Owner decision

2026-10-29: "si el deposito es uno solo y ya esta verificado no tiene que salir por cada beneficiario". Mockup
https://claude.ai/artifact/T1k2Lxz2qt128HQRUBixmM; then "me gustaria verlo en el crm de pruebas".

## Scope

- T1 Panel (inbox operations panel): when every non-cancelled member of a mixed group is `ready_to_transfer` and the
  group is paid by exactly ONE consumed, unvoided MMG deposit (or every member has an admin forced verification, see
  migration 352), show one group card with the deposit, each part (service, amount, share of GYD) and one
  "Completar envio" button, instead of one "Completar" per part. With several deposits, or any member not ready, keep
  today's per-part behaviour.
- T2 "Completar envio" sheet: one block per part with its beneficiaries and one proof per beneficiary (same upload and
  proof rules as today's per-operation completion), the CUP source card picker for a CUP part (same as today), the
  "notify" choice, "Completar las N partes" (enabled when every proof is attached) and "Completar sin captura" (same
  semantics as today's skip). On confirm it completes the parts one after another through the EXISTING deliver route
  (`/api/remittance-operations/{id}/deliver`), never a new completion path. A part that fails shows its real refusal
  reason (delivery-refusal.ts) and can be finished from the sheet; completed parts stay completed and are not retried.
- Notification: one combined customer message needs a notifier change (n8n workflow `wGud0KGR6eMqqfMQ`), out of scope
  here. For now each part keeps today's per-operation notice when "notify" is on. Say so in the sheet copy only if it
  would otherwise promise a single message.

## Out of scope

DB or migration changes, notifier changes, calculator changes.

## Constraints

- Do not touch the other session's uncommitted files: `pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`,
  `pruebas/decisor/decisor-notas.test.ts`, `odd/tasks/bot-brevedad.md`.
- No real customer data in tests, fixtures or commit messages.
- Panel deploy only with the owner's go-ahead; staging check first.

## TDD

Strict, on. vitest.

## Tasks

- [x] T1 Group card with one "Completar envio" when one deposit pays the whole send. (6210eaa)
- [x] T2 The sheet completes every part through the existing deliver route. (78983d6)
- [ ] T3 Staging check with a PRUEBA mixed send (owner), cleanup; production after go-ahead.

## Progress

- 2026-11-05 created. RDD off.
- 2026-11-05 T1 (6210eaa): "one deposit" = exactly one distinct consumed unvoided TransID across the members' prefetched
  `receiptsByOperationId[].consumedDeposits` (the deposit sits on the anchor's deal; other members list none). A member
  without receipts, not ready, or history keeps the per-part buttons. RED: 4 completableGroup + 1 panel test failed first.
  Forced-verification branch NOT done: the audit is not in the panel's data (needs an endpoint or RPC change).
- 2026-11-05 T2 (78983d6): sheet drives one `CompleteTransferContainer` per part (group mode) and calls its `submit` in order;
  stops at the first part that does not deliver, shows its refusal in that part, done parts are not called again.
  Sheet tests were written after the driver (no separate RED for them); the panel-open test was RED first.
  Verification: vitest inbox+lib 758 passed; full 272 files / 3768 passed; tsc clean; eslint clean.
  curl :3100/inbox returned 000 (staging dev server not running; not started).
