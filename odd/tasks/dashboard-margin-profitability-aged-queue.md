# Dashboard: real margin %, per-service profitability table, aged-operations queue

## Objective
Ship the three Phase-1 items from the Perplexity-assisted redesign the user
validated: a real margin percentage, a per-service profitability table, and a
queue of stuck/aged in-flight operations — all three chosen because they're
buildable from data that already exists, with no new business process.

## Origin / decisions carried over
The user brought a Perplexity redesign proposal into this session. Its Phase 1
was verified against this codebase before accepting it (not taken at face
value): `created_at`/`updated_at` on `remittance_operations` do exist (Phase 2
material is actually usable now, not conditional); no status-transition-history
table exists (Perplexity's Phase 3 caveat holds). Two of its claims were
corrected and are binding constraints here:
- **No service/delivery_method mapping layer needed.** `remittance_calculator_entries.service`
  is computed by `calculator_service_for_operation(delivery_method)` inside
  `calculator_feed_operation()` (migration 104) — always consistent by
  construction, never two independent sources to reconcile.
- **Delivery-evidence rate is explicitly OUT of this task.** Grepped `src/` for
  `delivery_proof_wamid`/`delivery_proof_path` — neither is read or written
  anywhere in the app. That metric would show 0%/null today; building it
  needs a proof-capture feature first, which is a separate, unauthorized
  product decision.

## Scope

### T1 — Real margin % (no new query)
Add `margenPct = retornoGyd / facturadoGyd * 100` (→ `null` when
`facturadoGyd === 0`, rendered as "—", never `NaN`/`Infinity`) to:
- `BusinessSnapshotHero` (today), as a 5th `MetricCard`.
- `LedgerProfitSummary` (today/week/month tabs), as a 5th `Tile`.
No new fetch — both already have `facturadoGyd`/`retornoGyd` in
`LedgerProfitBucket`. No status color on this tile: no baseline exists yet to
call a given margin "good" or "bad" (matches the "don't color without a
reason" rule from this session's earlier color pass, and Perplexity's own
"start with observation thresholds, not rigid rules").

### T2 — Per-service profitability table (no new query)
New pure function `serviceProfitabilityFrom(entries: LedgerEntry[]):
ServiceProfitabilityRow[]` (new file `src/lib/dashboard/service-profitability.ts`,
same pattern as `business-insights.ts`): groups by `entry.service` (CUP,
ZELLE, CLASICA, TROPICAL — the ledger's taxonomy, not
`remittance_operations.service_type`), `status === 'completed'` only, computing
per service: `operationCount`, `facturadoGyd`, `retornoGyd`, `margenPct`
(`null` on zero facturado), `ticketMedioGyd` (`facturadoGyd / operationCount`).
Sort by `retornoGyd` descending. Test-first (RED then GREEN) in
`service-profitability.test.ts`, mirroring `business-insights.test.ts`'s
structure.

`loadLedgerProfit` (in `queries.ts`) computes this from the SAME `entries` it
already fetches this month — no new round trip — and includes it in its
returned object (`LedgerProfitData.serviceProfitability`).

New component `src/components/dashboard/service-profitability-table.tsx`: one
row per service, columns operaciones/facturado/ganancia/margen %/ticket medio,
following this dashboard's existing table-ish list conventions
(`business-insights.tsx`'s rows). Reuses `CURRENCY_COLORS`-style fixed
identity is NOT needed here (service, not currency) — a plain table, no color
per Perplexity's own point that a sortable table beats a donut for this
comparison.

### T3 — Aged / stuck operations queue (NEW migration + RPC — needs a DB apply step)
`remittance_operations` has no client-usable RLS SELECT policy (confirmed:
`grep` found no `CREATE POLICY ... remittance_operations` in
`supabase/migrations/`, and migration 118's own comment documents this: "RLS
with no policies for authenticated"). Every other widget touching this table
goes through a `SECURITY DEFINER` RPC (116, 117, 118) — this needs one more,
following that exact established pattern.

New migration `supabase/migrations/119_dashboard_aged_operations_rpc.sql` +
`ROLLBACK-119-dashboard-aged-operations-rpc.sql` (mirror 118's structure/WHY-comment
style): RPC `cerebro_dashboard_operaciones_envejecidas()` returning, for every
row with `status` in the six non-terminal stages (same list as 118's funnel —
`collecting_information`, `awaiting_deposit`, `deposit_received`,
`deposit_verification`, `ready_to_transfer`, `transferring`): `id`,
`conversation_id`, `contact_name` (LEFT JOIN `contacts` on
`remittance_operations.contact_id`, nullable), `delivery_method`,
`quoted_source_amount`, `status`, `created_at` — ordered by `created_at` ASC
(oldest/most-stuck first), `LIMIT 20`. No `account_id` filter, matching 118's
documented reasoning (this subsystem has no account-scoped access anywhere in
it — confirmed again, not assumed, by that same migration's own comment).
`GRANT EXECUTE ... TO authenticated`.

**This migration has to be manually applied to the live `wacrm-staging`
Supabase project (`kolppplawzdsjfydwejr`) the same way this session's test-data
seed was: the assistant has read-only MCP access to that project (confirmed
earlier this session), not write access, and there is no `psql`/DB write
credential available locally. The user pastes the migration SQL into the
Supabase SQL editor themselves — flag this clearly when T3 is ready, do not
silently skip it or assume it applied.**

New type `AgedOperation` in `types.ts`. New `loadAgedOperations(db)` in
`queries.ts` (`db.rpc('cerebro_dashboard_operaciones_envejecidas')`, mapping
`delivery_method` → display service label the same way the rest of the
dashboard already does). New component
`src/components/dashboard/aged-operations-queue.tsx`: one row per operation —
cliente (`contact_name` or a fallback label, this RPC has no phone to fall
back to), servicio, monto (GYD, `formatCurrencyShort`), estado, antigüedad
(new small pure humanizer — check `date-utils.ts` first for anything reusable
before adding one), and an "Abrir chat" link to `/inbox?c=${conversation_id}`
(verified deep-link param: `src/app/(dashboard)/inbox/page.tsx` reads
`searchParams.get("c")`). Empty state when the RPC returns zero rows (nothing
stuck — a genuinely good state, say so).

## Wiring (page.tsx)
- `BusinessSnapshotHero`: 5th tile (T1), same fetch (`ledgerProfit`).
- `AgedOperationsQueue`: new state/loading, new fetch, placed right after
  `BusinessSnapshotHero` and before `QuickActions` — this is the "needs
  action now" section, so it goes first, before anything else, matching why
  the business snapshot itself got promoted to the top earlier this session.
- `ServiceProfitabilityTable`: reuses `ledgerProfit`/`ledgerProfitLoading`
  (T2, no new fetch), rendered near `LedgerProfitSummary`/`BusinessInsights`.
- `messages/en.json`: new keys for all three additions.

## TDD mode
Strict TDD (global rule). Runner: vitest. T1/T2's margin math and
`serviceProfitabilityFrom` are pure and testable — test-first, real RED then
GREEN, same as `business-insights.ts`'s precedent this session. T3's RPC/query
glue and the new duration humanizer: if the humanizer is genuinely pure
(elapsed-ms → label), test it the same way; the RPC-backed `loadAgedOperations`
itself follows the established precedent of no test coverage for
Supabase-touching `loadX` functions (no mock pattern exists in this repo).

## Acceptance criteria
- Margin % shows on both the hero and the ledger-profit tabs, reads "—" (not
  NaN/Infinity) at zero facturado, no new fetch added.
- Service profitability table shows one row per ledger `service` with
  operations/facturado/ganancia/margen %/ticket medio, sorted by ganancia
  descending, no new fetch added.
- Aged-operations queue shows the oldest non-terminal operations with a
  working `/inbox?c=...` deep link, or an explicit empty state at zero.
- `serviceProfitabilityFrom` (and the duration humanizer, if pure) have
  RED-then-GREEN unit tests.
- `tsc --noEmit`, `eslint` on changed files, `npm run build`, `npx vitest run`
  all pass (2 pre-existing unrelated `date-utils.test.ts` failures OK).
- The new migration file exists in the repo and is committed; its actual
  application to staging is called out explicitly as a pending manual step
  for the user, not silently assumed done.

## Tasks
- [x] T1 — Margin % on hero + ledger-profit tiles
- [x] T2 — `serviceProfitabilityFrom` (test-first) + `loadLedgerProfit` extension + table component
- [x] T3 — Migration 119 + rollback + `loadAgedOperations` + queue component + page wiring
- [x] T4 — i18n keys for all three
- [x] T5 — Verification (tsc/eslint/vitest/build) + local commit

## Progress
All five tasks implemented on branch `feat/dashboard-margin-profitability-aged-queue`
(off `feat/dashboard-business-snapshot-top-clients`), in the
`mejora-legacy` worktree.

- **T1**: `computeMarginPct` (new, in `service-profitability.ts`, test-first)
  used by `BusinessSnapshotHero` (5th `MetricCard`, no tone) and
  `LedgerProfitSummary` (5th `Tile`, no tone). Both grids widened from
  4 to 5 columns (`sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-5` /
  `sm:grid-cols-3 lg:grid-cols-5`). No new fetch.
- **T2**: `serviceProfitabilityFrom` in new
  `src/lib/dashboard/service-profitability.ts`, test-first
  (`service-profitability.test.ts`, RED confirmed before the module
  existed, then GREEN — 8 tests). `loadLedgerProfit` now returns
  `serviceProfitability` from the same fetched `entries`, no new query.
  New `src/components/dashboard/service-profitability-table.tsx`
  (shared `Table` primitives, no color).
- **T3**: new `supabase/migrations/119_dashboard_aged_operations_rpc.sql`
  + its `ROLLBACK-119-...sql`, mirroring 118's structure. New
  `AgedOperation` type, `loadAgedOperations` in `queries.ts`, new
  `src/components/dashboard/aged-operations-queue.tsx` (own fetch/state,
  wired right after `BusinessSnapshotHero` and before `QuickActions`).
  New pure `humanizeAge` in `date-utils.ts`, test-first (RED confirmed,
  then GREEN — 5 tests) since nothing reusable existed there already.
  **Migration 119 is a new file only — NOT applied to any live
  database.** This environment has no DB write access; the user must
  paste its SQL into the Supabase SQL editor for `wacrm-staging`
  (`kolppplawzdsjfydwejr`) manually.
- **T4**: `messages/en.json` — `margen` added to `ledgerProfit` and
  `businessSnapshot`; new `serviceProfitability` and `agedOperations`
  sections.
- **T5**: `npx vitest run src/lib/dashboard/service-profitability.test.ts`
  RED (module missing) then GREEN (8/8). `npx vitest run` full suite:
  1464 passed, 2 failed — the same 2 pre-existing unrelated
  `date-utils.test.ts` `mondayIndex` failures noted in the task brief
  (baseline was 1451/1453; +13 new tests = 1464/1466, no new failures).
  `npx tsc --noEmit` clean. `npx eslint` on every changed/created file:
  clean. `npm run build`: exit 0, no errors.

## Next step
Local commit made on this branch. No push, no PR, no deploy, no DB
write attempted (none possible from this environment). The user still
needs to: (1) manually apply migration 119's SQL to the live
`wacrm-staging` Supabase project via its SQL editor, and (2) decide
when to push/open a PR for this branch.
