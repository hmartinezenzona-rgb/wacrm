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
- [x] T5 Step 2a: status tones module `src/lib/status-tone.ts` (9 statuses, neutral fallback), `StatusPill`, `--status-*` tokens (both themes), pill in the Finanzas history "Estado" column
- [x] T6 Step 2b: service colours module `src/lib/service-color.ts` (12 colours + neutral `other`), `ServiceDot`, `--service-*` tokens (both themes)
- [x] T7 Dots applied: Finanzas by-service and detail tables, Finanzas history "Servicio", Calculator Operaciones tables (live and archived week view) and service breakdown
- [x] T8 Leftover: Calculator "Semanas anteriores" list figures toned (Fact. in, Inv. out, Ganancia by sign)
- [x] T9 Leftover: "Desglose Semanal" Retorno uses the money token by sign instead of hard-coded green
- [x] T10 Step 3a: inbox operations panel `StatusChip` takes the shared status tone (`statusTextClass` in `status-tone.ts`, same `--status-*` tokens as StatusPill; shape, dot, size, position unchanged); deposit-review "verified" check uses `text-status-success`
- [x] T11 Step 3b: `ServiceDot` before the service name in the card header (when it names the operation's service, not on "Mixed" or without a service) and in the "Servicio" selector's displayed value (not inside the option list)

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

## Step 2 (status pills, service dots) - decisions and evidence
Owner approved in the proposal: (a) status as coloured pills, (b) one fixed dot per service, (c) step 1 leftovers. Nothing else restyled.

Status -> tone (mapping lives only in `src/lib/status-tone.ts`; unknown -> neutral). Labels come from `Inbox.operationsPanel.status`:
collecting_information neutral; awaiting_deposit info; deposit_received attention; deposit_verification attention; ready_to_transfer attention; transferring info; incident danger; completed success; awaiting_beneficiary (panel-only synthetic) info.
Neutral pill uses the theme's `bg-muted text-muted-foreground`; the other four use `--status-*` and `--status-*-soft` (12% alpha).

Contrast of pill text on its own soft background (computed from OKLCH -> sRGB, WCAG): dark card/background: info 4.93/5.07, attention 5.07/5.21, success 5.08/5.21, danger 4.64/4.78 (soft alpha .12 tuned so every pair is >= 4.5). Light card/background: all >= 5.1 (info 5.9, attention 5.5, success 6.2, danger 5.9, approx at alpha .12).
Service dots (non-text) >= 3:1 on card and background in both themes (dark 6.1-10.2; light 3.4-6.5); minimum OKLab distance between any two dot colours 0.111.
Service colour -> token: CUP/cuban_card cup; ZELLE zelle; MLC mlc; TROPICAL tropical; CLASICA clasica; USDT usdt; EFECTIVO/efectivo_usd efectivo; RECARGA/recarga recarga; SALDO_MOVIL/saldo saldo; DIRECTO/combo/traduccion/mexico directo; remesa remesa; visa visa; anything else `--service-other` (neutral grey).
TDD: RED observed for status-tone, service-color, service-dot, resumen page and calculator/Finanzas dot and leftover tests; the StatusPill component test was written together with its implementation (no separate RED).

Gaps / not touched:
- Inbox operations panel `StatusChip` (`operation-icons.tsx`) already has its own coloured chip with raw `text-emerald/amber/red` classes: left alone (existing badge). Its colours differ from the new pill tones.
- Operations board (`src/components/tablero/`): status is only the column header, cards print no status; service badge on cards is untouched.
- Dashboard `service-volume-donut.tsx` still uses theme colours (colours come from `queries.ts`).
- Finanzas by-day chart (Tremor blue/rose) untouched.
- Product choices to confirm: combo/traduccion/mexico share the DIRECTO colour; cuban_card shares CUP; deposit_received and deposit_verification are "attention".
- Staging deploy (2026-10-08; release fcd41e198ce7feb1becf9ecc6ed7628a019f8743, BUILD_ID vhvONS1aIi6W64HurjlN5, app commit fcd41e1): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2, pm2 wacrm-staging process cwd resolves to the new release, restarts 84 -> 85 and stable (unstable 0, still 85 after 20 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", served stylesheet `_next/static/chunks/0.l-9g4-n_rki.css` (contains `--status-success`, `--status-danger`, `--status-attention`, `--status-info`, `--service-zelle`, `--service-cup` and `--money-profit`) byte-identical to the build (sha256 619c6e8a...), Calculator chunk `0l7bha-y8ofou.js` and Finanzas (resumen) chunk `0frn4_~gv7lml.js` served by crm.onlinefreedom.site byte-identical to the build (all 16 chunks listed by the two page manifests match). Rollback: anterior -> 644d67a (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/644d67a81ddee17a465f831c427f348470c3997e ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).

## Step 3 (inbox operations panel) - decisions and evidence
Owner: "Los apruebo, solo que quiero que el panel del chat esté acorde también." Only colours of the panel changed.
Status colour change in the chip (shared mapping wins): ready_to_transfer green -> attention (amber), transferring green -> info (blue), awaiting_deposit and awaiting_beneficiary amber -> info (blue), deposit_received/deposit_verification amber -> attention, completed green -> success, incident red -> danger. Panel colours now match the Finanzas pill.
Left as they were (not status/money): method-icon badges (blue/amber/violet/teal/emerald Zelle) and the closing picker icons (indigo/emerald/amber/rose/sky/violet/teal), selected picker border (green), confirm/cancel buttons, notify bell, "amount missing"/"not verified" amber warnings, amber warning banners and chips, validation errors, deposit-review success feedback text (emerald-600).
Gaps: method/picker icons carry a per-method colour that differs from the service dot colour (product decision whether to unify); "not verified" and "amount missing" amber warnings could be the attention tone if the owner wants.
TDD: RED observed for statusTextClass, StatusChip tones, header dot, selector dot and verified check (check reverted temporarily to observe RED).
- Staging deploy (2026-10-08; release 69e863fd824c83fb3932af74fb707c6e1d29daa0, BUILD_ID oIat02LaXobHHllGqtnK2, app commit 69e863f): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2, pm2 wacrm-staging process cwd resolves to the new release, restarts 85 -> 86 and stable (unstable 0, still 86 after 20 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", served stylesheet `_next/static/chunks/0.l-9g4-n_rki.css` (contains `text-status-attention`, `--status-*` and `--service-*` tokens) byte-identical to the build (sha256 619c6e8a...), and all 17 JS chunks listed by the inbox page client-reference manifest (including the two referencing `text-status-`, `0l5f9pmus0fnd.js` and `14knasej1hb18.js`) served by crm.onlinefreedom.site byte-identical to the build. Rollback: anterior -> fcd41e1 (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/fcd41e198ce7feb1becf9ecc6ed7628a019f8743 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).
