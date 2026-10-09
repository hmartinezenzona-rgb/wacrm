# Finanzas: the Resumen comes from the ledger, and the rounding leftover is profit

## Objective
The two blocks of the Finanzas page (`src/app/(dashboard)/resumen/page.tsx`) always agree for the same day, and the money a customer deposits that is not
delivered because of whole-unit rounding is counted as the business's profit.

## Problem / why (production, 2026-10-08, verified)
- "Resumen" (five period cards: hoy, ayer, esta semana, este mes, mes pasado) <- RPC `cerebro_dashboard_resumen()` <- view `cerebro_resumen_volumen`
  <- view `cerebro_volumen_diario`: counts OPERATIONS and sums what customers DEPOSITED. Today: 4 operations, 130,100 GYD.
- "Cierre financiero" <- RPC `crm_cierre_financiero(desde, hasta)` <- the calculator ledger `remittance_calculator_entries`: sums FACTURADO.
  Today: 4 operations, 130,060 GYD.
- The 40 GYD: Carlos Sangles deposited 47,100 GYD by Zelle at 260 -> floor(47,100 / 260) = 181 USD delivered; the ledger line bills 181 x 260 = 47,060.
  The 40 GYD stay with the business but appear nowhere (not billed, not profit).
- The gap is much larger on longer periods: the Resumen only knows bot operations, the close also counts MANUAL ledger entries
  (e.g. "ayer" Resumen 0 vs close 191,900).

## Owner decisions (2026-10-08)
1. The Resumen comes from the SAME source as the Cierre (the calculator ledger): both blocks always agree and the Resumen includes manual operations.
2. The rounding leftovers "si deben de contar como ganancia": money deposited and not delivered because of rounding is profit and must show in Finanzas.

## Authorised scope
Repo edits; migrations and assertions on STAGING (kolppplawzdsjfydwejr) only; READ-ONLY SELECTs on production (hqztotshnlzaiziwjyzh). No production write,
no n8n, no ssh, no deploy, no push.

## Design
### Part 1 - migration 234 (`cerebro_dashboard_resumen` from the close)
- Dependency query on staging: `cerebro_resumen_volumen` is read only by `cerebro_dashboard_resumen`; `cerebro_volumen_diario` is read by
  `cerebro_resumen_volumen`, `cerebro_volumen(date,date)` and `cerebro_dashboard_volumen_por_servicio` (a dashboard widget). Nothing app-side reads the views
  directly. Decision: both views stay exactly as they are (the dashboard widgets are untouched); only the function body changes.
- `cerebro_dashboard_resumen()` keeps its name, signature, returned columns and grants. Its body calls `crm_cierre_financiero(desde, hasta)` once per period
  and reads `totales`: `operaciones` = totales.operaciones, `volumen_gyd` = totales.facturado_gyd, `ticket_medio_gyd` = round(facturado / operaciones),
  NULL when 0 (the old view rounded the ticket too). Periods unchanged, in America/Guyana: hoy, ayer, esta semana (Monday -> today), este mes, mes pasado.
  Reusing the close (not re-deriving its WHERE) guarantees the same statuses, exclusions (void, deleted, pending-rate), day attribution and account scoping.
- SECURITY change: the old function was SECURITY DEFINER with NO account filter (any authenticated user saw the operations of every account). The close
  scopes to `is_account_member(account_id)`; since the new body calls the close, the Resumen is scoped identically (members see only their accounts,
  no identity -> zeros, as the close does).
### Part 2 - migration 235 (the ledger bills the deposit)
See "Part 2 analysis" below (filled in during the work).

## TDD
Mode strict, source user global CLAUDE.md. Runners: DB = staging SQL assertion run through docker postgres:17-alpine psql as
`BEGIN; <assertion minus its own BEGIN/ROLLBACK>; ROLLBACK;` (never `psql -1` alone: it can COMMIT a fixture); app = `npx vitest run <files>`
(RED then GREEN), `npx tsc --noEmit`, `npx eslint <changed>`.

## Tasks
- [x] P1.1 Read and compare definitions (repo / staging / production), dependency query
- [x] P1.2 Assertion `resumen-from-ledger.sql` RED on staging
- [x] P1.3 Migration 234 + ROLLBACK-234; apply; GREEN; rollback proof; widgets untouched evidence
- [x] P1.4 Commit part 1
- [ ] P2.1 Per-service analysis of facturado / leftover (below)
- [ ] P2.2 Assertion `ledger-bills-the-deposit.sql` RED
- [ ] P2.3 Migration 235 + ROLLBACK-235; apply; GREEN; rollback proof
- [ ] P2.4 Related ledger assertions re-run, expectations updated deliberately
- [ ] P2.5 Client-side recompute check (src/lib/calculator, components, .txt export)
- [ ] P2.6 Production preview (read-only) and the list of existing lines with a leftover
- [ ] P2.7 Commit part 2

## Evidence
### Part 1 (staging, 2026-10-08)
- Definitions: repo (migration 055 body, 228 close) = staging = production for `cerebro_dashboard_resumen` (md5 84ba499d6e5e0ad876cc0ebc11b1eb28) and
  `crm_cierre_financiero` (c903a47147c04a61b06471061b2e5cff). Drift: view `cerebro_resumen_volumen` md5 differs (staging 9f176ed9..., production 0ba555bd...), only the
  deparser printing `'ayer'::text AS text`; ACL drift: on production `crm_cierre_financiero` has no service_role grant (staging has it). Neither is touched.
- RED: `resumen-from-ledger.sql` failed before 234 (`hoy must equal the close: card 0 operations vs close 2`). 234 applied (`BEGIN; 234; COMMIT;`), assertion GREEN.
- Rollback proof (inside a rolled-back transaction): ROLLBACK-234 restores md5 84ba499d... and the same ACL; after 234 the md5 is 3827c1204e1e3ebd32e9990cf6477a44.
- Widgets untouched: `cerebro_volumen_diario` 6894f74169dd212b375f223a32d0bfa7, `cerebro_resumen_volumen` 9f176ed9ba017e762f42d5423abf17b3, `cerebro_volumen`
  41a41060c9336e7bc97b736625f1b24b, `cerebro_dashboard_volumen_por_servicio` 9369b9f6e5bdc8ca9c41bcb47662f6cd, `crm_cierre_financiero` c903a471... all unchanged after 234.
- Cost: `explain analyze` of the Resumen as a member: 34 ms (five calls of the close).

## Open points
(filled in as the work proceeds)
