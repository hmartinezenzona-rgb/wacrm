# Feature: edit the investment rates of one calculator entry

## Objective
From "Editar" in Control Semanal (/calculadora), an admin sees the rates a single remesa or service was costed with and
can change its investment rates. Invertido and retorno for that entry are recomputed, and the change flows everywhere
(Control Semanal totals, Finanzas Resumen, cierre financiero, dashboard). The customer price, facturado, the global
rates and the bot quote do not change.

## Owner request (2026-10-14)
Osmany invests at different prices. Example: CUP bought at 1060 CUP per USDT, then the card runs out for the day and he
uses another one bought at 960. The internal control must reflect the real investment of each operation. The global
"Tarifa CUP" (3 CUP per GYD) stays the same; this is only internal control.
Owner decisions:
- Both investment rates are editable: "Venta USDT (CUP)" (snapshot `cup_rate`, CUP service only) and
  "Compra USDT (GYD)" (snapshot `usdt_buy_gyd`, every service).
- The change must reach Finanzas as well ("debe repercutir en todo").
- NO audit/history row for rate edits (owner declined it explicitly).

## Current state (mapped 2026-10-14)
- Per-entry rate snapshot on remittance_calculator_entries (095/104): cup_global_rate, cup_rate, usdt_buy_gyd,
  usdt_sell_gyd, rate_version_id; stored facturado_gyd / invertido_gyd / retorno_gyd.
- invertido (SQL calculator_invertido, 105; TS twin src/lib/calculator/formulas.ts calculateEntry). CUP:
  (amount / cup_rate) * usdt_buy_gyd. RECARGA / SALDO_MOVIL: cost_usdt * usdt_buy_gyd.
- Completed rows are locked by remittance_calculator_entries_lock_completed (104, 149 GUC hole
  wacrm.calculator_correction, 228 manual rows). Template: crm_corregir_entrada_calculadora (149, 228).
- Finanzas (crm_cierre_financiero 228, cerebro_dashboard_resumen 234) read the STORED figures, so no Finanzas change.
- Archived weeks (227/228 remittance_calculator_weeks) snapshot figures as jsonb.
- Existing Editar (page.tsx ~358, ~827) edits facturado/invertido in GYD via
  POST /api/calculator/entries/[entryId]/correct.

## Scope
- New migration 236 + ROLLBACK-236 + staging assertion: admin-only SECURITY DEFINER RPC that sets the entry's
  investment rate(s), recomputes invertido from the entry's own stored amount/service/snapshot and retorno =
  facturado - invertido. facturado, cup_global_rate, usdt_sell_gyd untouched. Refuses: non-admin, missing/deleted/void
  entry, entry in an archived week, cup_rate on a non-CUP service, non-positive rates.
- New API route + route test.
- Editar UI shows the snapshot rates and lets the admin change the two investment rates, with recomputed figures.
- Out of scope: audit row, global rate changes, bot quote, editing archived weeks.

## Constraints
- Staging first; production only with the owner's explicit go-ahead.
- Conventional Commits, no AI trailer. Do not restyle anything not asked for.
- TDD strict: RED -> GREEN -> REFACTOR. Runner: `npm test` (vitest); SQL assertions in supabase/staging/assertions/.
  Mode source: user global instructions (Strict TDD Mode: enabled).
- RDD: off (decided by default).

## Tasks
- [x] T1 Migration 236 RPC + rollback + staging assertion file (commit b05acd8; SQL assertion written, NOT run: pending staging run in T4)
- [x] T2 API route + route test (commit be3de6a; RED 21 failed -> GREEN 21 passed)
- [x] T3 Editar UI: show snapshot rates, edit both investment rates, recompute preview; read-model mapping + tests (commit 9104d23)
- [x] T4 Apply 236 on staging, deploy staging, owner checks (owner checked staging 2026-10-14: CUP entry edited to 1060 -> invertido 6792.45; Zelle entry edited to 238 -> invertido 23800; figures correct)
- [x] T5 Production (owner go-ahead 2026-10-14 "pasa a producción"; done 2026-10-14, evidence below)

