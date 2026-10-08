# Feature: money figures read "1 157 712,40" (BIPM / RAE) everywhere in the CRM UI

## Objective
Every money figure shown in the CRM UI (Calculadora, Finanzas, dashboard, inbox operations panel, board) groups digits in
threes with a space and uses a comma for the decimal, instead of `1,157,712.40`.

## Owner request (2026-10-07)
"Los números que aparecen en Calculadora, Finanzas y en general donde aparecen números de dinero usen este formato: la
BIPM y la RAE recomiendan separar las cifras de tres en tres con un espacio en blanco (no con comas ni puntos) y usar
una coma para el decimal."

## Decisions (taken, not re-opened)
- One shared module `src/lib/format-number.ts`; no per-file `en-US` formatting left for money.
- Thousands separator U+202F (narrow no-break space); decimal separator comma.
- Always group in threes, four-digit numbers included (`5 000`). Deterministic: format with en-US, then swap separators
  (no reliance on `es` locales / ICU versions).
- Each call site keeps its current min/max fraction digits; negative sign behaviour unchanged.

## Scope
IN: money/amount/rate figures rendered in the UI (Calculadora page + `lib/calculator/entry-display.ts`, Finanzas
`resumen` + `financial-close-*`, dashboard money widgets, `lib/currency.ts`, inbox operations panel, board).
OUT: typed-input parsing (calculator grammar, `<input type="number">`), text sent to customers/WhatsApp, API payloads,
SQL, machine exports, DB values, non-money numbers (counts, percentages, durations, sizes), any visual restyling.
Ambiguous hits stay unchanged and are listed under Open points.

## TDD
Mode: strict TDD on. Source: user global CLAUDE.md ("Strict TDD Mode: enabled"). Runner: `npx vitest run <files>`.

## Tasks
- [x] F1 `format-number.ts` + unit tests (RED then GREEN)
- [x] F2 `currency.ts` (formatCurrency, formatCurrencyShort, formatCompactNumber) converted, tests updated
- [x] F3 Finanzas: `financial-close-format.ts`, `resumen/page.tsx` fmtGyd converted, tests updated
- [x] F4 Calculator: `entry-display.ts` and `calculadora/page.tsx` figures converted, tests updated
- [x] F5 Inbox operations panel: `money()`, saldo summary, combo cost converted, tests updated
- [x] F6 Full verification (vitest, tsc, eslint, grep)

## Evidence
- F1 RED: `npx vitest run src/lib/format-number.test.ts` failed (module missing); GREEN 6/6. F2 RED: 12 failing in
  currency/format-number tests; GREEN 25/25. F3 RED: 2 failing (fmtGyd/fmtAmount, rateLabel); GREEN. F4 RED: 4 failing in
  entry-display; GREEN. Page and inbox suites updated deliberately (old `1,234.56` / `26000.00` assertions).
- Full suite: 174 files, 2304 tests passed. `npx tsc --noEmit` clean. eslint on changed files clean.
- Commit: see git log (feat(format): money figures ...).

## Open points (decision gaps, left unchanged)
- Calculator .txt export ("Exportar Reporte"): keeps plain figures (`30000.00`, `1,800 SM`, `45000 CUP`) because the owner
  pastes it elsewhere. Say the word to switch it to the new format.
- Rate/tier labels in text ("Zelle desde 1,000 USD", component `RATE_FIELDS` labels): static names, not figures.
- Finanzas "operaciones" tile count keeps `toLocaleString("en-US")` (a count, not money).
- Margin percentage (`26.7`) and other percentages untouched.
- `formatCompactNumber` also feeds AI token counts (agents/ai-usage): they now read `1,2k` instead of `1.2k`.
- Dashboard activity counts (`toLocaleString()`), broadcasts stats: counts, untouched.
