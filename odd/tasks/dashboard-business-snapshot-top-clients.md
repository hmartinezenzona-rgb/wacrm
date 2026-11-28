# Dashboard: business snapshot hero + top clients / destination breakdown

## Objective
Make the dashboard answer "how is the business doing" at a glance, and surface
who/where the business actually comes from.

## Problem / why
User feedback (2026-09-24): looking at the dashboard "doesn't tell me anything"
about the business. Root cause verified in code: the four hero `MetricCard`s at
the very top of `src/app/(dashboard)/dashboard/page.tsx` are chat/CRM metrics
(active conversations, new contacts today, operations in progress, messages
sent today) — not remittance-business metrics. The real money numbers
(`LedgerProfitSummary`: today/week/month operation count, facturado, invertido,
retorno) already exist but sit three sections below the fold, behind a tab.
There is also no widget answering "who are my top clients" or "which
destination currencies move the most volume", even though
`remittance_calculator_entries` already carries `customer_name` and
`amount_currency` per completed entry.

## Scope
1. Promote a "today" business snapshot to the very top of the dashboard,
   above the existing chat/CRM metric cards, reusing `ledgerProfit.today`
   (no new query for this part).
2. Add a new "top clients / destination currency" widget fed by one new
   query, `loadBusinessInsights`, built on the same
   `remittance_calculator_entries` read path as `loadLedgerProfit`.

## Out of scope (explicitly deferred, not part of this task)
- "Time in stage" for the operations funnel, priority queue widget — both
  already deferred from a prior session, untouched here.
