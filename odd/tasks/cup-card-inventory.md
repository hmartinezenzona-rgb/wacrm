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
- Manual lines cannot be deleted today, so their CUP cannot be returned yet (later).
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
- [ ] T8 Staging apply + deploy + owner check (needs authorization)
- [ ] T9 Production (needs go-ahead; owner confirms real balances first)

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
  - OPEN: crm_resolve_pending_entry (a CUP line pending at completion, resolved later) does not consume; owner to decide.
  - T7 strict TDD: RED 4 failed (read-model + page) then GREEN; npx vitest run (cup-inventory, page, api, i18n) 14 files / 151 tests pass;
    npm test 201 files / 2730 pass; tsc and eslint clean.

## Next step
T8: staging apply of 240 + the assertion + deploy, needs the owner's authorization. Production (T9) needs the owner's go-ahead AND
his real card/lot balances confirmed first (a lot stops being editable once it is consumed).