### Extension: manual entries (owner request 2026-10-14)
Owner tried Editar on a production CUP entry and saw no rates: every CUP entry of the current week is MANUAL
(production current week: 3 chat ZELLE with snapshot; 30 manual rows - 3 CUP, 26 ZELLE, 1 CLASICA - with NULL
cup_rate / usdt_buy_gyd / cup_global_rate). Owner: "extiéndelo a las manuales también". Editar on a manual row
prefills the CURRENT global investment rates (no snapshot exists), recomputes invertido/retorno on change, and stores
the chosen rates on the row from then on. facturado untouched. Still no audit row.
- [x] T6 Migration 237 (+ROLLBACK, assertion): rate edit accepts manual rows; stores the rates on the row (commit d5538ea; assertion cases 13-17 written, NOT run: pending staging run T8)
- [x] T7 Route/UI/read model: manual rows editable, prefill from current global rates when the row has none (+tests) (commit 8d6b7f0; RED entry-rates 2 failed + page 4 failed -> GREEN 18 / 111)
- [ ] T8 Staging apply + deploy + owner check (needs owner authorization)
- [ ] T9 Production (needs owner go-ahead)

## Acceptance criteria
- Editing a CUP entry from 1060 to 960 changes only its invertido/retorno; facturado unchanged.
- Control Semanal totals and Finanzas Resumen reflect the new figures.
- Customer price / global rates unchanged.

## Progress / evidence
- 2026-10-14: document created, exploration done.
- 2026-10-14: T1-T3 implemented on feat/port-chat-operations-calculator. No local wacrm database was available (the only local
  Postgres is the unrelated remittance-core container), so migration 236 and its assertion
  (supabase/staging/assertions/calculator-entry-investment-rates.sql) are UNRUN: pending staging run (T4).
- RPC crm_corregir_tasas_entrada_calculadora(entry, usdt_buy_gyd, cup_rate). The 149 lock-trigger hole (wacrm.calculator_correction)
  only guards amount/service/operation_id/rate_version_id, so the rate snapshot columns need no trigger change and the hole does NOT
  force an audit row (only the 149 RPC writes one by its own choice): none is written, as decided.
- Per service: CUP (amount/cup_rate)*buy; RECARGA amount*cost_gyd*buy (cup_rate snapshot = buy rate, kept equal); SALDO_MOVIL
  (basis_gyd/sale_gyd)*cost_gyd*buy (amount is saldo units; cup_rate kept equal to buy); ZELLE/MLC/CLASICA/TROPICAL/USDT/EFECTIVO/DIRECTO
  amount*buy; COMBO/VISA refused (no rates); manual, void, pending and archived-week entries refused; cup_rate refused off CUP.
- Verification: new/changed vitest files green (route 21, entry-rates 13, page 106), npm test 189 files / 2556 tests, tsc 0, eslint 0.
- 2026-10-14 T4 staging run (owner-authorized, staging only):
  - Staging schema_migrations was at 228 (convention: version '228', name '228_manual_entries'); 229-235 are not recorded there.
    Function did not exist before 236.
  - RED: the assertion first failed with a plpgsql syntax error in case 9 (unparenthesized CASE inside `IF SQLSTATE = CASE ... THEN`),
    a fixture bug, fixed in 0d7b78d (parenthesized). Rerun then failed as expected: function crm_corregir_tasas_entrada_calculadora does not exist.
  - Migration 236 applied with --single-transaction at 2026-10-14 21:56 UTC; row ('236','236_calculator_entry_investment_rates') inserted
    in supabase_migrations.schema_migrations. SECURITY DEFINER; EXECUTE for postgres, service_role, authenticated; anon false.
  - GREEN: assertion in BEGIN..ROLLBACK: ALL PASS (cases 1-12). remittance_calculator_entries before and after identical
    (37 rows, sum invertido 1158317.6388349514562, retorno 181394.7611650485873, facturado 1339712.4).
  - Deployed to staging (crm.onlinefreedom.site, pm2 wacrm-staging online): release 0d7b78d5412c4c8fff278a251df22246a6661799, BUILD_ID
    GtZ2kSH0wSbAm8cQzRcOQ (server and domain match, pm2 cwd = the new release). anterior -> d39a3613b5883da4f9a0f4618b7b1fd4abd1f683.
    Manifest staging, ref kolppplawzdsjfydwejr, 0 production refs, sha256 ok. prod-build restored to 4930fe5.