- Any change to `remittance_operations` RLS/RPCs, any new migration.
- Multi-currency default-currency handling beyond what `ServiceVolumeDonut`/
  `LedgerProfitSummary` already do (ledger amounts stay GYD-denominated
  except the new destination-currency breakdown, which is about
  `amount_currency`, the client's requested currency, not GYD).

## Branch
`feat/dashboard-business-snapshot-top-clients`, based on
`feat/dashboard-ledger-profit` (tip of the still-unmerged #46→#47→#48 chain),
continuing the same chained-PR pattern as the prior session.

## TDD mode
Strict TDD (global rule, `~/.claude/CLAUDE.md`). Runner: vitest (`npx vitest
run <file>` / `npm test`). Precedent in this codebase
(`odd/tasks/dashboard-service-volume-widget.md`): Supabase-touching `loadX`
functions in `src/lib/dashboard/queries.ts` have no existing test coverage
pattern and are not unit-tested (would need a Supabase client mock this repo
doesn't otherwise use) — that precedent holds here too for `loadBusinessInsights`'s
fetch. What IS new and genuinely pure/testable this time: the client and
destination aggregation logic, extracted as standalone functions so they get
real RED/GREEN coverage instead of being skipped.

## Tasks

- [x] **T1 — Pure aggregation logic, test-first**
  New file `src/lib/dashboard/business-insights.ts`: `topClientsFrom(entries,
  limit = 5)` and `destinationBreakdownFrom(entries)`, operating on
  `LedgerEntry[]` (from `@/lib/calculator/ledger-read-model`), mirroring
  `ledgerTotals()`'s convention (only `status === 'completed'` counts).
  New test file `src/lib/dashboard/business-insights.test.ts`: RED first
  (write failing tests for grouping, sorting by facturadoGyd desc, the
  `limit` cap, a null `customerName` bucket, and completed-only filtering),
  then implement to GREEN.

- [x] **T2 — Types**
  `src/lib/dashboard/types.ts`: add `TopClientEntry { customerName: string |
  null; operationCount: number; facturadoGyd: number }`,
  `DestinationBreakdownEntry { currency: string; operationCount: number;
  facturadoGyd: number }`, `BusinessInsightsData { topClients:
  TopClientEntry[]; byDestinationCurrency: DestinationBreakdownEntry[] }`.

- [x] **T3 — Query**
  `src/lib/dashboard/queries.ts`: add `loadBusinessInsights(db):
  Promise<BusinessInsightsData>`, fetching this month's
  `remittance_calculator_entries` (`source = 'completed_operation'`, `status
  != 'void'`, `entry_date >= monthStart`) the same way `loadLedgerProfit`
  does, then calling `topClientsFrom`/`destinationBreakdownFrom` from T1.

- [x] **T4 — Hero component**
  New `src/components/dashboard/business-snapshot-hero.tsx`: 4 stat cards —
  remesas hoy (`operationCount`), monto movido hoy (`facturadoGyd`), ganancia
  hoy (`retornoGyd`), invertido hoy (`invertidoGyd`) — reading
  `ledgerProfit.today` (no new fetch). Follows the visual pattern of the
  existing `MetricCard`/`LedgerProfitSummary` components.

- [x] **T5 — Insights component**
  New `src/components/dashboard/business-insights.tsx`: top-clients list
  (name or phone fallback, operation count, facturado) + destination
  currency breakdown (currency, operation count, facturado), reading
  `BusinessInsightsData`. Empty/loading states follow the existing
  `SkeletonCard`/empty-state conventions used by sibling widgets.

- [x] **T6 — Wire into the page**
  `src/app/(dashboard)/dashboard/page.tsx`: move `BusinessSnapshotHero` to
  the very top (above `PageHeader` content or immediately below it, before
  `QuickActions`); move the current 4 chat/CRM `MetricCard`s down to a
  secondary position (after `QuickActions`/`OperationsFunnel`, not deleted —
  still useful, just no longer the first thing seen); add
  `loadBusinessInsights` to the existing `loadAll` loader and render
  `BusinessInsights` near `LedgerProfitSummary`.

- [x] **T7 — i18n**
  `messages/en.json`: new `Dashboard.businessSnapshot.*` and
  `Dashboard.businessInsights.*` keys for both new components (titles,
  empty states, "unknown client" fallback label).

## Acceptance criteria
- Looking at the dashboard with no scrolling shows: remesas hoy, monto
  movido hoy, ganancia hoy, invertido hoy.
- A new widget shows top clients by facturado this month and a destination
  currency breakdown this month.
- `topClientsFrom`/`destinationBreakdownFrom` have RED-then-GREEN unit tests.
- `tsc --noEmit`, `eslint` on changed files, `npm run build`, `npx vitest
  run` all pass (pre-existing 2 `date-utils.test.ts` `mondayIndex` failures
  are known-environmental, not caused by this change).
- Positive-presence checklist run on staging before/after deploy per the
  durable global rule: every previously-shipped dashboard widget (bot
  switch, SLA compliance, operations in progress, service volume donut,
  operations funnel, ledger profit, scroll-fix markers) still present.

## Progress
All tasks T1-T7 implemented and verified locally.

- T1: `src/lib/dashboard/business-insights.ts` (`topClientsFrom`,
  `destinationBreakdownFrom`) with `src/lib/dashboard/business-insights.test.ts`
  (8 tests). RED confirmed first (`Cannot find module './business-insights'`),
  then implemented to GREEN.
- T2: `TopClientEntry`, `DestinationBreakdownEntry`, `BusinessInsightsData`
  added to `src/lib/dashboard/types.ts`.
- T3: `loadBusinessInsights(db)` added to `src/lib/dashboard/queries.ts`,
  same month-start/`entry_date` fetch shape as `loadLedgerProfit`.
- T4: `src/components/dashboard/business-snapshot-hero.tsx` — 4
  `MetricCard`s (remesas/monto movido/ganancia/invertido hoy) reading
  `ledgerProfit.today`, no new fetch.
- T5: `src/components/dashboard/business-insights.tsx` — top clients list
  + destination currency breakdown, `EmptyState`/`Skeleton` conventions,
  `unknownClient` fallback for `customerName === null` (no phone join —
  out of scope per task doc).
- T6: `src/app/(dashboard)/dashboard/page.tsx` — `BusinessSnapshotHero`
  moved to the very top (right below `PageHeader`, before `QuickActions`);
  the 4 chat/CRM `MetricCard`s moved down after `LedgerProfitSummary`/
  `BusinessInsights`, still rendered, no longer first; `loadBusinessInsights`
  wired into `loadAll`; `BusinessInsights` rendered next to
  `LedgerProfitSummary`.
- T7: `messages/en.json` — `Dashboard.businessSnapshot.*` and
  `Dashboard.businessInsights.*` keys added (only locale file in the repo).

Verification (all run locally in
`/home/onlinefreedom/wacrm-worktrees/mejora-legacy`):
- `npx vitest run src/lib/dashboard/business-insights.test.ts`: RED then
  GREEN, 8/8 passing.
- `npx vitest run` (full suite): 1451/1453 passing — same 2 pre-existing
  `date-utils.test.ts` `mondayIndex` failures as baseline (unrelated).
- `npx tsc --noEmit`: clean.
- `npx eslint` on every changed/created file: clean.
- `npm run build`: succeeds.

## Next step
Implementation complete. Commit created on
`feat/dashboard-business-snapshot-top-clients`. No push/PR — per task scope,
delivery remains a separate human decision.
