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
- [x] T1 Map the recharge / saldo cost flow (feed, manual lines, rates UI) and confirm the tier rule (findings below; recorded in 4837440's doc commit)
- [x] T2 Migration 242: 500-tier cost rate + feed uses the tier; rollback; assertion (991c368; SQL assertions pending staging run T5)
- [x] T3 Same migration 242: crm_corregir_tasas_entrada_calculadora(+p_costo_usdt), chat + manual (991c368; pending staging run T5)
- [x] T4 UI: rates panel field + Editar cost fields + read model + tests (4837440)
- [ ] T5 Staging apply + deploy + owner check (needs authorization)
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

## Next step
T5: staging apply of 242 + run recarga-tier-cost.sql + deploy + owner check -- needs explicit owner authorization (no remote work done).
