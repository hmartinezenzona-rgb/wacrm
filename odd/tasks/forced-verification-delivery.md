# An admin's forced verification counts as funded; the panel says why a delivery is refused

## Problem (production, 2026-10-29)

- Operation f370a1d4 (recarga, 6,200 GYD) was force-verified by an admin at 17:48 UTC (audit
  `human_forced_verification`) and moved to `ready_to_transfer`, but has no MMG deposit linked.
- `crm_entregar_operacion` (migration 329 rule) refuses delivery unless `cerebro_fondos_operacion(op).cubierto`:
  "the operation has 0 GYD of verified funding but needs 6200 GYD". PostgREST returned 400 at 18:04-18:25 UTC.
- The panel (`src/components/inbox/operations/complete-transfer-container.tsx`, stage-failed branch) shows the generic
  "La captura se envió pero la operación no pudo completarse. Reintenta para terminar." Retrying can never work.

## Owner decision

2026-10-29: "corrige el mensaje del panel ... igual forzar una verificacion de pago debe darse por buena porque lo hace
un admin".

## Scope

- T1 Migration 352: in `crm_entregar_operacion`, the funding gate passes when the operation (or, for a mixed group,
  every operation the gate checks) has an admin forced verification: a `remittance_admin_audit` row with action
  `human_forced_verification` for that operation that is the latest verification event (a later return to an earlier
  status must not keep it valid; decide from the live data and the force-verify route, document the rule). Every other
  gate (beneficiaries, funding-case incident, recipients sum, delivery proofs, source amount > 0) stays. Do NOT change
  `cerebro_fondos_operacion` (the bot's balance uses it). Read the live body with `pg_get_functiondef` first. ROLLBACK
  file and a self-reverting staging assertion. Staging only; production apply needs the owner's go-ahead.
- T2 Panel: when the deliver route is refused with a reason (RPC 22023 messages mapped by `rpcErrorResponse`), the
  completion banner shows that reason in plain Spanish (for example "Falta verificar el deposito: tiene 0 de 6,200 GYD"
  / "Faltan los comprobantes de N beneficiarios" / "Los beneficiarios suman X pero la operacion envia Y"), and offers
  retry only when retrying can help (network/unknown errors). Map the known RPC messages; unknown ones show the server
  text. Same for the other two stage-failed paths in that file.

## Constraints

- Do not touch the other session's uncommitted files: `pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`,
  `pruebas/decisor/decisor-notas.test.ts`, `odd/tasks/bot-brevedad.md`.
- No real customer data (names, phones, cards) in tests, fixtures or commit messages.
- Panel deploy and production migration only with the owner's go-ahead.

## TDD

Strict, on. vitest for the panel; the staging assertion for SQL (RED before the migration).

## Tasks

- [x] T1 Migration 352 (staging): forced verification counts as funded. Evidence: assertion RED before (b failed, 7 expectations), then `staging-migracion.sh aplicar` dry-run/apply/assertion OK, rollback OK (md5 equal); `relacionadas` 100 assertions, 98 SAME, 2 DIFF (the new assertion, expected; delivery-feed-evidence differs only by a uuid in a pre-existing fixture error).
- [x] T2 Panel shows the real refusal reason. Evidence: container tests RED then GREEN; `delivery-refusal.ts` maps the 22023 messages; refusals (HTTP 400) show the reason without Retry; network/5xx keep Retry. vitest full 271 files / 3755 passed, tsc clean, eslint clean.
- [x] T3 Production 2026-10-29, owner go-ahead ("si, aplica la 352 y publica el panel"): previa SEGURO; 352 applied (20261029184505), verificar 1/1 EQUAL; panel release/prod-forzada = 1171d33 (pushed to privado), BUILD_ID -x45sdVm7G9luHcjQtjIR, rollback target 55847a1. Smoke: /login 200, /finanzas and /inbox 307 to login.

## Progress

- 2026-10-29 created. RDD off.
- 2026-10-29 T1+T2 done on staging/branch. Rule: when deposits do not cover the scope, delivery passes if every operation in the scope (the op, or every non-cancelled mixed-group member) has a `human_forced_verification` audit not superseded by a later `human_deposit_verification` or a later audit whose after.status is deposit_verification/incident/cancelled. Multi-beneficiary stage-failed path shares the refusal banner (no dedicated test).
- Done. Open: whether one forced op is enough in a mixed send (owner); MMG payment requests leave no deposit row (owner question).
