# Feature: per-tier recharge cost and per-operation cost edit (recargas / saldo móvil)

## Objective
The Calculator/Finanzas investment of ETECSA recharges and saldo móvil reflects what Osmany really pays:
(1) two recharge costs, one per ETECSA promotion tier (starts at 500 CUP / starts at 600 CUP), each recharge costed
with its tier; (2) from "Editar" in Control Semanal, an admin can change the cost in USDT of one recharge or saldo
operation (provider discount, cheaper provider), recomputing invertido/retorno everywhere.

## Owner facts (voice notes 2026-10-16, Engram negocio/recargas-saldo/costos-osmany)
- Promo from 500 CUP: provider 19.5 USDT; sold 5,200 GYD. Promo from 600 CUP: 23.1 USDT (sometimes 22.8); sold
  6,200 GYD. USDT cost 238 or 240 GYD. invertido = cost_usdt x usdt_buy_gyd; retorno = facturado - invertido.
- Saldo móvil: per 360 CUP, provider A 1.6 USDT, provider B 2 USDT; sold 1,000 GYD.
- Owner go-ahead 2026-10-17: "sí, empieza con las dos cosas".

## Current state (production 2026-10-17)
- calculator_rate_versions latest: recarga_costo_usdt 23.1 (ONE value for both tiers), saldo_costo_usdt 2,
  usdt_buy_gyd 240. cerebro_servicios 'recargas' prices 5,200 / 6,200 (no per-tier cost).
- A 500-tier recharge is costed 23.1 x 240 = 5,544 > 5,200 billed -> shown as a loss (real profit ~520).
- Per-entry rate edit (migrations 236-238, crm_corregir_tasas_entrada_calculadora) edits usdt_buy_gyd / cup_rate only;
  manual RECARGA / SALDO_MOVIL rows are refused (unit cost only in raw_line).
