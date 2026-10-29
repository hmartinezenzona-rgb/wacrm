# One "Finanzas" section (Semana | Cierres | Operaciones) and no Dashboard

## Objective

Phases 1 and 2 of the plan agreed on 2026-10-28, after the owner's Claude-chat research (structure "B"):
- phase 1: the useful operational parts of the Dashboard move to the Tablero and the Dashboard goes away;
- phase 2: "Control semanal" (/calculadora) and "Finanzas e historial" (/resumen) become one section, "Finanzas", with three tabs.

Phases 1 and 2 only reorganize what already exists: no calculation changes.

## Problem

- /resumen and /calculadora overlap. Both show billed, invested and profit from the same calculator data, and they define "a week" differently: a manual "Limpiar todo" cut versus a calendar week. That choice is left to phase 3.
- The Dashboard (/dashboard) comes from the generic CRM template and Osmany does not use it.

## Owner decisions

- 2026-10-28: "quisiera fusionar finanzas con control semanal y eliminar el dashboard ya que Osmany ni lo usa".
- Research structure B accepted. "si, empieza con las fases 1 y 2".
- Phases 3 and 4 wait for Osmany's answers: what a week is, which number first, the MMG/USDT reconciliation.

## Facts (code, 2026-10-28)

- Sidebar `src/components/layout/sidebar.tsx`: group "money" holds /resumen ("resumen"), /calculadora ("controlSemanal"), /inventario-cup and /tablero.
- /dashboard is the landing page in 4 places: `src/app/page.tsx` (redirect), `src/app/(auth)/login/page.tsx:68`, `src/middleware.ts:73` (auth pages when logged in) and `src/app/join/[token]/page.tsx:174`. It is also listed in `protectedPaths` (`src/middleware.ts:80`) and in `src/components/layout/header.tsx`.
- The Tablero (`src/app/(dashboard)/tablero/page.tsx` + `src/components/tablero/operations-board.tsx`) already shows a column per status with its count and an age tone per card (`ageParts`/`ageTone` in `src/lib/tablero/board.ts`). It refreshes every 20 s.
- The Dashboard widgets live in `src/components/dashboard/*` and `src/lib/dashboard/*`:
  - AgedOperationsQueue, with "Abrir chat" through `setInboxOpenTarget`;
  - OperationsFunnel, ServiceVolumeDonut, BusinessInsights and ResponseTimeChart;
  - MetricCard, ConversationsChart and ActivityFeed.
- /resumen (455 lines) has a period summary (ops, volume, ticket), FinancialCloseSection (`src/components/resumen/*`: day/week/month/range, by day, by service, detail, CSV) and an operations history with filters. i18n namespace `Resumen` in `messages/es.json` and `messages/en.json`.
- /calculadora (1270 lines) holds the weekly entries, the global rates, the by-service breakdown, the weekly cut "Limpiar todo" (`/api/calculadora/weeks` POST -> `crm_cerrar_semana_calculadora`) and the archived weeks ("Semanas anteriores", `loadWeeks()`, GET `/api/calculadora/weeks` and `/api/calculadora/weeks/{id}`).
- Neither page is role-gated in the sidebar. Any page or API checks they make must be kept.

## Scope

Phase 1 (Tablero + Dashboard):
- F1.1 Tablero: an "Atrasadas" strip above the columns. It lists the most stale in-flight operations (the "late" age tone), oldest first, at most 5, with "Abrir chat". It is computed from the board's own data, with no new query. It is hidden when nothing is late.
- F1.2 The Dashboard route goes:
  - /dashboard redirects to /tablero;
  - every landing that pointed to /dashboard points to /tablero;
  - the sidebar and header entries are removed;
  - Dashboard-only components and libs are deleted when nothing else imports them (verify with grep), together with their i18n keys.
- Volume today and top clients are not carried over in phase 1; they come back in phase 3 inside Finanzas > Semana. The response-time chart is dropped; the owner can ask for it back.

