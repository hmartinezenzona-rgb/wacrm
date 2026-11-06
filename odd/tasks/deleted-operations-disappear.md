# Deleted operations disappear from the panel

## Problem (production, 2026-11-06)

Conversation of a customer who overpaid: the bot created a Zelle operation 5a20c482 for the money returned; an admin
deleted it at 15:19:28 UTC (`crm_eliminar_operacion` 200, audit `human_operation_deleted`). The card did not vanish at
once and then showed in "Historial" as cancelled; a second delete 8 s later got a 400 ("an operation that is cancelled
cannot be deleted") shown as a generic error, so the team believed deleting did not work.

## Owner decision

2026-11-06: deleted operations must disappear from the panel ("desaparecer"), not stay in Historial.

## Scope

- T1 The chat operations panel never shows an operation deleted from the panel: an operation whose latest status change
  to `cancelled` is a `remittance_admin_audit` row with action `human_operation_deleted`. Other cancelled operations
  (corrections, merges, bot cancellations) keep showing in Historial as today. Do it in the read the panel uses (API
  route / server query); no migration if the existing read can join the audit; if it truly needs a DB function, stop
  and report.
- T2 Deleting: on success the card is removed at once (optimistic, before the refetch) and a toast says
  "Operacion eliminada". A refused delete shows the real reason in Spanish (map `crm_eliminar_operacion` messages:
  already cancelled/completed -> "Esta operacion ya estaba eliminada o cerrada", verified deposit -> "No se puede eliminar:
  tiene un deposito verificado", not owner/admin -> "Solo un administrador puede eliminar operaciones"), like
  `delivery-refusal.ts` does for deliveries.

## Constraints

- Do not touch `pruebas/decisor/*` or `odd/tasks/bot-brevedad.md` (another session's uncommitted files).
- No real customer data in tests or commits. Panel deploy only with the owner's go-ahead.

## TDD

Strict, on. vitest.

## Tasks

- [ ] T1 Deleted operations are not listed.
- [ ] T2 Instant removal, toast and clear refusal messages.
- [ ] T3 Production panel deploy after the owner's go-ahead.

## Progress

- 2026-11-06 created. RDD off.
