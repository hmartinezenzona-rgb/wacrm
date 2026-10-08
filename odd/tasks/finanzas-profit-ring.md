# Feature: profit-by-service ring in the Finanzas financial close

## Objective
A ring chart in "Cierre financiero" (Finanzas) showing PROFIT (`retorno_gyd`) BY SERVICE for the selected period.

## Owner request (2026-10-07)
The owner misses the dashboard's ring chart and wants one in Finanzas to understand the business at a glance.
Decided with him: the ring shows profit ("ganancia" = `retornoGyd`) by service for the period picked in the close.

## Scope
IN: card "Ganancia por servicio" (es) with ring + legend (name, profit in GYD, share %), centre = total profit.
Fed by `close.byService` (same data object, no extra RPC). Placed right under the by-day / by-service row, ADD only.
OUT: database changes, restyling or reordering anything existing, the dashboard donut (output unchanged).

## Decisions
- Pure slice math in `src/lib/financial-close/profit-ring.ts`; percentages are of the sum of POSITIVE profits.
- Slices sorted by profit descending; zero profit: legend row with 0, no slice; negative: legend row with the negative
  figure, no slice, share "—"; positive total <= 0: no ring, legend only; no operations: empty state, no ring.
- Money via `fmtGyd`; service names via `ledgerServiceLabel`; colours `--chart-1..5`, cycling with reduced opacity after 5.
- Ring drawing copied from the dashboard `Donut` approach (new component; dashboard file untouched).

## TDD
Mode: strict TDD on. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [x] P1 pure `buildProfitRing` + unit tests (RED, GREEN)
- [x] P2 `FinancialCloseProfitRing` component + tests for every edge case
- [x] P3 wire into `FinancialCloseSummary` + es/en strings (parity test)
- [x] P4 full verification (vitest, tsc, eslint)

## Evidence
- P1 RED: profit-ring.test.ts failed (module missing); GREEN 7/7.
- P2 RED: ring test failed (module missing); GREEN 9/9 (after correcting my own fmtGyd expectations: fmtGyd drops trailing zeros).
- P3 RED: section test failed on ring rows; GREEN. Card sits as a full-width row at the end of the by-day/by-service grid, only when the period has operations.
- P4 full vitest 176 files / 2320 tests pass; tsc --noEmit clean; eslint clean on changed files.

## Open points
- With zero operations the existing empty message is shown and the card is not added (it would repeat it). The component itself handles an empty list.
- Only 5 chart tokens exist; services 6+ reuse them at 55% opacity (legend carries names).
