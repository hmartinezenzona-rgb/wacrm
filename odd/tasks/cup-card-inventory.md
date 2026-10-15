# Feature: CUP inventory per sending card (lots, priority, daily limit)

## Objective
The profit of every CUP remesa reflects what that CUP really cost the owner (Osmany), according to the sending card
and the lot it came from. The system tracks his own sending cards, the CUP lots loaded on each (amount + purchase
rate in CUP per USDT), the daily transfer limit, and which card to use next.

## Owner decisions (2026-10-14, one question at a time)
- Scope: CUP only for now.
- The SYSTEM picks the card, by an owner-defined PRIORITY order, and shows the operator which card to use.
- Cost per LOT, FIFO inside each card (not a weighted average).
- When the card's remaining daily limit or balance is short, the remesa is SPLIT across cards (priority order).
- Deduction happens in BOTH cases: a CUP operation is completed (panel, crm_entregar_operacion) AND a manual CUP line
  is registered in Control Semanal (crm_registrar_entradas_manuales, 228).
- Manual lines: the rate Osmany typed WINS; inventory only deducts the CUP. CRM/bot operations: the consumed lots'
  rate becomes the entry's cup_rate.
- No card with limit today: the operation waits for the next day (manual lines, already transferred, register anyway
  with a warning).
- Daily limit 120,000 CUP per card, reset at MIDNIGHT CUBA (America/Havana), unlike the rest of the system (Guyana).
Claude defaults (stated to the owner):
- A manual rate edit on an entry (236-238) changes only that entry's profit; inventory untouched.
- An inventory failure never passes silently: alert.
- Manual lines CAN be deleted since 228 (crm_eliminar_entrada_calculadora accepts source manual): deleting one returns its CUP.
- Cards are stored by name + optional last 4 digits (no full card number).

## Current state (mapped 2026-10-14)
- No sending-card model exists (only beneficiary receiving cards in remittance_beneficiaries, deposit accounts
  depositos_mmg). account_id is the tenant.
- CUP op completion is human: crm_entregar_operacion (101) -> completed -> trigger feeds calculator_feed_operation
  (235) inside EXCEPTION WHEN OTHERS (audits calculator_feed_failed, never blocks delivery). cup_rate from
  calculator_rates_vigentes usdt_sell_cup (235:126, 182).
- Manual: crm_registrar_entradas_manuales (228:74), Guyana day, advisory lock calculator-cut:<account>.
- Void paths: trigger 104:375 (op leaves completed -> entry void), 226 delete (chat entries only).
- Delivery UI: src/components/inbox/operations/complete-transfer-*.tsx, route deliver.

## Phases
1. Inventory CUP: tables + admin screen (cards, lots, balance, remaining limit today). <- this document's first slice
2. Automatic deduction on completion and manual registration, FIFO + split, lot rate for CRM ops, return on void.
3. Delivery panel shows "usa tarjeta X: n" and the wait-until-tomorrow warning.

## Phase 1 scope
- Migration 239 (+ROLLBACK, staging assertion): tables cup_cards (account_id, name, last4, priority, daily_limit_cup
  default 120000, active, timestamps), cup_lots (card, amount_cup, remaining_cup, rate_cup_per_usdt, loaded_at, note,
  created_by), cup_lot_consumptions (lot, entry/operation refs nullable, amount_cup, consumed_at, cuba_day) - empty in
  phase 1, created now so the report computes remaining limit. RLS: members read; writes only through admin
  SECURITY DEFINER RPCs: save card (create/update/reorder/deactivate), load lot, correct/delete a lot only while
  unconsumed, inventory report (per card: balance, lots, used today and remaining limit for the current Cuba day).
- API routes + tests; admin-only page "Inventario CUP" (Spanish), sidebar entry for admins, i18n es/en.
- Out of scope in phase 1: any deduction, delivery panel, bot.

## Constraints
- Staging first; production only with explicit go-ahead. Conventional Commits, no AI trailer. Do not restyle.
- TDD strict (RED -> GREEN -> REFACTOR). Runner `npm test` (vitest); SQL assertions in supabase/staging/assertions/.
- RDD off.

