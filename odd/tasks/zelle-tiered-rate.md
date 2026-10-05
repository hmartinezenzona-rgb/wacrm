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
- [ ] T2 App mirror
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
