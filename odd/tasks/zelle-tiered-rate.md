# Feature: Zelle tiered rate

## Objective
Zelle is priced by tiers of USD received, as Osmany asked:
- 260 GYD per USD for 50 to 999 USD;
- 250 GYD per USD for 1,000 to 1,999 USD;
- 245 GYD per USD from 2,000 USD up.
The customer always gets the best tier the deposit reaches. Every Zelle quote and amount (bot, panel, calculator)
uses the same rule.

## Problem (2026-10-05)
- One rate (calculator_rate_versions.usdt_sell_gyd, 260, exposed by the `tasas` view and crm_tasa_vigente('usd')) is
  shared by Zelle, Clasica, Tropical, USDT, Mexico and the bot's "usd" rate. There are no tiers.
- Yoandrys' operation 9166f4be (production) was quoted wrong: a 250,000 GYD deposit gave 961 USD at 260
  (249,860 billed). With the tiers it is 1,000 USD at 250 (250,000 billed, 240,000 invested, 10,000 return).

## Owner decisions (2026-10-05)
- Zelle only for now. Clasica, Tropical, USDT and Mexico keep the single rate.
- The tier comes from the TOTAL of the deposit ("es lo que deposita"), not from each part of a split deposit.

## Defaults chosen by Claude (stated to the owner, open to change)
- Tiers live in configuration (not in code, not in calculator_rate_versions), so they can change without a
  migration.
- From GYD: the tier is the best one whose floor(gyd / tier_rate) reaches the tier's minimum USD
  (floor(gyd/245) >= 2000 -> 245; floor(gyd/250) >= 1000 -> 250; else 260).
- A deposit split between Zelle and a card: the tier comes from the deposit's total converted to USD with the
  Zelle tiers.
- The Zelle minimum stays 13,000 GYD (50 x 260).
- The calculator's invested side keeps usdt_buy_gyd; only the selling rate of a Zelle line is tiered.

## Owner decision (2026-10-05, later)
- Rates vary, so the Zelle tier prices must be editable where the other rates are: the Calculator. Option 1: three
  Zelle price fields (one per tier), not a discount relative to the USDT sale rate.
- Approved layout for "Tarifas Globales": titled groups with equal-width fields, stacked on mobile, one "Guardar
  tasas" button for everything.
  - Compra: Compra USDT (GYD).
  - Venta: Venta USDT (GYD) (renamed from "Venta USDT/Zelle"), Venta USDT (CUP).
  - Zelle por tramo: a small table "Desde / Precio" with fixed minimums 50, 1,000, 2,000 USD and editable prices.
  - Cuba: Tarifa CUP global.
  - Otros: Efectivo USD (GYD por dólar), Recarga: costo (USDT).

- A customer who asks for an amount below a tier pays it at its own tier's price (999 USD -> 999 x 260 = 259,740
  GYD); nobody is rounded up to the next tier. To check in T3/T4: with a 999 USD objective, a 259,740 GYD deposit
  (1,038 USD at 250 when converted from GYD) must still send 999.

## Owner decision (2026-10-05, after seeing staging)
The grouped layout still looks disorganised. Approved replacement for "Tarifas Globales":
- a dropdown "Tasa a cambiar" listing every rate (Tarifa CUP global, Compra USDT (GYD), Venta USDT (GYD), Venta USDT
  (CUP), Zelle desde 50 USD, Zelle desde 1,000 USD, Zelle desde 2,000 USD, Efectivo USD (GYD por dólar), Recarga: costo
  (USDT)); the value field shows the selected rate's current value; "Actualizar" saves only that rate;
- below, a read-only "Tasas actuales" list with every rate, refreshed right after an update.

## Scope
- T1 DB (migration 215 + ROLLBACK + assertion zelle-tiered-rate.sql):
  - the tier config and `cerebro_tasa_zelle(p_usd)` / `cerebro_zelle_usd_desde_gyd(p_gyd)`;
  - Zelle readers switched: crm_calcular_monto_destino, crm_monto_resto_zelle, cerebro_aplicar_reparto (tier from the
    deposit total), cerebro_resolver_operacion_beneficiario, cerebro_fijar_objetivo, calculator_feed_operation (ZELLE
    line), crm_resolve_pending_entry, the {tasa_usd} service placeholder;
  - existing assertions pinning 260 stay valid (tier 260); new cases for >= 1,000 and >= 2,000 USD.
- T2 App: src/lib/calculator/document-rates.ts mirrors the tiers for Zelle; vitest.
- T3 Cerebro (n8n): calcular_usd / calcular_usd_desde_gyd and the "TASAS DE HOY" block quote Zelle by tier; the bot may
  tell a customer just below a tier that a bit more gets the better rate. Dry run, node --check, offline harness.
