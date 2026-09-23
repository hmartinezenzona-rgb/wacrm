# Replace the dashboard's pipeline donut with a service-volume donut

## Objective
Where the dashboard used to show open-deal value by pipeline stage (removed in `4100a65`/PR #44 — the pipelines management UI no longer exists), show today's remittance volume (GYD) broken down by `service_type` instead. Financial, informative, not action-oriented — deliberately NOT the "operations needing attention" panel considered and rejected in this conversation.

## Why
User explicitly wants financial information in that spot, and noted `/resumen` may eventually be retired in favor of `/dashboard` absorbing its function — so surfacing real remittance volume here now, using the same underlying data `/resumen` already reports from, is a small step in that direction without attempting the full merge yet.

## Grounded facts (verified this session, do not re-derive)
- `remittance_operations.service_type` real domain (migration 046 CHECK constraint): `remesa`, `combo`, `recarga`, `visa`, `traduccion`, `mexico`.
- View `cerebro_volumen_diario` already exists on the real DB (confirmed via `\d` on staging) with exactly the needed shape: `dia date, service_type text, operaciones bigint, volumen_gyd numeric, ticket_medio_gyd numeric`. No new aggregation logic needed — just expose today's rows safely.
- `remittance_operations` has RLS enabled with **no policies** — a direct client `SELECT` returns empty, not an error (confirmed by migration `055_dashboard_rpc.sql`'s own header, which is why `/resumen` reads through `SECURITY DEFINER` RPCs, not direct table/view access). The new RPC must follow the exact same pattern: `SECURITY DEFINER SET search_path = public`, `GRANT EXECUTE ... TO authenticated`.
- Next free migration number: 116.
- The deleted-from-the-page-but-still-present `src/components/dashboard/pipeline-donut.tsx` (145 lines) has a fully generic, reusable `Donut` SVG renderer (arc-path math, center-label totals) that only needs a `{id, color, totalValue}[]`-shaped input — adapt/rename it rather than writing new SVG math from scratch. `formatCurrencyShort`, `EmptyState`, `Skeleton` are already shared and reusable as-is.
- Design system already has 5 theme-aware categorical chart color tokens (`--chart-1` through `--chart-5` in `globals.css`, referenced as `var(--chart-1)` etc.) — use these for the 6 service types (one token will need to cover 2 service types, or pick the least-common one to fold in; use judgment, don't invent new hex colors).

## Scope
1. Migration 116: new `SECURITY DEFINER` RPC reading `cerebro_volumen_diario` filtered to today (`dia = current_date`), returning `service_type, operaciones, volumen_gyd, ticket_medio_gyd`, granted to `authenticated`. Name it consistently with the `cerebro_dashboard_*` convention (e.g. `cerebro_dashboard_volumen_por_servicio`). +ROLLBACK. Apply + verify on staging.
2. `src/lib/dashboard/queries.ts`: new `loadServiceVolume(db)` calling the RPC, mapped into a typed shape.
3. `src/lib/dashboard/types.ts`: new type for the widget's data (adapt `PipelineDonutData`'s shape — `stages[]` → `services[]` or similar, `dealCount`→`operationCount`, `totalValue`→stays as volume).
4. New component (adapt `pipeline-donut.tsx`'s reusable `Donut` renderer — new file, e.g. `service-volume-donut.tsx`; don't just rename the old file in place since the old one might still be a useful reference/is currently orphaned-but-harmless).
5. Wire into `src/app/(dashboard)/dashboard/page.tsx` in the spot the old `PipelineDonut` occupied (restore the two-column charts-row layout, this widget paired with `ConversationsChart`).
6. i18n: new `Dashboard.serviceVolumeDonut` (or similar) namespace in `messages/en.json`, matching the old `Dashboard.pipelineDonut` key shape.
7. Tests: a query test for `loadServiceVolume` if this file has existing test coverage patterns to follow (check first), component test if reasonable following existing dashboard component test conventions.
8. Verify on staging: apply migration, confirm the RPC returns real rows (staging only has 1 seed row currently — that's fine, confirms shape not volume).

## Explicitly out of scope
- Do NOT touch or resurrect anything under `src/app/(dashboard)/pipelines/` or `src/components/pipelines/`.
- Do NOT build the "operations needing attention" panel (deposit_verification/incident/ready_to_transfer counts) — considered, explicitly not what the user chose.
- Do NOT attempt to merge `/resumen` into `/dashboard` — out of scope, a possible future direction only.
- Do NOT delete `src/components/dashboard/pipeline-donut.tsx` or its `PipelineDonutData` type/`loadPipelineDonut` query — leave them in place, unused, for now (may inform other future work; deleting them is a separate, smaller cleanup task if ever wanted).

## Status
Done — 2026-09-24, on branch `feat/dashboard-service-volume-widget`
(created from `feat/dashboard-remove-dead-pipeline-links`, PR #44, not
yet merged).

1. Migration 116 (`cerebro_dashboard_volumen_por_servicio()`) + rollback:
   authored, applied to staging via the docker+psql pattern, verified
   callable (0 rows — staging has 0 rows for today, expected; confirms
   shape not volume). Commit `a6d5c8b`.
2. `src/lib/dashboard/types.ts` (`ServiceVolumeSlice`/`ServiceVolumeData`)
   + `src/lib/dashboard/queries.ts` (`loadServiceVolume`): done. Commit
   `0be40a0`.
3. `src/components/dashboard/service-volume-donut.tsx` +
   `Dashboard.serviceVolumeDonut` i18n namespace: done, reuses
   pipeline-donut.tsx's arc-path Donut renderer. Commit `f827d62`.
4. Wired into `src/app/(dashboard)/dashboard/page.tsx`, restoring the
   `lg:grid-cols-5` two-column charts row (`ConversationsChart` +
   `ServiceVolumeDonut`). Commit `f249952`.
5. Tests: skipped. `src/lib/dashboard/date-utils.test.ts` is the only
   test file touching `src/lib/dashboard/`, and it covers pure date
   utilities only — no query function or dashboard component has any
   existing test coverage, so there was no pattern to follow per the
   task's own fallback instruction.
6. Verification: `tsc --noEmit` 0 errors; `npm run lint` 0 errors, 45
   warnings (matches the pre-existing baseline exactly, no new
   warnings); `npm test` 1443/1445 passing (same 2 pre-existing
   unrelated `date-utils.test.ts` `mondayIndex` failures, untouched by
   this work); `npm run build` exits 0, `/dashboard` prerenders
   statically.

Color-token judgment call: `mexico` and `traduccion` share `--chart-5`
(6 service types, 5 tokens available). Reasoning: `remesa` is the core
remittance business (chart-1); `combo`, `recarga`, `visa` are common
distinct products (chart-2/3/4); `mexico` (a corridor variant) and
`traduccion` (a translation add-on) are the two most tangential to the
core business, so they were folded together. `traduccion`'s ring
segment and legend swatch render at reduced opacity (`strokeOpacity`
0.55) to stay visually distinguishable from `mexico` — no new hex
colors introduced.

Out of scope items were left untouched: `pipeline-donut.tsx`,
`loadPipelineDonut`, `PipelineDonutData` all still present and unused;
nothing under `pipelines/` touched; no "operations needing attention"
panel built; `/resumen` untouched; nothing deployed, no PR opened.

Not yet committed to git: this file itself (left untracked, per
existing repo convention for `odd/tasks/*.md`).