Phase 2 (Finanzas):
- F2.1 New route /finanzas with tabs **Semana | Cierres | Operaciones**. The tab is kept in the URL (`?tab=semana|cierres|operaciones`); the default is semana. One sidebar entry, "Finanzas", replaces "Finanzas e historial" and "Control semanal".
- F2.2 The tabs:
  - Semana: today's /calculadora content, unchanged in behaviour.
  - Cierres: the archived weeks, plus FinancialCloseSection (day/week/month/range, CSV). The archived-weeks list moves from Semana to Cierres. If it is too entangled with the calculator page's state, Cierres gets the list through its own component, using the same `/api/calculadora/weeks` endpoints; no API change.
  - Operaciones: the /resumen period summary and the operations history.
- F2.3 /calculadora and /resumen redirect to /finanzas with their tab (semana and operaciones), so old links and bookmarks still work. The header title map is updated.

## Out of scope

- Any change to calculations, rates, the weekly cut or the APIs.
- Phase 3: comparison with the previous week, top clients by profit, the "Hoy" strip.
- Phase 4: the close assistant and reconciliation.

## Constraints

- Next.js in this repo has breaking changes: read the relevant guide in `node_modules/next/dist/docs/` before writing routing or redirect code (AGENTS.md).
- Use graphify for structural questions, not codegraph (AGENTS.md).
- Spanish UI copy through next-intl (`messages/es.json` and `messages/en.json`), matching the existing keys style.
- Do not touch the other session's uncommitted files: `pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`, `pruebas/decisor/decisor-notas.test.ts`, `odd/tasks/bot-brevedad.md`.
- The panel is deployed only with the owner's go-ahead (skill wacrm-publicar-panel); browser check on staging first (skill wacrm-probar-staging).

## TDD

- Strict, on (global CLAUDE.md). Runner: vitest (`npx vitest run <paths>`); typecheck `npx tsc --noEmit`; lint `npx eslint <changed files>`.
- RED before each behaviour, for example:
  - the sidebar has one Finanzas entry and no Dashboard or Control semanal;
  - /finanzas renders each tab from `?tab`;
  - the Atrasadas strip shows only late operations, oldest first, at most 5;
  - the landings point to /tablero.

## Tasks

- [x] F1.1 Atrasadas strip on the Tablero (tests first). RED: `vitest run src/lib/tablero src/components/tablero` 4 failed + strip suite not loadable; GREEN: 4 files, 55 passed. Commit: see git log (feat(tablero)).
- [x] F1.2 Remove the Dashboard: redirects, landings, sidebar/header, dead components and i18n keys. RED: 12 failed across 5 files; GREEN: full suite 252 files, 3540 tests passed; tsc clean. Kept components/dashboard/skeleton.tsx and lib/dashboard/date-utils.ts (still imported elsewhere). Commit: see git log (refactor(dashboard)).
- [x] F2.1 /finanzas with tabs and one sidebar entry. RED: sidebar-nav 2 failed + 3 new files not loadable (tabs, finanzas-view, finanzas page); GREEN: `vitest run` on layout, lib/finanzas, components/finanzas, app finanzas: 9 files, 54 passed; tsc clean. Tab panels are interim wrappers of the old pages until F2.2. Commit: see git log (feat(finanzas)).
- [x] F2.2 Semana / Cierres / Operaciones content moved, behaviour unchanged. RED: `vitest run src/components/finanzas` 4 failed + archived-weeks not loadable; GREEN: 5 files, 146 passed; full suite 257 files, 3563 passed after fixing src/i18n/request.test.ts (Sidebar.resumen -> Sidebar.finanzas, missed in F2.1). Moved with git mv: calculadora page -> components/finanzas/semana-tab.tsx, resumen page -> operaciones-tab.tsx, both page tests, calculadora.module.css. Archived-weeks tests moved to archived-weeks.test.tsx. Old routes have no page until F2.3. Commit: see git log (refactor(finanzas)).
  - Correction (coordinator): panels stay mounted after first visit, hidden when inactive, so the Semana draft survives a tab switch; Cierres refetches the weeks when it turns active. RED: 4 failed (view x2, archived-weeks, cierres-tab); GREEN: `vitest run src/components/finanzas` 5 files, 150 passed; full suite 259 files all passed. Commit: see git log (fix(finanzas)).