- T4 Owner test on staging.
- T5 Production after the go-ahead.
- T6 Correct Yoandrys' 9166f4be in production after the owner's OK (beneficiary 1,000 USD, ZELLE line at 250).

## TDD
Strict. SQL assertions (self-reverting DO blocks, own fixtures, rechecked with every promo discarded), vitest for
the app, offline harness for n8n code.

## Tasks
- [x] T1 DB 215 (staging only)
- [x] T1b DB 216: the three Zelle tier prices move to calculator_rate_versions (versioned, admin-edited from the
  Calculator); the helpers read them from the current rate version instead of cerebro_config.
- [x] T2 App: the Calculator "Tarifas Globales" redesign with the Zelle tier table, the rates API, and the
  document-rates mirror
- [x] T2b App: the owner found the grouped layout still messy (staging 4df2cd5). Replace it with a single-rate editor
  (dropdown + value + "Actualizar") and a read-only "Tasas actuales" list.
- [ ] T3 Cerebro tools and context
- [ ] T4 Owner test on staging
- [ ] T5 Production
- [ ] T6 Yoandrys correction

## Progress
- 2026-10-05 document created.
- 2026-10-05 T1 done on staging, commit d5283f5 (migration 215 recorded in schema_migrations, version 215).
  - Config: cerebro_config key `zelle_tiers` (JSON [{min_usd, rate_gyd}], seeded 50/260, 1000/250, 2000/245). Helpers (service_role only): cerebro_zelle_cotizar_gyd(gyd) -> (usd, tasa), cerebro_tasa_zelle(usd), cerebro_zelle_usd_desde_gyd(gyd). Missing config falls back to crm_tasa_vigente('usd').
  - Switched: crm_calcular_monto_destino (zelle only), crm_monto_resto_zelle, cerebro_aplicar_reparto (tier from the deposit total), cerebro_resolver_operacion_beneficiario (Zelle accounts), cerebro_fijar_objetivo (USD -> GYD), calculator_feed_operation (ZELLE line), crm_resolve_pending_entry (ZELLE line when the deposit reaches a tier above the base; base tier keeps the admin-entered rate; still requires a sell rate).
  - RED: assertion before 215: `function cerebro_zelle_usd_desde_gyd(numeric) does not exist` (case 1, first line).
  - GREEN: `ERROR: ALL PASS (rolled back on purpose)`, as is and with promos discarded.
  - Regression (as is and promos discarded, all unchanged vs before 215): PASS reparto-keeps-zelle, reparto-guards, split-deposit-minimums, requested-amount-target (+split helper), target-origin-label (+both helpers), calculator-access/cash/entries-realtime/entry-correction/recarga, resolve-pending, deal-free-money-rules, visa-model, combo-model, zelle-remainder-amount, reparto-usd-card-rail, reparto-auto, zelle-confirmed-name. NOT VERIFIABLE (fail identically with 215 rolled back, pre-existing): destination-amount and rounding-parity (`cannot insert into view "tasas"`), deterministic-usd-destination (deal produces no operation). No expectation was changed.
  - Rollback: apply 215 then ROLLBACK-215 in one transaction: md5 of the 7 redefined functions equal the pre-215 ones, helpers and config gone; transaction rolled back.
  - Open: {tasa_usd} in cerebro_servicio_get is only in the cash (efectivo_usd) text, left as is. Zelle base tier is the configured 260, no longer follows usdt_sell_gyd. Zelle + Clasica/Tropical single-currency repartos keep the legacy single-rate sum. 259,740 GYD is 1,038 USD at 250 (not 999 at 260).