- 2026-10-14 staging test entries (owner-authorized, staging only) so the owner can try Editar rates on /calculadora:
  - Why the page showed nothing: the owner cut the week ("Limpiar todo") at 2026-10-14 18:40 UTC (remittance_calculator_weeks), which moved
    all 37 entries into remittance_calculator_week_entries; calculator_current_entries (the GET source) excludes them, so 0 current entries.
  - Created through the real path (contact PRUEBA TASAS, two remittance_operations moved to completed under the owner claim, trigger ran
    calculator_feed_operation with rate version ded565f7: global 3, buy 240, sell 260, sell CUP 975):
    CUP 30,000 -> entry b3c3f377-95f0-472d-a583-3647572ffba4 (facturado 10000, invertido 7384.615, retorno 2615.385);
    ZELLE 100 -> entry b2788df5-0b3e-4719-bf95-952df774ef42 (facturado 26000, invertido 24000, retorno 2000).
  - Ids: contact 56588e14-691f-4698-88a9-e7c3985c5d23, conversation aa1a1fad-e2a1-4d78-b680-6dce937e59a5, operations
    cfe38f3f-fac0-4b09-9e28-6e08064668a8 (CUP) and 91a9b37e-1f8a-41a7-8089-e1532fc76b10 (ZELLE).
  - Dry run (rolled back): CUP cup_rate 975 -> 960 gave invertido 7384.615 -> 7500, retorno 2615.385 -> 2500; nothing persisted.
  - Cleanup SQL (staging only, run later; delete this data before the next weekly cut matters):
```sql
BEGIN;
SET LOCAL session_replication_role = replica; -- completed entries are append-only (149/228 guard); verified in a rolled-back dry run
DELETE FROM remittance_calculator_entries WHERE operation_id IN ('cfe38f3f-fac0-4b09-9e28-6e08064668a8','91a9b37e-1f8a-41a7-8089-e1532fc76b10');
DELETE FROM remittance_admin_audit WHERE row_id IN ('cfe38f3f-fac0-4b09-9e28-6e08064668a8','91a9b37e-1f8a-41a7-8089-e1532fc76b10');
DELETE FROM remittance_beneficiaries WHERE operation_id IN ('cfe38f3f-fac0-4b09-9e28-6e08064668a8','91a9b37e-1f8a-41a7-8089-e1532fc76b10');
DELETE FROM remittance_operations WHERE id IN ('cfe38f3f-fac0-4b09-9e28-6e08064668a8','91a9b37e-1f8a-41a7-8089-e1532fc76b10');
DELETE FROM conversations WHERE id = 'aa1a1fad-e2a1-4d78-b680-6dce937e59a5';
DELETE FROM contacts WHERE id = '56588e14-691f-4698-88a9-e7c3985c5d23';
COMMIT;
```