- [x] F2.3 /calculadora and /resumen redirect to /finanzas; header titles. RED: 2 failed (the two redirect tests); GREEN: full suite 259 files, 3566 passed; tsc clean. No in-app links to /calculadora or /resumen existed besides the sidebar (already replaced); only comments were updated. Commit: see git log (feat(finanzas) redirects).
- [x] G1 Charts in Cierres (owner 2026-10-28: "hay alguna forma de mostrar los datos en algun grafico" -> "si").
  Profit by day (vertical bars) and by service (horizontal bars, sorted) above FinancialCloseSection's tables, from
  the data it already loads; profit of the last 8-12 archived weeks (line) above the archived weeks, from the weeks
  API. Recharts (already a dependency, `src/components/tremor/bar-chart.tsx`). Rules from the dataviz skill: one axis
  (no dual axis), no pie/donut, fixed categorical order, palette validated light+dark, hover tooltip, legend only
  for >= 2 series, table stays as the accessible view, mobile width. No API or calculation change.
  Done: profit by service (sorted horizontal bars) in FinancialCloseSummary,
  profit per week (line, last 12) above the archived weeks; new token --chart-profit (dark money-profit failed the
  palette L band: 0.78 -> 0.66; validator PASS light #00682a / dark #3eab5e). The summaries carry profit
  (manualTotals + chatTotals retornoGyd), no API change. RED: 2 new series suites + profit-charts suite not
  loadable, 2 wiring tests failed; GREEN: full suite 262 files, 3595 passed; tsc and eslint clean. The close already
  had a facturado+retorno per-day chart, so no second by-day chart was added (coordinator decision; a profit-only
  by-day chart built first was removed, RED: section test saw it, GREEN: gone). Visual check left to the owner.
- [x] S1 Semana overview (owner 2026-10-28 approved the mockup https://claude.ai/artifact/Xe9pm4L1L9pCmmnXfcW54v: "me gusta,
  programalo asi, quiero verlo en staging"). Above the existing calculator in the Semana tab: 4 KPI cards (ganancia
  with change vs the previous archived week at the same point, facturado + ops, invertido GYD + USDT + average cost,
  margen + ticket), profit by day Mon-Sat (today lighter), "Hoy" box with a warning for incomplete lines, profit by
  service (bars + margin), top 5 clients by profit, the existing entries table and rates below. Open week = entries
  since the last "Limpiar todo" cut (owner's current practice; to revisit with Osmany). No API, DB or calculation
  change; numbers come from the stored per-entry figures.
  Done: pure module src/lib/finanzas/semana-overview.ts (+19 tests) and src/components/finanzas/semana-overview.tsx above the
  calculator. Previous week read from GET /api/calculadora/weeks and /weeks/{id} (no API change), compared at the same
  elapsed days; day = entryDate (Guyana day); chart Mon-Sat of today's week. Not done: click-to-filter by service (the
  entries table has no filter) and "en curso sin completar" (the page holds no in-flight operations). RED: module suite
  not loadable, component suite not loadable; GREEN: `vitest run` 264 files, 3621 passed; tsc and eslint clean;
  /finanzas answers 307 on the staging dev server. Visual check left to the owner.
- [x] C1 Cierres redesign (owner 2026-10-29 approved the mockup https://claude.ai/artifact/TsFutkFLRp7dzwrEkW18AY: "me
  gusta, programalo asi y quiero verlo en staging"). Top to bottom: period chips (last 12 weeks | this month | last
  month | all, over archived weeks); 4 KPI cards (profit of the period with last-6 vs previous-6 change, average per
  week + ops per week, best and worst week, average margin + billed); main chart: profit per closed week as vertical
  bars with a dashed average line, selected week at full opacity, click selects; selected-week panel (name, dates from
  its entries, closed-by only if the cut stores it, profit with change vs the previous week, billed, invested, margin,
  ops, best day, top service, "Ver los registros" opens the existing week detail, "Exportar .txt" reuses the existing
  export if there is one); profit by service over the period (sorted bars + share); compact archived-weeks table (ops,
  billed, profit, margin, change vs previous); FinancialCloseSection at the end ("Cuadrar un periodo", collapsible,
  unchanged behaviour, CSV kept). Replaces the current WeeklyProfitChart line. No API, DB or calculation change.
  Done: pure module src/lib/finanzas/cierres-overview.ts (+16 tests, commit 80d4932) and src/components/finanzas/cierres-overview.tsx
  (+22 tests), wired in cierres-tab.tsx. RED: module suite and component suite not loadable; GREEN: `vitest run` 265 files,
  3645 passed; tsc and eslint clean; /finanzas?tab=cierres answers 307 on the staging dev server. Removed the line chart
  (WeeklyProfitChart, WeekTooltip, week-profit-series + tests, gananciaSemana/periodo i18n keys); archived-weeks.tsx now
  only exports ArchivedWeekDetail (the read-only week view), its tests rewritten. Omitted: "cerrada por X" (the weeks
  table stores no closer) and "Exportar .txt" (the only export is for the open week in Semana, none for an archived one).
  Assumptions: profit/billed/invested are the stored week totals (as the old table), ops/dates/best day/top service come
  from the week's entries (weeks cut before migration 228 hold only the bot's entries, so their ops can be low); period
  filters go by the week's last entry day (cut day if no entries), "Todo" covers the newest 60 weeks (detail read 6 at a
  time, once per week); the change is the last k vs previous k weeks with k=min(6, n/2). "Cuadrar un periodo" is collapsed
  and unmounted until opened. Visual check left to the owner.
