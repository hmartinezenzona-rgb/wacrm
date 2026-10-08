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
- Staging deploy (2026-10-08; release 582b52b6a028ca67228ea03db7bbcb78da32ac23, BUILD_ID snBy3i_ajiiM1w5-Xdw-w, app commit 582b52b): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2, pm2 wacrm-staging process cwd resolves to the new release, restarts 82 -> 83 and stable (unstable 0, still 83 after 20 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", served stylesheet `_next/static/chunks/0q-fjn5dk~yoh.css` (contains `--money-profit`, `--money-loss`, `--money-out`, `--money-in` and a `text-money-profit` rule) byte-identical to the build (sha256 7f5d824b...), Calculator page chunk `_next/static/chunks/0~ujc569f4p89.js` (references `text-money-in/loss/out/profit`) served by crm.onlinefreedom.site byte-identical to the build (sha256 4cbafddd...). Rollback: anterior -> a6b0d58 (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/a6b0d58ef49006efcb7d925bc1b1dc8f38d4f0a9 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`). Owner's look pending.

## Open points
- Archived weeks LIST table (Fact/Inv/Ganancia per week) and the per-service "Desglose Semanal" lines: not listed in the approved scope, left as they were.
- Production app deploy (2026-10-08, owner-authorised; release 644d67a81ddee17a465f831c427f348470c3997e, BUILD_ID 9mT8XaQBb2rnvLEa99pJH; the rejected profit ring is reverted in this commit): manifest environment=production, project hqztotshnlzaiziwjyzh, 0 staging refs (kolppplawzdsjfydwejr), 32 production refs, 114 build tests passed, pm2 `wacrm` cwd = new release, restarts 32 -> 33 and stable (unstable 0, still 33 after 20 s), /login 200 with valid TLS, "Bienvenido de nuevo", the new BUILD_ID and 0 occurrences of "Ganancia por servicio", served stylesheet `_next/static/chunks/0aloinb98jouv.css` (contains `--money-profit`, `--money-loss`, `--money-out`, `--money-in`) byte-identical (sha256) to the build, Calculator page chunk `0~ujc569f4p89.js` (references `text-money-in/loss/out/profit`, sha256 4cbafddd...) and the Finanzas chunk `0d0ql13c.h~_~.js` served by wacrm.onlinefreedom.site byte-identical to the build, no `gananciaServicio` in any built client chunk. Rollback: anterior -> be7f281a1c294ee66b5ffc4bd751f210201e4985 (`infra/deployment/rollback-wacrm-produccion.sh`).
- Staging deploy (2026-10-08; release 644d67a81ddee17a465f831c427f348470c3997e, BUILD_ID yt2SdAqYBVa98NOJ5MNJ_, app commit 644d67a): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2, pm2 wacrm-staging process cwd resolves to the new release, restarts 83 -> 84 and stable (unstable 0, still 84 after 20 s), /login 200 with the new BUILD_ID, "Bienvenido de nuevo" and 0 occurrences of "Ganancia por servicio", served stylesheet `_next/static/chunks/0aloinb98jouv.css` (contains the four `--money-*` tokens) byte-identical to the build, Calculator chunk `0~ujc569f4p89.js` and Finanzas chunk `0d0ql13c.h~_~.js` served by crm.onlinefreedom.site byte-identical to the build. Rollback: anterior -> 582b52b (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/582b52b6a028ca67228ea03db7bbcb78da32ac23 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).
