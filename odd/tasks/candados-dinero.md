# Phase 1: money guards (funding + recipient sums)

Status: IN PROGRESS (2026-10-26). Objective: no delivery without verified funding, and the
recipients of any rail must add up to what the operation sends (not only Zelle). This is the first
phase of `odd/design/no-service-without-data.md`; it works on the current operation model and its
rules survive the funding case.

## Why

- `crm_entregar_operacion` never checks that the operation (or its mixed group) has verified money.
  A `ready_to_transfer` operation with no consumed deposit can be delivered.
- The 328 sum gate covers Zelle only. Cuban card, Clasica, Tropical, Mexico and cash have the same
  failure mode.
- `cerebro_saldo_operacion` counts only deposits whose `operation_id` is set. A deposit verified by
  the admin typed-TransID path is consumed with `operation_id NULL`; the bot's balance does not see
  it.

## Scope

In scope: the delivery gate, a shared funding helper, the balance function, and the required
regressions. Out of scope: `funding_case`, allocations, the conflict state, panel UX, and the typed-
TransID linking fix (phase 2/3).

## Decisions

- Verified money = a consumed, non-void, non-discarded `depositos_mmg` row in GYD that is either
  linked to the operation/group or (when unlinked) matches a receipt reference of the operation/group.
- Required money = the operation's `quoted_source_amount`, or the sum of the group's non-cancelled
  members.
- Under-funding blocks delivery; over-funding is allowed in phase 1 and stays visible as a negative
  balance.
- The sum gate applies only when every vigente recipient has an amount and all their currencies equal
  the destination currency (both null included). Rails without amounts (recarga, saldo) skip. Zelle
  keeps whole-dollar rounding; other rails compare cents.
- 328 is not applied in production (checked 2026-10-26: `schema_migrations` ends at 327 and the live
  body has no gate). The production bundle is 328 + 329.

## Tasks

- [x] T1. Write the staging assertion with behavioural RED on the current body (no funding gate).
- [x] T2. Migration 329: `cerebro_fondos_operacion`, rewrite `cerebro_saldo_operacion`, add both gates
      to `crm_entregar_operacion`.
- [x] T3. Staging cycle `aplicar` (dry-run, apply, assertion, rollback md5).
- [x] T4. Related regressions for `crm_entregar_operacion`, `cerebro_saldo_operacion` and
      `_repartir_envio_core`.
- [x] T5. Production `previa` over 328 + 329; report differences; wait for the owner's go-ahead.
- [ ] T6. Production `aplicar 328 329` after approval; `verificar`.
- [ ] T7. Update the design's phase status and save the evidence.

## Verification

- Staging: `infra/db/staging-migracion.sh aplicar supabase/migrations/329_candado_fondos_entrega.sql
  supabase/staging/assertions/candado-fondos-entrega.sql
  supabase/migrations/ROLLBACK-329-candado-fondos-entrega.sql cerebro_fondos_operacion,cerebro_saldo_operacion,crm_entregar_operacion`
- Regression: `infra/db/staging-migracion.sh relacionadas <mig> 'crm_entregar_operacion|cerebro_saldo_operacion|_repartir_envio_core'`
- Production: `previa` → `aplicar` → `verificar`.
- TDD mode: enabled (global `Strict TDD Mode: enabled`); runner: the SQL assertion above. RED is the
  assertion failing on the current body; GREEN is `ALL PASS` after 329.

## Evidence

- Production measurements 2026-10-26 (120 days): 162 completed, 154 funded by their own deposit, 11
  by the group's; 2 completed with receipts but no verified deposit (one receipt reference differs
  from the real TransID by one digit; neither would pass the new gate). Recipient sums per rail: all
  match except 1 legacy Zelle (the Yoandrys case).
- 328 is absent from production (`schema_migrations` ends at 327; live body has no Zelle gate).
- T1 RED (2026-10-26): the assertion on the staging base ended with
  `case 1: delivered without verified funding`.
- T3 (2026-10-26): `dry-run OK`, `apply OK`, `assertion OK`, `rollback OK (md5 igual al previo)`.
- T4 (2026-10-26): `relacionadas` → 17 SAME, 1 DIFF. The DIFF is `delivery-feed-evidence`, which
  already fails on the base during fixture setup (no operation created for the deal); it is not
  caused by 329. Fixtures in `beneficiary-proofs`, `candado-zelle-entrega`, `cup-source-card`,
  `cutover` and `panel-notify-and-cash-name` now add the verified deposit their delivery needs.
- T5 (2026-10-26): `produccion-migracion.sh previa 328 329` → `VEREDICTO: SEGURO`;
  `cerebro_saldo_operacion` and `crm_entregar_operacion` EQUAL against the staging pre-bundle state,
  `cerebro_fondos_operacion` NEW. Awaiting the owner's explicit go-ahead to apply.