- [x] O1 Operaciones redesign (owner 2026-10-29 approved the mockup, artboard Operaciones.dc.html in
  https://claude.ai/artifact/TsFutkFLRp7dzwrEkW18AY: "me gusta, programalo asi tambien"; then chose the new read-only
  function: "si, haz la funcion nueva de solo lectura"). DB: migration 351, a new read-only SECURITY DEFINER-or-INVOKER
  function (match the existing cerebro_dashboard_historial security model and grants) adding: free-text search
  (client name, phone, operation id), status filter, per-status counts for the current filters, conversation_id, and
  the operation time (Guyana). Existing cerebro_dashboard_historial stays untouched (no breaking change). ROLLBACK and a
  self-reverting staging assertion. Staging only; production apply needs the owner's go-ahead. UI: period cards
  filter the table when clicked; search box; service and dates; status chips with counts; table Hora (or date+time
  when the range spans days), Cliente + masked phone, Servicio, Monto GYD, Destino, Estado, "Abrir chat" (same
  mechanism as the Tablero/inbox open target); operation id copied from the row; "Exportar CSV" of the current filter.
  Done: migration 351 (commit 3ac5ebe): `crm_historial_operaciones` (old columns + conversation_id, operacion_at, estado_grupo;
  search by name / phone digits / operation id prefix; status group; limit capped at 200), `crm_historial_estados` (row counts
  per group under the same filters except status) and the IMMUTABLE helper `crm_historial_estado_grupo`; all SECURITY DEFINER,
  search_path public, EXECUTE only authenticated + service_role, `cerebro_dashboard_historial` untouched. Status groups:
  completed = completed; in_progress = collecting_information, awaiting_deposit, deposit_verification, deposit_received,
  ready_to_transfer, transferring; incident = incident; cancelled = cancelled. Pure helpers src/lib/finanzas/operaciones-historial.ts
  (+15 tests, commit 9237633) and the redesigned operaciones-tab.tsx (+20 tests, commit 3f6c6ce).
  RED: assertion failed before the migration ("function ... crm_historial_operaciones does not exist"); helper suite not
  loadable; tab suite 19 of 20 failed against the old component. GREEN: staging `aplicar` dry-run/apply/assertion/rollback all OK
  (assertion ALL PASS, rollback md5 equal); `relacionadas` 26 assertions, 25 SAME, 1 DIFF (the new assertion itself: base has no
  function, migrated passes); `vitest run` 266 files, 3671 passed; tsc and eslint clean; /finanzas?tab=operaciones answers 307.
  Omitted: phone masking (the old function already exposes the full phone to the panel, kept as is, no wider exposure); the
  "Aplicar" button (filters apply on change). Assumptions: counts are rows, like `total` (an operation with several recipients
  counts once per recipient, so a chip equals the table total); the operation time is COALESCE(completed_at, updated_at), the
  instant the old `dia` comes from; the default range is empty (all history) until a card or date is chosen; pressing the active
  card releases the range; the CSV caps at 5000 rows and says so. Visual check left to the owner.
  Production: migration 351 pending owner go-ahead, apply before the panel deploy (`previa` not run, leave to the parent).
