# One name per service, everywhere

## Objective
Every screen that shows a service name shows the same canonical name for it, resolved from either vocabulary
(ledger keys, operation service types, delivery methods / beneficiary types).

## Owner request
Variants found: ZELLE/Zelle, CLASICA/Clásica, Saldo Móvil/Saldo móvil/SALDO MOVIL, VISA/Visa/Extensión de visa,
EFECTIVO/Efectivo en USD, "Trámites / Combos / Servicios" and the same in capitals, "Tarjeta CUP" vs "CUP".

## Decisions (approved by the owner)
Canonical Spanish names, exactly: CUP, Zelle, Clásica, Tropical, MLC, USDT, Efectivo USD, Recarga, Saldo móvil, Combo,
Visa, Trámites, Traducción, México, plus "Remesa mixta" (remittance split over several kinds) and "Remesa" only where
the screen cannot know the rail.
- ONE pure module `src/lib/service-name.ts` resolves any key to a canonical id and names an operation with the DB's
  precedence (`calculator_resolve_operation_service`, migration 223).
- ONE catalog namespace `ServiceNames` in es.json and en.json; Calculator and Finanzas history (no next-intl) use a
  shared Spanish table that a test proves equal to es.json.
- Display only: keys sent to the API or database never change. The Calculator `.txt` export and the text-box grammar do
  not change.

## TDD
Mode: strict TDD ON. Source: user global CLAUDE.md. Runner: `npx vitest run <files>`.

## Tasks
- [x] N1 Names module + catalog namespace (es/en) + tests (parity, es table equals es.json)
- [x] N2 Calculator, Finanzas close and Finanzas history
- [x] N3 Dashboard (donut labels, aged queue), operations board card text, inbox panel
- [x] N4 `CalculatorServiceType` gets COMBO and VISA if it is a pure type fix

- [x] H1 Migration 229 + ROLLBACK + staging assertion: `cerebro_dashboard_historial` returns `servicio`, filter accepts both vocabularies
- [x] H2 Same migration: the board RPC keeps `awaiting_deposit` / `deposit_received` (ranked 1 and 2)
- [x] H3 Finanzas history cell and filter use `servicio` and the shared names (works without 229)

## Evidence
- N1 5dfd12b: `service-name.test.ts` RED (module missing) then GREEN; `service-color` resolves through the canonical id.
- N2 702a124: calculator, close, history. RED observed on 8 calculator tests, then GREEN. History refactor-only (names
  already matched), covered by the existing tests.
- N3 acc2930: dashboard aged queue (new test, RED then GREEN), donut, board card text and pills, inbox panel (picker,
  closing control, correction form, add-beneficiary, card header). RED observed on 10 inbox tests.
- N4: COMBO and VISA added to `CalculatorServiceType`; tsc and calculator tests unchanged, so a pure type fix.
- The `use-service-name` hook test was written together with the hook (RED skipped for that tiny hook).
- Full suite 184 files / 2460 tests green; tsc and eslint clean.

- H1/H2 54977e8 (staging only): assertion `history-service-and-board-statuses.sql` RED (result columns lack `servicio`; the
  board half fails with the 219 function re-applied), then GREEN after applying 229 (BEGIN; assertion; ROLLBACK forced, run
  from a docker postgres:17 psql). Cases: CUP, ZELLE, CLASICA, TROPICAL, EFECTIVO, RECARGA, SALDO_MOVIL, COMBO, VISA, MIXTA,
  TRADUCCION, MEXICO, bare remesa -> REMESA; two same-kind recipients -> ZELLE on two rows (grain unchanged); filter 'CUP'
  only CUP with a correct `total` (also on a 1-row page); old 'remesa' returns every remittance and nothing else; old
  four-argument call still answers; grants (authenticated + service_role, not anon); board order collecting, awaiting,
  verification, received. Staging drift check before overwriting: none (repo and staging bodies equal; ACLs as 088b left them;
  the view has no dependants other than the RPC, so it was NOT changed: the RPC reads `delivery_method` from the operation).
- Rollback proof on staging, inside a rolled-back transaction: ROLLBACK-229 gives the pre-229 md5 for both RPCs
  (cerebro_dashboard_historial 4d077dbeb2d4be9822e84293666913c2, crm_tablero_operaciones d09ded1e35123fcf13a506dbb9dc0427),
  same ACLs, anon has no EXECUTE. Staging then left WITH 229 applied.
- Timing on staging (synthetic 4008 history rows in a rolled-back transaction, server-side clock): page of 200 rows 50 ms
  before, 81-99 ms after; limit 1000 with the remesa filter 66 ms before, 191 ms after; count only 69 ms before, 54 ms after.
  `servicio` is computed once per operation (CTE), not per recipient row. Real staging has 8 rows (~85 ms is the round trip).
- Related assertions after 229: board-status-age PASS, operations-board PASS, cutover PASS. deals-free-views-and-inert-edits:
  its history/view cases PASS; four FAILs are in the alert and delivery fixtures (crm_entregar_operacion, alert), which 229 does not touch.