- Relevant: migrations 198/199 (recarga_costo_usdt, cerebro_recarga_unidades), 223 (saldo_costo_usdt, SALDO_MOVIL),
  235 feed, 236-238 rate edit, src/lib/calculator/*, Calculadora rates UI.

## Design (Claude defaults, to confirm with the owner when shown)
- Tier of a recharge decided by its sale price per unit (5,200 -> 500 tier, 6,200 -> 600 tier); unknown price ->
  the 600-tier cost (current behaviour) and flagged.
- New global rate field for the 500-tier cost (recarga_costo_usdt stays as the 600-tier cost), editable in the
  Calculator rates panel like the other rates; snapshotted per entry.
- Per-operation cost edit: Editar on a RECARGA / SALDO_MOVIL entry shows "Costo por recarga (USDT)" /
  "Costo por 360 CUP (USDT)" and Compra USDT (GYD); changing them recomputes invertido/retorno; no audit row
  (owner rule for rate edits). Manual lines included when their cost can be read from the typed line.
- Staging first; production only with explicit go-ahead.

## Constraints
- TDD strict (RED -> GREEN -> REFACTOR); runner `npm test` (vitest); SQL assertions in supabase/staging/assertions/.
- Conventional Commits, no AI trailer. Do not restyle. Next migration number after 241.

## Tasks
- [x] T1 Map the recharge / saldo cost flow (feed, manual lines, rates UI) and confirm the tier rule (findings below)
- [x] T2 Migration 242: 500-tier cost rate + feed uses the tier; rollback; assertion (991c368; SQL assertions pending staging run T5)
- [x] T3 Same migration 242: crm_corregir_tasas_entrada_calculadora(+p_costo_usdt), chat + manual (991c368; pending staging run T5)
- [x] T4 UI: rates panel field + Editar cost fields + read model + tests (4837440)
- [x] T5 Staging apply + deploy + owner check (owner checked 2026-10-17: global rates 600 cost 22.8 and saldo 2 saved; Editar on 600-tier entry a2fc9712 -> cost 22.8, invertido 5,472 / retorno 728; manual saldo 69abe03e -> cost 2, invertido 960 / retorno 1,040; facturado unchanged; no server errors)
- [ ] T6 Production (needs go-ahead)

## Acceptance criteria
- A 500-tier recharge with rates 19.5 / 240 shows invertido 4,680 and retorno 520 on 5,200.
- Editing a 600-tier recharge cost to 22.8 recomputes invertido 22.8 x buy; facturado unchanged.
- Editing a saldo entry cost to 1.6 recomputes invertido.

## T1 findings (2026-10-17, read-only)
- Chat feed (calculator_feed_operation, latest body in 240, derived from 235): RECARGA v_sell = cerebro_recarga_precio(deposit) = the
  precio_recarga price the deposit is a whole multiple of (5,200 <-> min_cup 500, 6,200 <-> min_cup 600); amount = units; invertido =
  units x recarga_costo_usdt x usdt_buy_gyd; snapshot cost_gyd = USDT cost per recharge, sale_gyd = price, cup_rate = usdt_buy_gyd.
  SALDO_MOVIL: packages = deposit / cerebro_saldo_precio(); invertido = packages x saldo_costo_usdt x buy; amount shown in 'SM'.
- Tier rule chosen: the precio_recarga row (min_cup) that the per-unit price belongs to, NOT a hard-coded price. It is reliable: the
  price is already required (deposit matching no price is pending 'recargaPrecioGyd'), so "unknown tier" cannot reach the cost. No cleaner
  stored signal exists (no promo amount is stored on the entry). Ambiguity only at multiples of both prices (161,200), where
  cerebro_recarga_precio already prefers the current promotion.
- Rates: calculator_rate_versions (append-only) + crm_set_calculator_rates (latest body 223) + calculator_rates_vigentes; API
  /api/calculator/rates (RATE_KEYS) and the panel (RATE_FIELDS in calculadora/page.tsx). crm_resolve_pending_entry (240) prices a pending
  recharge from the payload cost and is untouched.
- Manual lines: crm_registrar_entradas_manuales stores the client-computed figures + raw_line only (cost_gyd / usdt_buy_gyd NULL). The unit
  cost is slot 1 of "(cost/sale/buy)" ("rec promo(23.1/6.2k/240)"); invertido = typed number x cost x buy (web-calculator calculateLine).
- Rate edit 236-238: refused manual RECARGA/SALDO because no column held the unit cost; the lock trigger (228) does not freeze cost_gyd, so
  the edit can store it.
- Decision: no stop needed.

## Progress / evidence
- 2026-10-17: document created from the owner's voice notes and a read-only production check.
- 2026-10-17 T2/T3 (991c368): migration 242 + ROLLBACK-242 + supabase/staging/assertions/recarga-tier-cost.sql. Replaces
  crm_set_calculator_rates (223 body), calculator_feed_operation (240 body), crm_corregir_tasas_entrada_calculadora (238 body; the 3-arg
  function is DROPped, 4-arg created). SQL not run locally: pending staging run (T5).
- 2026-10-17 T4 (4837440): vitest per-file RED then GREEN (entry-rates, web-calculator, ledger-read-model, both routes, page); npm test
  204 files / 2786 tests pass; npx tsc --noEmit clean; eslint on src/lib/calculator, src/app/api/calculator, calculadora clean.
- Design choices to confirm with the owner: until the 500 rate is set, a 500-tier chat recharge still uses recarga_costo_usdt (no behaviour
  change, not pending); the rate fallback is visible in the entry's cost_gyd snapshot. Pending lines resolved with crm_resolve_pending_entry
  are not tiered.

- 2026-10-17 T5 staging run (owner-authorized, staging only kolppplawzdsjfydwejr; production, MCP, push untouched):
  - Recon: schema_migrations top 241; md5(prosrc) on staging equals the 242 header (calculator_feed_operation fcd4fff9, crm_set_calculator_rates 1dd94c00,
    crm_corregir_tasas_entrada_calculadora 60bc617f): no drift. Snapshot: entries 46, facturado 1516712.3999999999930000, invertido 1302516.95272860497039600000,
    retorno 214195.44727139507310400000; cup_lots 2, consumptions 4, cards 2.
  - RED: recarga-tier-cost.sql in BEGIN..ROLLBACK failed (unknown rate: recarga_costo_usdt_500).
  - 242 applied (--single-transaction, ON_ERROR_STOP) + row ('242','242_recarga_tier_cost') in supabase_migrations.schema_migrations. The 3-arg crm_corregir_tasas_entrada_calculadora is gone;
    the 4-arg has EXECUTE authenticated true, anon false.
  - GREEN: recarga-tier-cost ALL PASS, cup-inventory-consumption ALL PASS, cup-inventory-panel ALL PASS, all rolled back; snapshot after = before (data). calculator-entry-investment-rates
    failed case 15.1 (expected 22023 for a manual RECARGA): the 238 refusal that 242 lifts by design (header: "A manual RECARGA / SALDO_MOVIL is accepted now"). Migration right; fixture-only
    fix 4f4e1f6 (case 15 keeps only DIRECTO refused). Re-run: ALL PASS.
  - Deploy: release 4f4e1f683de2de590145b7a17d15fd0c3d01c257, built in prod-build (node:20 docker, build-wacrm.sh, money-route tests 114 passed), BUILD_ID QksCJOBc2QYY3ldof98D9 served by
    crm.onlinefreedom.site. Manifest staging / kolppplawzdsjfydwejr / 0 production refs, sha256 a9f05e8be6513f57a3563e13777be4ed3e649d747e05054e0d84c34d789bc16a. oracle2: current -> 4f4e1f6,
    anterior -> e80f23679711935bf66d4a4eba3f78fa0fdeb4d4; pm2 wacrm-staging online, /proc cwd = the release, /login 200. prod-build restored to b6f1a1c, env copy deleted.
    Rollback app: ln -sfn ~/wacrm-releases/e80f23679711935bf66d4a4eba3f78fa0fdeb4d4 current + pm2 restart wacrm-staging --update-env. DB: supabase/migrations/ROLLBACK-242-recarga-tier-cost.sql (and delete schema_migrations row 242).
  - Rates (crm_set_calculator_rates under the owner claim): before version ded565f7 recarga_costo_usdt 23.1, recarga_costo_usdt_500 NULL, saldo_costo_usdt 1.25, usdt_buy_gyd 240 (others unchanged);
    after version 311a2e94 recarga_costo_usdt_500 19.5, everything else identical.
  - Demo (persisting; PRUEBA TASAS contact 56588e14..., conversation aa1a1fad..., last message updated; recharge beneficiary 'recarga' with a Cuban mobile, confirmed; completed with crm_cerrar_operacion_manual):
    (a) 500 tier 5,200 GYD, op 6267d3c4-25b2-4772-b1e6-480c3593ef1f, entry a835206b-87b2-43a8-966f-8f3d3948ac70: facturado 5200, invertido 4680, retorno 520, cost 19.5.
    (b) 600 tier 6,200 GYD, op 9fee0cb1-57ac-4e1b-b0cc-7dffc8e94bae, entry a2fc9712-3ef7-4f6a-a2bc-8192c781d94f: facturado 6200, invertido 5544, retorno 656, cost 23.1.
    (c) manual lines (crm_registrar_entradas_manuales, payload from manualEntriesFromText): "• PRUEBA COSTOS 1 rec promo(19.5/5.2k/240)" entry d19641ac-2bb5-4dc1-9d22-b75d2a4cc7c3 (5200/4680/520);
        "• PRUEBA COSTOS 2 saldo movil (1.6/1k/240)" entry 69abe03e-f385-4d2f-a488-bc02f5d83276 (2000/768/1232). entries 46 -> 50.
  - Dry runs (rolled back): 600 entry p_costo_usdt 22.8 -> invertido 5472 (22.8 x 240), retorno 728, facturado 6200; saldo manual line with 1.6 -> unchanged (already 1.6: 768/1232);
    extra: manual recharge with 19 -> invertido 4560, retorno 640.
  - Cleanup SQL of the demo (staging only):
```sql
BEGIN;
SELECT set_config('request.jwt.claims', json_build_object('sub','feeccc91-5c2d-446e-8366-21e97ceeb23f','role','authenticated')::text, true);
SELECT crm_eliminar_entrada_calculadora(x) FROM unnest(ARRAY['a835206b-87b2-43a8-966f-8f3d3948ac70','a2fc9712-3ef7-4f6a-a2bc-8192c781d94f','d19641ac-2bb5-4dc1-9d22-b75d2a4cc7c3','69abe03e-f385-4d2f-a488-bc02f5d83276']::uuid[]) x;
-- optional: the two completed operations and their beneficiaries
-- DELETE FROM remittance_beneficiaries WHERE operation_id IN ('6267d3c4-25b2-4772-b1e6-480c3593ef1f','9fee0cb1-57ac-4e1b-b0cc-7dffc8e94bae');
COMMIT;
```
  - The 500 rate (19.5) stays set on staging; to unset: crm_set_calculator_rates(account, '{"recarga_costo_usdt_500": null}').

## Next step
T5: owner checks staging (crm.onlinefreedom.site, chat PRUEBA TASAS, Calculadora rates + Editar). Then T6 production on explicit go-ahead.