- [ ] S2 Semana with the calculator merged in (owner 2026-10-29 approved the final mockup
  https://claude.ai/artifact/9qeDbj4Lndi7zD93EHX5Bn, variant A: "si", after a round of feedback). Display-only rework
  of the Semana tab; NO calculation, formula, rate-storage, API or DB change. Split into slices:
  - S2a Fixes in the existing overview: numbers use the panel's comma thousands / dot decimals everywhere (staging
    showed "35 609" and "239,5"); "Ganancia por dia" and "Hoy" use the days of the OPEN week (entries since the last
    cut), not the calendar week (staging week opened Wed 14 oct and the chart showed all zeros). Ganancia card same
    size as the others, in the profit colour; "Cifras en GYD" once. Daily chart in its own card, a value label on every
    bar, today lighter with "en curso", days not reached yet "aun no", no y-axis.
  - S2b "Tasas actuales" card: all RATE_FIELDS plus Mexico ARQ, grouped in 4 equal cards (USDT: compra, venta (note
    "tambien Clasica, Tropical y Mexico"), venta en CUP; Zelle: 50 / 1,000 / 2,000; Recargas y saldo: 500, 600, saldo;
    CUP, efectivo y Mexico: CUP global, efectivo USD, USD->MXN auto with age), unit suffix per value, click to edit in
    place with the SAME save path as today's rate editor (same lock and messages), pencil on hover. Groups come from one
    config list (rate -> group, unit) so a new rate is one line; flex-wrap cards + container query so new groups never
    leave holes. Replaces the "Tarifas Globales" select+input editor and the "Tasas actuales" list.
  - S2c "Registros de la semana": one table for bot and manual lines (replaces "Registros", "Operaciones" and "Desglose
    Semanal por Servicios" of the legacy calculator), quick-entry bar "+ Linea" (same parser and save as today's manual
    entry) with a preview row in the table's columns, format hints + "Todos los formatos" (the existing guide), search,
    status chips with counts (Todas / Completadas / Pendientes / Sin tasa / A mano), service filter, inline row edit
    (same edit/save logic as today), "Poner tasa" on lines without a rate, totals of the filtered rows, no "Abrir chat".
    Clicking a service in "De donde sale la ganancia" or a client in "Mejores clientes" filters this table.
  - S2d "Cerrar la semana" section at the end (pending/sin tasa notices with jump links, totals archived, week name,
    .txt checkbox, "Archivar y empezar semana nueva") using the existing close + export logic; header button scrolls to
    it. Warning style: neutral grey background, black text, amber dot (no brown text).
  - S2e Operaciones tab removed (Finanzas = Semana | Cierres); its history search moves into Cierres as "Buscar en el
    historial" without "Abrir chat" (uses migration 351 functions). /finanzas?tab=operaciones redirects to cierres.
- [ ] F2.4 Full checks (vitest affected + full suite, tsc, eslint), staging browser check, then the production panel deploy after the go-ahead.

## Delivery

- Forecast: about 400-700 authored changed lines, mostly moves and deletions. Strategy: ask-on-risk; one work-unit commit per task on the feature branch.

## Progress

- 2026-10-28 created. RDD off.

## Next step

F2.4 (checks, staging browser check, deploy after go-ahead).
