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

- [x] T1 Deleted operations are not listed. Owner 2026-11-06: "si, haz la migracion para ocultar las eliminadas" -> migration 354: `crm_historial_operaciones` and `crm_historial_estados` (351) exclude operations whose latest audit with after.status = cancelled is `human_operation_deleted` (rows, totals, counts and pagination stay consistent). Staging first; production after go-ahead.
- [x] T2 Instant removal, toast and clear refusal messages. RED observed (7 failing), then GREEN.
- [ ] T3 Production panel deploy after the owner's go-ahead.

## Progress

- 2026-11-06 created. RDD off.
- 2026-11-06 T1 finding: the chat panel never lists cancelled operations. `crm_operaciones_de_conversacion` (migration
  271) returns open ones (`status NOT IN ('completed','cancelled')`) and only `completed` history, so there is nothing
  to filter in the panel. The "Historial" the owner saw is Finanzas > Operaciones (`crm_historial_operaciones`, migration
  351), whose rows, totals and status-group counts are computed in the DB function with server-side pagination; hiding
  deleted operations there needs a DB change (a migration), or a route post-filter that would break totals and counts.
  Stopped per the task rule; not implemented. What the team saw in the panel (card lingering after delete) was the
  stale card until the refetch, fixed by T2.
- 2026-11-06 T2 done: `delete-refusal.ts` (`parseDeleteRefusal`) maps the RPC/role-gate refusals to
  `Inbox.operationsPanel.closing.deleteRefusal.*` (es/en); `OperationClosingControl` shows the mapped text or the
  server text; the card calls the new `onDeleted(id)` before `onChanged`; the container drops the card from state and
  toasts `closing.deleted`. Checks: vitest on inbox + remittance-operations + api 66 files / 1079 passed; full vitest
  275 files / 3818 passed; tsc clean; eslint clean on changed files.
- 2026-11-06 T1 done on staging (production pending the owner's go-ahead): migration 354 redefines
  `crm_historial_operaciones` and `crm_historial_estados`; `base` excludes status = 'cancelled' operations whose latest
  `remittance_admin_audit` row (table_name 'remittance_operations', row_id = op id, after->>'status' = 'cancelled') has
  action `human_operation_deleted`. Assertion `historial-oculta-eliminadas.sql`: RED before (case 1, 2 rows), GREEN after.
  `staging-migracion.sh aplicar`: dry-run/apply/assertion/rollback OK (md5 equal to previous). `relacionadas crm_historial`
  with `--ya-aplicada`: historial-busqueda SAME (ALL PASS), new assertion DIFF (base fails, mig passes), as intended.