## Tasks
- [x] T1 Migration 239 tables + RPCs + rollback + staging assertion (07b3fda; SQL NOT run, pending staging run in T4)
- [x] T2 API routes + tests (fcf8040)
- [x] T3 "Inventario CUP" admin page + sidebar + i18n (+ tests for pure logic) (7310a83)
- [x] T4 Staging apply + deploy + owner check (239 applied, owner checked staging 2026-10-14; delete dialog fixed in 54a7831)
- [x] T5 Production (owner go-ahead 2026-10-14 "pasalo a produccion"; done 2026-10-14, evidence below)
- [x] Phase 2 and 3: planned after phase 1 is in use (phase 2 started 2026-10-15)

### Phase 2: automatic deduction (owner go-ahead 2026-10-15 "podemos seguir con la fase 2")
Owner loaded his real cards and lots in production but is not sure of their current balances: lots stay editable
only while unconsumed, so balances must be confirmed BEFORE phase 2 reaches production.
Rules (owner decisions above) + Claude defaults stated to the owner 2026-10-15:
- Consume on CUP chat entry creation by calculator_feed_operation (op completed) and on manual CUP registration
  (crm_registrar_entradas_manuales). One shared SQL function; advisory lock per account; Cuba day of the completion
  time (manual line dated another day counts toward that day's limit).
- Per card available = min(balance, daily_limit - used that Cuba day); cards by priority, lots FIFO; split.
- CRM entries: cup_rate = amount / sum(part_cup / lot_rate) (exact invertido); manual entries keep the typed rate.
- Insufficient inventory/limit: consume what is available, the rest uses the global rate, and an ALERT is raised
  (existing notifications mechanism). Never silent, never blocks the completion (the feed trigger swallows errors:
  a consumption failure must also alert).
- Void (op leaves completed -> entry void, 104 trigger; entry delete 226): consumed CUP returns to its lots.
- Manual rate edit (236-238) changes only that entry's profit; inventory untouched.
- [x] T6 Migration 240: consume/return functions, hooks in feed + manual registration + void paths, alert; rollback;
      staging assertion (b71f3cd; SQL NOT run, pending staging run in T8)
- [x] T7 Page shows consumptions per lot/card (used today real) + API/read model + tests (de53cb9)
- [ ] T8 Staging apply + deploy + owner check (240 applied, assertion green, deployed e16953e + demo data on staging 2026-10-15; WAITING FOR THE OWNER'S CHECK, do not tick until he confirms)
- [ ] T9 Production (needs go-ahead; owner confirms real balances first)

### Phase 3: delivery panel (owner go-ahead 2026-10-15)
Owner saw the movements on staging and asked that the chat panel of a CUP remesa show it. Owner decision: when no
card has limit, the panel only WARNS and still lets the operator complete.
- Before completion (ready_to_transfer / transferring CUP ops): "Transfiere desde" plan computed read-only with the
  same algorithm as cup_consumir (priority, FIFO, limit of the Cuba day, split), segmented per beneficiary in
  beneficiary order (same greedy fill as consuming the total). Labelled as an estimate: the real deduction happens
  at completion.
- Shortfall: "Faltan X CUP sin tarjeta con límite hoy: queda para mañana" warning; completion not blocked.
- After completion: consumptions of the op's entries (card, lot rate, amount) and the resulting cup_rate.
- Visible to the roles that already see/complete the operation panel; card names + last4 only.
- [x] T10 Migration 241: read-only plan function shared with cup_consumir (refactor so both use one allocator),
      RPC for the panel (plan for an operation + consumptions of a completed one); rollback; staging assertion
      (20ba4db; SQL NOT run, pending staging run in T12)
- [x] T11 Panel UI in the CUP delivery sections + API + tests (1bc6568)
- [ ] T12 Staging apply + deploy + owner check (241 applied, both assertions green, deployed d529d75 + demo plan on staging 2026-10-15; WAITING FOR THE OWNER'S CHECK, do not tick until he confirms)
- [ ] T13 Production together with phase 2 (needs go-ahead; owner confirms real balances first)

## Acceptance criteria (phase 1)
- Admin creates cards A (priority 1) and B (priority 2), loads 500,000 CUP at 960 on A and 250,000 at 1060 on B,
  sees balances and 120,000 remaining limit for today (Cuba day) on each.
- Agents/viewers cannot see the page nor call the write RPCs.

## Progress / evidence
- 2026-10-14: document created after design Q&A and exploration (16102fe).
- 2026-10-14 T1-T3 done. T2/T3 strict TDD: RED observed (missing modules) then GREEN. Final: npx vitest on new files green
  (routes+lib 100 tests, page+lib 95), npm test 201 files / 2724 tests pass, npx tsc --noEmit clean, eslint on changed dirs clean.
  Migration 239 and assertion cup-card-inventory.sql were written without a SQL engine (psql unavailable): UNVERIFIED until T4.
  Open choices made by default: report RPC is admin+ (not any member); lots fully consumed drop out of the report; inactive
  cards hidden unless includeInactive=1; decimal parsing treats a lone "." + 3 digits as thousands (es habit).

- 2026-10-14 T4 staging run (owner-authorized, staging only):
  - Recon: schema_migrations top 238; no cup_* tables; remittance_calculator_entries 42 rows, facturado 1432712.3999999999930000, invertido 1238124.4998984162911480, retorno 194587.9001015837523520.
  - RED: assertion in BEGIN..ROLLBACK failed: type "cup_cards" does not exist.
  - 239 applied (--single-transaction); row ('239','239_cup_card_inventory') inserted. cup_cards / cup_lots / cup_lot_consumptions: RLS enabled, one SELECT policy each, authenticated SELECT only (no anon grants).
    RPCs crm_guardar_tarjeta_cup, crm_cargar_lote_cup, crm_corregir_lote_cup, crm_eliminar_lote_cup, crm_inventario_cup: SECURITY DEFINER, EXECUTE postgres + service_role + authenticated, no anon. cup_cuba_day is a plain helper.
  - First GREEN attempt failed ONE expectation, case 3.priority: the fixture expected the new card at priority 3, but the migration (by design, "max active priority + 1") gives 2 after case 2 moved B to 0.
    Fixture-only fix (b23afa9, test(cup-inventory)); migration unchanged. Re-run: ALL PASS (52 checks); cup_* empty after; entries before = after.
  - Deployed to staging: release b23afa944626b86430bff9a52612b06dc496642b (code identical to 80e8332 plus the fixture), BUILD_ID o49Mmpy6ay0MmpLizEhFm (served by crm.onlinefreedom.site, pm2 cwd = the release, wacrm-staging online, /login 200,
    /inventario-cup 200 page for an unauthenticated request). anterior -> 7e62096f35818f7a50ab9ae25765230efeafdc15. Manifest staging, kolppplawzdsjfydwejr, 0 production refs, sha256 ok. Built WITH the tests (114 passed in node:20).
    prod-build restored to 97ae254, env copy deleted. Transfer used scp + tar (not rsync).
  - Staging redeploy (UI-only fix, no migration): release 54a78315158c9b6ae7f58a0a16af3b65d72b0605 (confirm lot deletion in a dialog), BUILD_ID FDWEDwYnvbbUDsW_G_Nce served by crm.onlinefreedom.site,
    pm2 wacrm-staging online, cwd = the release, /login 200, /inventario-cup 200. anterior -> b23afa944626b86430bff9a52612b06dc496642b. Manifest staging, kolppplawzdsjfydwejr, 0 production refs, sha256 ok, built WITH the tests (6 files passed in node:20).
    prod-build restored to 97ae254, env copy deleted. Rollback: current -> b23afa944626b86430bff9a52612b06dc496642b + pm2 restart wacrm-staging --update-env.
    Rollback: current -> 7e62096f35818f7a50ab9ae25765230efeafdc15 + pm2 restart wacrm-staging --update-env; DB: supabase/migrations/ROLLBACK-239-cup-card-inventory.sql (and delete the schema_migrations row 239).
  - Test data (owner-authorized, through the real RPCs under the owner claim feeccc91..., account 472917ed-fca5-4679-b64c-e76a54089a16):
    PRUEBA Tarjeta A (1111, priority 1, limit 120000) e8d43d7b-cfed-479d-be00-2a4552cea31e, lot 500000 CUP @ 960 5ba110da-ff29-4f8b-98bd-fa568ceb8cb0;
    PRUEBA Tarjeta B (2222, priority 2, limit 120000) d8fd481d-9ffb-4c2b-acaa-716e3eb71401, lot 250000 CUP @ 1060 14b0f9b2-c8af-4698-a6c0-3dae4a4633b7.
    crm_inventario_cup returns both: balances 500000 / 250000, used_today 0, remaining_limit_today 120000 each, cuba_day 2026-10-14.
    Cleanup SQL (staging only):
```sql
BEGIN;
DELETE FROM cup_lots WHERE id IN ('5ba110da-ff29-4f8b-98bd-fa568ceb8cb0','14b0f9b2-c8af-4698-a6c0-3dae4a4633b7');
DELETE FROM cup_cards WHERE id IN ('e8d43d7b-cfed-479d-be00-2a4552cea31e','d8fd481d-9ffb-4c2b-acaa-716e3eb71401');
COMMIT;
```

- 2026-10-14: owner checked staging; asked that deleting a lot use a dialog like editing instead of the browser prompt. Fixed: DeleteLotDialog (src/components/inventario-cup/delete-lot-dialog.tsx); page tests RED 2 -> GREEN 9; npm test 2726 pass; tsc/eslint clean.

- 2026-10-14 T5 production (239 + app b6f1a1c, code = staging release 54a7831):
  - Backup `~/wacrm-respaldos/produccion-20261015T030158Z.dump` (111 data tables, 320 functions, sha256 18cbca43d9ee92d0...).
  - Recon: last schema_migrations row 20261014225919 / 238; no cup_* objects; helper absent; ACL convention postgres + authenticated; entries 122 rows, facturado 4536577.40, invertido 4111053.0781553398064480, retorno 425524.3218446602358520.
  - `~/cerebro-fase1/pruebas/gate140-aplicar-db.py` (copy of gate139, bundle 239 only, bundle md5 4bee891078e7b3176772fa47d741d41e): `quien` -> postgres; `ensayo` (rolled back) -> 3 tables, RLS true on all, new RPC md5s
    (crm_cargar_lote_cup 150a093e, crm_corregir_lote_cup 8b9a3ad7, crm_eliminar_lote_cup c51d7c25, crm_guardar_tarjeta_cup 20100bf1, crm_inventario_cup b2227744, cup_cuba_day 573730aa), untouched functions identical
    (calculator_feed_operation 31c256da, crm_cierre_financiero c903a471, crm_corregir_tasas_entrada_calculadora b0e97962, crm_registrar_entradas_manuales d1f2b48c, is_account_member cea73e60), entries identical; `aplicar` -> {"r":"OK"}, row 20261015030414 / 239_cup_card_inventory.
  - After: RLS enabled + one SELECT policy per table; authenticated SELECT only on tables (no anon); the 5 RPCs SECURITY DEFINER, anon false, authenticated true; cup_cuba_day plain, same grants.
    cup_cards/cup_lots/cup_lot_consumptions EMPTY (0/0/0; no test data in production, the owner loads his real cards); entries identical to before; helper zz_wu5b_exec dropped (count 0); temp n8n workflows deleted. Assertion NOT run in production.
  - App: release b6f1a1c97be75ed95d84397d326d643d9e8ac5fa built in prod-build (node:20 docker, NEXT_PRIVATE_OUTPUT_TRACE_ROOT=$PWD, main .git mounted read-only, WITH tests: 114 passed; manifest production, hqztotshnlzaiziwjyzh, 0 staging refs),
    BUILD_ID CLs9uvPcwCjBlTN-NgTV2. Deployed with desplegar-wacrm-produccion.sh: pm2 wacrm online, /proc cwd = the release, domain serves the BUILD_ID, /login 200, /inventario-cup 200.
    Rollback: anterior -> 97ae254ab8a8bd7bd53e06e668b834a22b382469 (rollback-wacrm-produccion.sh); DB ROLLBACK-239 through the gate route. prod-build left at b6f1a1c.

- 2026-10-15 T6/T7 (phase 2), written locally without a SQL engine (psql unavailable): UNVERIFIED until the T8 staging run.
  - 240: cup_consumir / cup_devolver / cup_alertar (internal, revoked from authenticated/anon/service_role); alert = notifications type
    'inventario_cup' (check carried forward from 231) to owners/admins. Hooks: calculator_feed_operation (consumes BEFORE the INSERT of a
    fully priced CUP line that will be inserted/revived; links the consumptions after; exception caught inside -> global rate + alert),
    crm_registrar_entradas_manuales (typed rate kept; Cuba day = line date if not today), void trigger 104 (cup_devolver per voided CUP
    line, own subtransaction + alert), crm_eliminar_entrada_calculadora 228 (returns CUP; failure fails the delete),
    crm_inventario_cup (+consumptions_today). Return deletes the consumption rows. Rate edits 236-238 untouched.
    Replaced-body md5s (migration text) are in the 240 header. Assertion: supabase/staging/assertions/cup-inventory-consumption.sql.
  - Correction to the plan: manual entries CAN be deleted since 228 (crm_eliminar_entrada_calculadora accepts source manual), so they
    return their CUP too.
  - Owner rule "every completed CUP operation consumes inventory": crm_resolve_pending_entry (235 body, md5 51ceb370...) is hooked in 240 too (same
    consume/rate/alert logic, never aborts the resolve, idempotent per entry); assertion case 11.
  - T7 strict TDD: RED 4 failed (read-model + page) then GREEN; npx vitest run (cup-inventory, page, api, i18n) 14 files / 151 tests pass;
    npm test 201 files / 2730 pass; tsc and eslint clean.

- 2026-10-15 T8 staging run (owner-authorized, staging only kolppplawzdsjfydwejr; production, MCP, push untouched):
  - Recon: schema_migrations top 239. md5(prosrc) on staging equals the 240 header for all six replaced functions (calculator_feed_operation 1a9b5bc1, crm_registrar_entradas_manuales 1390c523,
    crm_eliminar_entrada_calculadora 497ed115, remittance_operations_calculator_feed 71ecdeaa, crm_inventario_cup a76c03d6, crm_resolve_pending_entry 51ceb370): no drift.
    Snapshot: entries 42, facturado 1432712.3999999999930000, invertido 1238124.4998984162911480, retorno 194587.9001015837523520; one lot only (A 500000/500000) and 0 consumptions: the
    phase 1 lot of PRUEBA Tarjeta B (14b0f9b2...) no longer existed (deleted by the owner during his phase 1 check).
  - RED: assertion in BEGIN..ROLLBACK failed (FAILs, then ERROR function cup_consumir(...) does not exist).
  - 240 applied (--single-transaction, ON_ERROR_STOP) + row ('240','240_cup_inventory_consumption'). cup_consumir / cup_devolver / cup_alertar: EXECUTE false for anon, authenticated and service_role.
  - GREEN: first run 2 FAIL, both fixture arithmetic (case 8: A remaining is 370000 = 500000 - 120000 today - 10000 yesterday, not 380000; B after deleting the manual line is
    250000-30000-15000-75000+15000 = 145000, the formula forgot the 15000). The migration was right; fixture-only fix e16953e. Re-run: 50 PASS, 0 FAIL, rc 0.
    Snapshot after = before (entries and lots identical, 0 consumptions).
  - Deploy: release e16953e61c5dbe4924d0bd13a2773e9ffce303bb (code identical to c5f5f7a, plus the assertion fixture), built in prod-build with node:20 docker, WITH the whole suite (201 files / 2730 tests passed),
    BUILD_ID ArLq7lOIP-tj1dMKVb9jo served by crm.onlinefreedom.site. Manifest staging, kolppplawzdsjfydwejr, 0 production refs, sha256 2864b7c1d04040cd6a891e1289aeae9e527943caffc2b916d8a29a9a2ad97c88.
    oracle2: current -> e16953e, anterior -> 54a78315158c9b6ae7f58a0a16af3b65d72b0605; pm2 wacrm-staging online, /proc cwd = the release, /login 200, /inventario-cup 200.
    prod-build restored to b6f1a1c97be75ed95d84397d326d643d9e8ac5fa, env copy deleted.
    Rollback app: ln -sfn ~/wacrm-releases/54a78315158c9b6ae7f58a0a16af3b65d72b0605 current + pm2 restart wacrm-staging --update-env. DB: supabase/migrations/ROLLBACK-240-cup-inventory-consumption.sql (and delete schema_migrations row 240).
  - Demo data (persisting; real paths under the owner claim feeccc91..., account 472917ed...; contact PRUEBA TASAS 56588e14..., conversation aa1a1fad...; a new lot 250000 @1060 on B,
    98e92c82-b79b-474f-b5df-92ab69bcd01f, was loaded through crm_cargar_lote_cup because the old one was gone). Operations inserted ready_to_transfer with a 'PRUEBA INVENTARIO' beneficiary and moved to completed:
    (a) 50,000 CUP, op 53083958-2c31-438a-b6d7-5411f574a0a9, entry db1ddef5-7a70-42c3-b900-2e8186b83ac1: 50,000 from A @960; cup_rate 960, facturado 16666.67, invertido 12500, retorno 4166.67.
        After: A balance 450,000, used today 50,000, remaining limit 70,000; B untouched.
    (b) 100,000 CUP, op 12ef2f85-d6af-4d04-bda9-8e045102cbc3, entry 51fe985c-4a4f-4dd5-b9ba-58b0904cbe46: 70,000 from A @960 (its limit) + 30,000 from B @1060; cup_rate 987.9612 (= 100000/(70000/960+30000/1060)),
        facturado 33333.33, invertido 24292.45, retorno 9040.88. After: A 380,000 / used 120,000 / limit 0; B 220,000 / used 30,000 / limit 90,000.
    (c) manual "• PRUEBA INVENTARIO manual 15,000 cup (240/1000)", entry 9b237b66-caba-45a5-8eb0-90c7df288814 (date 2026-10-14): 15,000 from B @1060; cup_rate stays NULL, typed invertido 3600 kept (facturado 5000, retorno 1400).
        After: B 205,000 / used 45,000 / limit 75,000.
    Amounts carry a 1e-12 residue (50000.000000000001, 99999.999999999999) because the test ops were quoted in GYD with the global rate 3 (16666.67 x 3). The notifications table has 0 'inventario_cup' rows and no new rows: no alert fired.
    entries 42 -> 45; cup_lot_consumptions: 4 rows (af2cd978, 68aff475, 1dd20596, 2dc7c2cc).
  - Cleanup SQL of the demo (staging only; verified in a rolled-back dry run: the three entries become void/deleted, every consumption returned, A 500000, B 250000, 0 consumptions):
```sql
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub','feeccc91-5c2d-446e-8366-21e97ceeb23f','role','authenticated')::text, true);
SELECT crm_eliminar_entrada_calculadora(x) FROM unnest(ARRAY['db1ddef5-7a70-42c3-b900-2e8186b83ac1','51fe985c-4a4f-4dd5-b9ba-58b0904cbe46','9b237b66-caba-45a5-8eb0-90c7df288814']::uuid[]) x;
-- optional, once the lot is back to 250000 (then editable): SELECT crm_eliminar_lote_cup(...) / the phase 1 cleanup above
COMMIT;
```

- 2026-10-15 T10/T11 (phase 3), written locally without a SQL engine: 241 UNVERIFIED until the T12 staging run.
  - 241: cup_planificar(account, amount, cuba_day) is the single allocator (read-only, internal, revoked from all roles); cup_consumir (240 body, md5 0e6e3a21...) now only
    writes the parts it returns. diff of the two bodies shows only the allocation block changed; equivalence argument in the 241 header (same advisory lock held, same
    ordering, per-lot FOR UPDATE kept). ROLLBACK-241 restores the 240 text (md5 verified 0e6e3a21...). RPC crm_inventario_cup_operacion(op): agent+ of the account (viewer refused),
    states plan | completed | no_inventory | no_amounts | not_cup | unavailable; plan segmented per beneficiary by cumulative ranges over ONE plan of the total of the CUP
    beneficiaries' amounts (position order); grants EXECUTE postgres + authenticated. Assertion: supabase/staging/assertions/cup-inventory-panel.sql (8 cases).
  - T11 strict TDD: RED (panel lib 0 tests/module missing, route 8 failed, wiring 3 failed) then GREEN. GET /api/remittance-operations/[operationId]/cup-plan (agent+, beta flag);
    src/lib/cup-inventory/panel.ts; src/components/inbox/operations/cup-plan-block.tsx wired through an optional `extra` slot of both complete-transfer sections (container
    passes it) and in remittance-operation-card.tsx for completed operations; i18n Inbox.operationsPanel.cupPlan es/en (add-only). The block shows nothing on any failure.
    npm test 204 files / 2758 pass, tsc and eslint clean.

- 2026-10-15 T12 staging run (owner-authorized, staging only kolppplawzdsjfydwejr; production, MCP, push untouched):
  - Recon: schema_migrations top 240; md5(prosrc) cup_consumir on staging = 0e6e3a2111e798735c4ba4c681054504, equal to the 241 header: no drift.
    Snapshot: entries 45, facturado_gyd 1487712.3999999999930000, invertido_gyd 1278516.95272860497039600000, retorno_gyd 209195.44727139507310400000; lots A 380000 / B 205000; 4 consumptions.
  - RED: cup-inventory-panel.sql in BEGIN..ROLLBACK failed (function crm_inventario_cup_operacion(uuid) does not exist).
  - 241 applied (--single-transaction, ON_ERROR_STOP) + row ('241','241_cup_inventory_panel'). cup_consumir md5 now 6686341131868928e9a89a14808bcd1b.
    cup_planificar: EXECUTE false for anon, authenticated, service_role. crm_inventario_cup_operacion: authenticated true, anon false, service_role false.
  - GREEN: first run 1 FAIL, case 5 "CUP beneficiary without amount -> no_amounts": the fixture operation is quoted at 2000 CUP by the trigger and a LONE CUP beneficiary
    takes the quoted CUP by design (state plan, total 2000). Migration right; fixture-only fix d529d75 (two beneficiaries without amount). Re-run: cup-inventory-panel ALL PASS and
    the phase 2 cup-inventory-consumption ALL PASS (regression of the cup_consumir refactor), both rolled back; snapshot after = before.
  - Deploy: release d529d758ffdbfccf34bb2d04ce7265a2611ffcb9 (code = a7a9fb6 plus the fixture), built in prod-build with node:20 docker WITH the whole suite (204 files / 2758 tests) and the build's own money-route tests (114),
    BUILD_ID L7ewpv0yW7GW1ztpmwkr1 served by crm.onlinefreedom.site. Manifest staging, kolppplawzdsjfydwejr, 0 production refs, sha256 032c9fd18a072f5adcbef69777d187e28d5a50ac7c89a651807c37c26fda8e51.
    oracle2: current -> d529d75, anterior -> e16953e61c5dbe4924d0bd13a2773e9ffce303bb; pm2 wacrm-staging online, /proc cwd = the release, /login 200. prod-build restored to b6f1a1c, env copy deleted.
    Rollback app: ln -sfn ~/wacrm-releases/e16953e61c5dbe4924d0bd13a2773e9ffce303bb current + pm2 restart wacrm-staging --update-env. DB: supabase/migrations/ROLLBACK-241-cup-inventory-panel.sql (and delete schema_migrations row 241).
  - Beta flag: the cup-plan route needs profiles.beta_features to contain operations_panel; the owner profile feeccc91... already has {operations_panel}. Nothing changed.
  - Demo (persisting): the Cuba day rolled over (2026-10-15) so card limits are fresh (A 120000, B 120000); the 60,000 + 50,000 example would not show a shortfall, so the amounts are 150,000 + 110,000.
    Operation 008deb15-fc2e-43ac-bd32-9d4c1aa8b01e (conversation aa1a1fad..., ready_to_transfer, NOT completed), beneficiaries 514c6e39-9196-406c-b414-bf11c3941f08 (150,000) and b6297f15-7239-4999-b196-2d19dc1c6f13 (110,000).
    Panel RPC: state plan, estimate true, total 260000, planned 240000, missing 20000, effective_rate 1007.52; beneficiary 1: A 120000 + B 30000; beneficiary 2: B 90000, missing 20000. Nothing written (entries 45, consumptions 4).
    Completed op 12ef2f85 (T8 b): state completed, Salio de B 30000 @1060 + A 70000 @960 (69999.999999999999), cup_rate 987.96; op 53083958 (T8 a): A 50000 @960, cup_rate 960.
    Cleanup: DELETE FROM remittance_beneficiaries WHERE operation_id='008deb15-fc2e-43ac-bd32-9d4c1aa8b01e'; DELETE FROM remittance_operations WHERE id='008deb15-fc2e-43ac-bd32-9d4c1aa8b01e'; (staging only; plus the T8 cleanup above).

## Next step
T12 is deployed on staging: the owner checks the delivery panel on operation 008deb15 (ready_to_transfer). T8/T9/T13 wait on the owner's check and real balances.
