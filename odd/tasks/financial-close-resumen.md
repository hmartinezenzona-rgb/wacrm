# Financial close on /resumen

## Objective
Turn `/resumen` into the business's financial close: what the business billed,
invested and earned, from the calculator ledger, queryable by day, week, month
or custom range, broken down visually and auditable down to each operation.

## Problem / why
- `/resumen` only shows volume (operation count, GYD in) from `remittance_operations`,
  in 5 fixed periods. No profit.
- Money figures live in `remittance_calculator_entries` (fed on completion, migration 104)
  and only appear on `/dashboard` in 3 fixed buckets computed in the browser.
- Day boundaries follow the viewer's browser timezone; `entry_date` is the UTC date of
  `completed_at`. A close needs the business day (America/Guyana).

## Scope (accepted by the user 2026-09-25, target: Sunday 2026-09-27 cutover)
1. Period selector: day, week (Mon–Sun), month, custom range. Business day = America/Guyana.
2. Period totals: facturado, invertido, retorno (GYD), operation count.
3. Breakdown by service and by day inside the period.
4. Auditable detail: each ledger entry in the period (customer, service, amount,
   rate/rate version, delivered by, delivery mode, operation id). Voided entries and
   entries pending a rate (`verified_pending`) listed separately, never in totals.
5. CSV export of the detail.

Out of scope (later): period lock/close, business expenses, historical backfill
(the production ledger starts empty on the cutover, by design).

## Constraints
- Totals count `source = 'completed_operation'` AND `status = 'completed'` only, same rule as
  `/dashboard` (`loadLedgerProfit`).
- Grouping by `(completed_at AT TIME ZONE 'America/Guyana')::date`, not `entry_date`.
- Read access: account members only (the ledger's RLS / `is_account_member`), SECURITY
  DEFINER RPC scoped by account like the ledger policy.
- New migration `121_financial_close_rpc.sql` + ROLLBACK file; joins Sunday's migration series.
- Existing `/resumen` volume and history sections must keep working (keep or move below).

## Tasks
- [x] T1 — Migration 121: RPC(s) returning totals, per-service, per-day and detail for a
  date range in Guyana days. SQL assertions in a rolled-back transaction on staging.
  - `crm_cierre_financiero(p_desde date, p_hasta date) → jsonb` (totales, por_servicio,
    por_dia with every day, detalle, excluidas), SECURITY DEFINER, `is_account_member`
    (viewer, same as the ledger policy 106), actor_name from profiles.
  - Process note: a delegated writer wrote the migration BEFORE the test (then lost its
    connection twice); the parent wrote `supabase/staging/assertions/financial-close.sql`.
    RED observed with the assertions alone (function missing). First GREEN run failed on a
    real bug: a pending row without completed_at fell on the previous Guyana day
    (entry_date::timestamptz → 20:00 GY the day before). Fixed to
    `coalesce((completed_at AT TIME ZONE 'America/Guyana')::date, entry_date)`; ALL PASSED.
  - ROLLBACK file verified (drops the function). Staging untouched (all runs rolled back).
  - Commit `96c6d74`.
- [x] T2 — TS read model + data loader (`src/lib/...`) with vitest tests.
  - `src/lib/financial-close/{periods,read-model,load}.ts` + tests. RED (modules missing)
    → GREEN 15/15; also green under TZ=Pacific/Kiritimati and America/Los_Angeles
    (period math runs on UTC midnights; "today" via Intl in America/Guyana).
  - tsc and eslint clean. Written inline by the parent (delegated writers kept dropping). Commit `c1c186e`.
- [x] T3 — `/resumen` UI: period selector, totals, breakdowns, detail, voided/pending section.
  - `src/components/resumen/financial-close-{section,period-picker,summary,detail,format}` +
    section test; wired at the top of `/resumen` (volume and history unchanged below).
    Texts in Spanish under `Resumen.cierre` in messages/en.json (page convention).
  - Per-day chart: Tremor BarChart, Facturado vs Retorno on one GYD axis; palette blue/pink
    validated with dataviz validate_palette.js in light and dark (emerald failed dark).
  - RED (module missing) → GREEN 5/5. Lint forbade setState in effects: result keyed by
    request, picker remounted by `key`. Commit `57efb25`.
- [x] T4 — CSV export of the period detail.
  - `src/lib/financial-close/csv.ts` (+test): BOM, raw numbers, Guyana time, completed then
    excluded rows with state, CSV-injection guard on text cells. Export button in the section
    header, hidden when the period is empty. RED → GREEN; module 29/29; full suite only the 2
    known date-utils failures. Commit `b85e160`.
- [x] T5 — Apply 121 to staging, deploy, live check with the user; add 121 to the cutover list.
  - 2026-09-25 (user OK): 121 applied to staging in one transaction + registered in
    supabase_migrations (version 20260925214120). Verified as the user: week 2026-09-14..20
    returns the one real ledger entry (75,000 facturado, 1 detail row).
  - Pushed b85e160 to privado; staging serves b85e160 (pm2 cwd verified, /login 200).
    Rollback target 2899d94. First scp dropped (connection closed) — nothing activated; retried OK.
  - User review: raw ISO dates hard to read; could navigate into the future. Fix (TDD, RED 5 →
    GREEN 34/34, TZ-independent): `periodLabel` ("Semana del 21 al 27 sep 2026", "septiembre
    2026"…), `shortDayLabel` for the chart, `canShiftForward` disables Next once the next
    period starts after today (Guyana), custom range ending after today refused (`future`).
    Commit `44fb949`, pushed, staging serves 44fb949.
  - User review 2: history page size "does nothing" — verified working; staging has only 4
    ops, so 25/50/100 look identical (prod ~556 ops will paginate). Beneficiary/card only
    apply to remittances (prod: 537 remesa, 19 recarga, other services unused so far but kept
    in the filter per the user). Merged into one "Destino" column via
    `src/lib/resumen/historial-destino.ts` (+test, RED → GREEN 4/4). Limitation: RPC 088 only
    returns name + masked card, so Zelle/Clásica show the name alone (showing the type/account
    would need a new migration; deferred past Sunday). Commit `f0fe0e3`, staging serves it.
  - 2026-09-25: user confirmed on staging ("sí así me sirve"). 121 noted for the Sunday
    migration series (after 120), Engram `project/production-cutover-2026-09-27/migration-121`.

## Acceptance criteria
- Any day/week/month/range returns the same totals as summing its ledger rows by hand.
- An operation completed at 20:30 Guyana counts on that Guyana day.
- Voided and pending entries never change totals and are visible in their section.
- CSV has one row per detail entry with the same numbers as the screen.

## Checks
- TDD: strict (global rule). TS runner `npx vitest run`; SQL via staging assertion
  script in a transaction with ROLLBACK. `npx tsc --noEmit`, `npx eslint` on touched files.
- Known environmental failures: `src/lib/dashboard/date-utils.test.ts` mondayIndex (2 tests,
  timezone-dependent, pre-existing).

## Delivery
Work-unit commits on `feat/port-chat-operations-calculator` (pushed to `privado`), deployed
to staging, shipped with the Sunday cutover. No separate PR (existing practice for this branch).

## Progress
- 2026-09-25: document created after exploration.
- 2026-09-25: T1 done (96c6d74). Next: T2 TS read model + loader.
- 2026-09-25: T2 done. Next: T3 UI.
- 2026-09-25: T3 (57efb25) and T4 (b85e160) done. Next: T5 staging (needs user OK to apply 121 + deploy).
- 2026-09-25: feature complete on staging (f0fe0e3). Ships with the Sunday cutover.