- 2026-10-14 T5 production (owner go-ahead "pasa a producción"):
  - Backup `~/wacrm-respaldos/produccion-20261014T220911Z.dump` (supabase/cutover/respaldar-base.sh produccion; 111 data tables, 318 functions, sha256 316959b7889f5f56...).
  - Recon: function absent; last migration 235 (20261009024301); lock trigger remittance_calculator_entries_append_only -> ..._lock_completed present with the
    wacrm.calculator_correction hole; week tables and calculator_current_entries present. Template crm_corregir_entrada_calculadora ACL in production is
    postgres + authenticated only, same as 236's GRANT (authenticated; REVOKE PUBLIC, anon).
  - `~/cerebro-fase1/pruebas/gate138-aplicar-db.py` (copy of gate136, bundle 236 only, bundle md5 4bbca791636a02577dd32be07bcd997e): `quien` -> role postgres;
    `ensayo` (rolled back) -> new fn md5 4332dccb71c56d9c59dbaa2f775ca134, ACL {postgres,authenticated}, six untouched functions identical to before
    (calculator_feed_operation 31c256da, calculator_invertido fb30194d, cerebro_dashboard_resumen 3827c120, crm_cierre_financiero c903a471,
    crm_corregir_entrada_calculadora 5fb1c6d4, is_account_member cea73e60); `aplicar` -> {"r":"OK"}, row 20261014221208 / 236_calculator_entry_investment_rates.
  - After: fn md5 4332dccb..., SECURITY DEFINER, anon false, authenticated true. remittance_calculator_entries before = after: 122 rows, facturado 4536577.40,
    invertido 4111483.0781553398064480, retorno 425094.3218446602358520. Helper zz_wu5b_exec dropped (count 0); temp n8n workflows deleted.
  - The staging assertion was NOT run in production: its header says staging only, never production, and it builds auth.users/accounts fixtures.
  - App: release 5e912131267bcdbb660e70f8280722a671564b73 built in prod-build (Node 20.20.2, production env; manifest environment production, ref
    hqztotshnlzaiziwjyzh, 32 production refs / 0 staging refs), BUILD_ID O6hPDeIZw9Wf23jcfcYfH. Deployed with desplegar-wacrm-produccion.sh: pm2 wacrm online,
    cwd = the new release, domain serves the BUILD_ID, /login 200. Rollback target (anterior): 4930fe58af0de0600546f320d779d285ee8aeb7a
    (rollback-wacrm-produccion.sh; DB: ROLLBACK-236 through gate138). prod-build left at 5e91213. Build note: needed NEXT_PRIVATE_OUTPUT_TRACE_ROOT=$PWD
    because the stray ~/package-lock.json made Next nest the standalone output.

- 2026-10-14 T6-T7 (manual rows), findings:
  - (a) Manual rows are INSERTED once by crm_registrar_entradas_manuales (228) when the admin presses Registrar; the registered lines then leave the text box.
    The textarea autosave only stores raw text and never re-generates rows, so a rate edit is not overwritten. Nothing to fix.
  - (b) Lock trigger (228) lets a manual row change under wacrm.calculator_correction while it stays completed; it freezes account/date/customer/day_label/raw_line/
    completed_at/currency and (149 hole) amount/service/operation/rate_version. The rate columns are free, so 237 needs no trigger change.
  - (c) Manual formulas (web-calculator.ts calculateLine): CUP (amount/cup)*buy and USDT amount*buy equal the SQL; ZELLE/MLC/CLASICA/TROPICAL are
    (amount/(1+pct))*cost, equal to amount*buy only without a discount ("%" in the typed line). The discount is not stored in a column, so a discounted
    manual line is refused by 237 (raw_line contains "%").
  - (d) Manual services: CUP, ZELLE, MLC, TROPICAL, CLASICA, USDT, SALDO_MOVIL, RECARGA, DIRECTO (COMBO/VISA lines are typed as DIRECTO, no investment).
    RECARGA/SALDO_MOVIL manual: amount*unitCost*buy with the unit cost only in the typed line (cost_gyd NULL) -> refused. COMBO/VISA stay refused.
  - Editar: a manual row without snapshot prefills the CURRENT global usdt_buy_gyd / usdt_sell_cup (from the rates the page already loads, no new fetch); a
    change sends the full set the formula needs and the database stores it on the row; untouched prefill = plain figures edit.
  - Verification: npm test 189 files / 2566 tests, tsc 0, eslint 0. SQL (237 + assertion cases 13-17) NOT run: pending staging run (T8).

## Next step
T8: apply 237 on staging, run the assertion (cases 1-17) and deploy staging: needs the owner's explicit authorization. Then T9 production only with the owner's go-ahead. Staging test entries (PRUEBA TASAS) are still to be deleted when the owner says (cleanup SQL above).