- 2026-10-05 T1b done on staging, commit 823db98 (migration 216 recorded in schema_migrations, version 216).
  - Columns on calculator_rate_versions: zelle_sell_gyd (tier from 50 USD), zelle_sell_gyd_1000, zelle_sell_gyd_2000; nullable, CHECK > 0 and < 1e9. Minimums stay fixed in code/SQL.
  - New reader cerebro_zelle_tiers() (newest version, service_role only); cerebro_zelle_cotizar_gyd and cerebro_tasa_zelle now read it (same selection rule as 215). crm_set_calculator_rates accepts the three keys (carry-forward, NULL clears, same validation). The seven Zelle readers of 215, calculator_missing_rates and the `tasas` view are unchanged.
  - Fallback for a NULL price: base tier -> usdt_sell_gyd (crm_tasa_vigente('usd')), 1,000 tier -> base price, 2,000 tier -> 1,000 price. Zelle lines are therefore never pending for lack of a Zelle price.
  - cerebro_config 'zelle_tiers' removed (single source of truth); ROLLBACK-216 restores it.
  - Seed: calculator_rate_versions is append-only (trigger), so the migration appended ONE new version per account (staging: 1) carrying the rates forward plus 260/250/245. The rollback cannot delete it (it stays, without the columns).
  - RED: assertion zelle-tier-prices.sql before 216: `record "v_rates" has no field "zelle_sell_gyd"`. GREEN after 216: `ALL PASS (rolled back on purpose)`, as is and with promos discarded.
  - Regressions after 216 (as is and promos discarded): PASS zelle-tiered-rate (215), reparto-keeps-zelle, reparto-guards, split-deposit-minimums, requested-amount-target, target-origin-label, calculator-access/cash/entries-realtime/entry-correction/recarga, resolve-pending, deal-free-money-rules, visa-model, combo-model, zelle-remainder-amount, reparto-usd-card-rail, reparto-auto, zelle-confirmed-name, rate-versions. Still failing exactly as before 215/216 (pre-existing): destination-amount and rounding-parity (`cannot insert into view "tasas"`), deterministic-usd-destination (case 2d, deal produces no operation).
  - Rollback round trip: ROLLBACK-216 on the applied 216 inside one rolled-back transaction: md5 of crm_set_calculator_rates (019e7e76...), cerebro_zelle_cotizar_gyd (708f51e6...), cerebro_tasa_zelle (379775ef...) equal the pre-216 ones; columns, cerebro_zelle_tiers gone; config row back.
  - Note: with custom prices the rule is unchanged (floor(gyd/price) >= minimum), so with 265/255/250 a 250,000 GYD deposit is 943 USD at 265 (it does not reach 1,000 USD at 255); 255,000 is 1,000 USD at 255.
- 2026-10-05 T2 done, commit d50d0fa.
  - API: GET/POST /api/calculator/rates read and write zelle_sell_gyd, zelle_sell_gyd_1000, zelle_sell_gyd_2000; CalculatorRates gains zelleSellGyd, zelleSellGyd1000, zelleSellGyd2000. /api/calculadora (compra/venta summary) not touched.
  - document-rates.ts mirrors the DB: zelleTiers, zelleRateForUsd, zelleQuoteFromDeposit; ZELLE deriveAmountFromDeposit and the deposit snapshot use the tier of the deposit; same NULL fallback; Clasica/Tropical/USDT unchanged.
  - Calculator "Tarifas Globales": titled groups Compra / Venta (label now "Venta USDT (GYD)") / Zelle por tramo (table Desde / Precio, 50, 1,000, 2,000 USD, prices editable) / Cuba / Otros, one "Guardar tasas" button, ids and disabled={ratesLocked} kept; CSS grid auto-fit in calculadora.module.css using the existing theme tokens (own tier table class, because legacyParsedTable collapses to cards on phones).
  - RED: document-rates tests (9 failed), rates route tests (4 failed), page tests (5 failed) before the code. GREEN: document-rates 40/40, rates route + read-model, page 32/32.
  - Checks: `npm run typecheck` clean, eslint on touched dirs clean, full `npm test`: 155 files, 1968 tests passed.
  - NOT VERIFIED: the page was not seen in a browser (no visual check of light/dark or phone width); production untouched; the n8n bot (T3) still quotes by its own tools.
- 2026-10-05 staging app: release 4df2cd5 (BUILD_ID gR4U55B6afspVgjgiP2f5), served by crm.onlinefreedom.site; 0
  production refs; build contains zellePrecio1000; anterior -> 857a15c. build-wacrm.sh needs /home/onlinefreedom/wacrm/.git
  mounted in the container (prod-build's .git points there). Waiting for the owner's look at the Calculator layout.
- 2026-10-05 T2b done, commit a0c96e6.
  - Calculator "Tarifas Globales" is now the owner-approved single-rate editor: dropdown "Tasa a cambiar" (9 rates, Spanish labels), "Nuevo valor" field filled with the selected rate's current value, "Actualizar" posts only that key (snake_case) plus expectedVersionId (omitted when no version exists; the RPC carries the other rates forward). Below, read-only "Tasas actuales" list (dl, "—" when unset) refreshed from the response, with an "Tasa actualizada." confirmation. Invalid (empty, <= 0, NaN) is not sent. 403/409/generic messages kept; dropdown, field and button disabled while locked or saving. Page state is now one `rates` object (the nine per-rate states and the grouped-fields CSS are gone); `tarifa` for the manual calculator derives from it.
  - RED: 14 new page tests failed before the code. GREEN: page.test.tsx 33/33.
  - Checks: `npm run typecheck` clean, eslint on touched files clean, full `npm test` 155 files / 1969 tests passed (one earlier full run showed 1 failure that did not reproduce in two reruns; not identified).
  - NOT VERIFIED: browser (light/dark, phone width); staging not redeployed with this commit.
- 2026-10-05 staging app: release 0b9b249 (BUILD_ID Q5C_8vDGw_DvoboE9y6RJ, single-rate editor), served; 0 production
  refs; anterior -> 4df2cd5. Waiting for the owner's look.
