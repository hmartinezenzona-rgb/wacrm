# Semantic money colours (step 1)

## Objective
Give money figures a fixed colour meaning so profit and money in/out are readable at a glance.

## Owner request
"Siento que le faltan colores a los datos en el CRM: casi todo se ve igual, no hay un color que te indique ganancia o dinero." After research he approved ONLY this first step, to be reviewed on staging before anything else is coloured.

## The four meanings (independent of the accent theme)
- profit / positive "retorno" -> green (`money-profit`)
- loss / negative "retorno" -> red (`money-loss`)
- money out / "invertido" -> amber (`money-out`)
- money in / "facturado" -> blue (`money-in`)

## Scope
Step 1 (approved): totals and money columns of the Calculator page and the Finanzas financial close (`src/components/resumen/`).
NOT approved yet (later steps): status badges, per-service colour dots, dashboard, board, inbox panel, the profit ring (rejected look, pending decision, do not touch).

## Decisions
- Tokens are CSS custom properties in `src/app/globals.css` (dark + light base themes), exposed to Tailwind as `--color-money-*` in `@theme inline`. Never derived from `--primary` / `--chart-N`.
- Never colour alone: totals show `+` / `−` (U+2212) on profit, zero is neutral and unsigned; each totals card gets a lucide icon.
- Totals cards: thin inset accent stripe (no layout change) + icon + figure in tone. Tables: text colour of the facturado / invertido / retorno columns only.
- The `.txt` export and anything off screen is untouched. Formatter stays `fmtGyd` / `formatNumber`.
- TDD: enabled, source user global CLAUDE.md, runner `npx vitest run <files>`.

## Tasks
- [x] T1 Pure helper `src/lib/money-tone.ts` (tone by sign, signed formatting, class maps) with tests
- [x] T2 Tokens in globals.css (dark + light) and `@theme inline`, contrast verified
- [x] T3 Figure component + Calculator totals boxes and the three columns (open and archived week)
- [x] T4 Finanzas summary tiles, by-service table, detail table columns

## Evidence
- RED observed before each GREEN (helper module missing; calculator and Finanzas tone tests failing on untoned markup).
- Tokens: `--money-profit|loss|out|in` in both `html[data-mode]` blocks plus `--color-money-*` in `@theme inline`.
  Text contrast, dark (card / background): profit 10.02/10.72, loss 7.04/7.53, out 10.67/11.42, in 8.20/8.77.
  Light (card / background): profit 6.96/6.35, loss 6.62/6.04, out 6.15/5.60, in 6.61/6.02.
- Existing calculator tests updated deliberately: the Retorno total now reads `+N` (6 expectations).
- Full suite, tsc, eslint green (see commit).

## Open points
- Archived weeks LIST table (Fact/Inv/Ganancia per week) and the per-service "Desglose Semanal" lines: not listed in the approved scope, left as they were.