- H3 57b6353: `page.test.tsx` (cell with and without `servicio`, filter options and the value sent) and the names module
  (`MIXTA`) RED then GREEN. Full suite 184 files / 2467 tests green; tsc and eslint clean.
- Fingerprint after 229 on staging (production must give the same after it gets 229):
  `select md5(pg_get_functiondef('public.cerebro_dashboard_historial(date,date,text,integer,integer)'::regprocedure)), md5(pg_get_functiondef('public.crm_tablero_operaciones()'::regprocedure)), md5(pg_get_viewdef('public.cerebro_historial_operaciones'::regclass));`
  staging: 9dbb5a2858e579afef6b20f7bcd620f5, 11379ddcbc226d516f4a422ab1f95ca5, b744d92520d67fa9180e7fd760425904 (view unchanged by 229).

## Open points
- Production: migration 229 and the app reach production separately; both orders are safe (new app on old DB falls back to
  `service_type` but its ledger-style filter values match nothing until 229; old app on new DB ignores `servicio` and its old
  filter values still match). Preferred: migration first.
- The board SQL ranks incident 4 and completed 5 while the client column order is requested, depositCheck, readyToTransfer,
  completed, incident. Left as is on purpose.
- The history RPC (and its view) have no account filter: any authenticated user reads every account's rows. Pre-existing
  (088), not changed here; a product/security decision.
- Staging deploy (2026-10-08; release d5dd1b2c5ae22a7007c882a0fcc5c19649cb038c, BUILD_ID hs8nPGSwrAx5ytEWJfDHd, app commit d5dd1b2; migration 229 already applied on staging): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2 and the unpacked release byte-identical to a fresh extraction of the built tarball (2468 files), pm2 wacrm-staging process cwd resolves to the new release, restarts 89 -> 90 and stable (unstable 0, still 90 after 30 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", all 14 JS chunks listed by the client-reference manifest of the Finanzas resumen page served by crm.onlinefreedom.site byte-identical to the build, and the page chunk (`0ax2iwgiul.mn.js`) calls `cerebro_dashboard_historial` and reads `e.servicio` from the history rows. Rollback: anterior -> 5233c84 (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/5233c84436c5f272b30581aa925e650e4170e6a7 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).

- Production database, migration 229 (2026-10-08, owner "pasalo a produccion"): backup
  `~/wacrm-respaldos/produccion-20261008T132759Z.dump`. Pre-check: production had the pre-229 definitions
  (history `4d077dbe…`, board `d09ded1e…`, view `b744d925…`, resolver `3c67bdca…`), last migration 228. Applied
  through `~/cerebro-fase1/pruebas/gate129-aplicar-db.py` (helper `zz_wu5b_exec` created before, dropped after, count
  0): `ensayo` fingerprint equal to staging (history `9dbb5a28…`, board `11379ddc…`, view and resolver unchanged);
  `GATE_BUNDLE=ida-y-vuelta ensayo` gave the pre-229 md5s back; `aplicar` -> `{"r":"OK"}`, recorded as
  `229_history_service_and_board_statuses`; `probar history-service-and-board-statuses` -> ALL PASS (rolled back).
  Read back: one `cerebro_dashboard_historial`, its rows carry `servicio` (EFECTIVO, ZELLE, VISA, CUP on the six
  live rows); 5 operations and 31 calculator entries, as before.
  Pre-existing difference, not changed: production's `crm_tablero_operaciones` is not granted to service_role
  (staging's is).
- Production app deploy (2026-10-08, owner "pasalo a produccion"; release 04c7a7637cdc5a373ffaa90c2fbe9e7bdf8218dc, BUILD_ID IzL95HD_6uQIq8G04R_Zb, app commit 04c7a76; migration 229 was already applied on production; the release also carries the status pills, the panel header reorganisation, the single deposit notice and the board visual pass): built in docker node:20 as uid 1000 from the clean prod-build worktree with the production build env, manifest environment=production, project hqztotshnlzaiziwjyzh, 0 staging refs (kolppplawzdsjfydwejr), 32 production refs, 114 build tests passed, pm2 `wacrm` cwd = new release, restarts 33 -> 34 and stable (unstable 0, still 34 after 20 s), /login 200 with valid TLS, "Bienvenido de nuevo" and the new BUILD_ID, served stylesheet `_next/static/chunks/0mv-z_eqiiq1f.css` (contains `--lane`, `--status-success`, `--service-zelle`, `--money-profit`) byte-identical (sha256) to the build, all 23 JS chunks listed by the tablero, inbox, calculadora and resumen client-reference manifests served by wacrm.onlinefreedom.site byte-identical to the build, deployed es messages carry `ServiceNames` ("Efectivo USD", "Remesa mixta") and none of "Extensión de visa", "Tarjeta CUP", "Depósito no verificado", "Ganancia por servicio", no `gananciaServicio` or `depositReview.notVerified` in any built client chunk, prod-build clean. Rollback: anterior -> 644d67a81ddee17a465f831c427f348470c3997e (`infra/deployment/rollback-wacrm-produccion.sh`).
