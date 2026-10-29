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
- [ ] G1 Charts in Cierres (owner 2026-10-28: "hay alguna forma de mostrar los datos en algun grafico" -> "si").
  Profit by day (vertical bars) and by service (horizontal bars, sorted) above FinancialCloseSection's tables, from
  the data it already loads; profit of the last 8-12 archived weeks (line) above the archived weeks, from the weeks
  API. Recharts (already a dependency, `src/components/tremor/bar-chart.tsx`). Rules from the dataviz skill: one axis
  (no dual axis), no pie/donut, fixed categorical order, palette validated light+dark, hover tooltip, legend only
  for >= 2 series, table stays as the accessible view, mobile width. No API or calculation change.
- [ ] F2.4 Full checks (vitest affected + full suite, tsc, eslint), staging browser check, then the production panel deploy after the go-ahead.

## Delivery

- Forecast: about 400-700 authored changed lines, mostly moves and deletions. Strategy: ask-on-risk; one work-unit commit per task on the feature branch.

## Progress

- 2026-10-28 created. RDD off.

## Next step

F2.4 (checks, staging browser check, deploy after go-ahead).
