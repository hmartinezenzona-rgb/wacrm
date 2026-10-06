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
- [x] T3 Cerebro tools and context (staging only; one open finding: objective 999 USD, see Progress)
- [x] T3b DB 217 (staging only): a requested USD amount keeps its own tier price (the 999 USD objective sends 999)
- [x] T3c DB 218 (staging only): the conversation's recorded USD quote (no objective yet) keeps its tier price
- [x] T4 Owner test on staging
- [x] T5 Production
- [x] T6 Yoandrys correction

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
- 2026-10-05 owner checked the single-rate editor on staging: "se ve mejor". Staging tiers back at 260/250/245
  (cerebro_zelle_tiers()).
- 2026-10-05 T3 done on staging (Cerebro U52y1kSNvhgxvWeb), gate ~/cerebro-fase1/pruebas/gate115-zelle-tiers.py (not repo-tracked, like the other gates). Production Cerebro, notifier and DB untouched.
  - Backups: cerebro-staging-antes-115-20261005T123026.json (before the gate), cerebro-staging-antes-115b-20261005T123123.json (before the description fix). (antes-115-20261005T122351 is the --seco run, same content as 123026.)
  - Nodes changed: `calcular_usd` and `calcular_usd_desde_gyd` (new optional $fromAI param `via`: zelle | clasica | tropical | mexico; empty = Zelle; Zelle quotes through cerebro_tasa_zelle / cerebro_zelle_cotizar_gyd, the others keep the single `tasas` rate; new column `aplica_a`; side effects fijar_objetivo / registrar_cotizacion kept); `Ultima cotizacion` (new column zelle_tramos_texto read live from cerebro_zelle_tiers(), no hardcoded price); `Decisor` (TASAS DE HOY lists "Zelle por tramos, GYD por USD: 260 (50-999 USD), 250 (1,000-1,999 USD), 245 (desde 2,000 USD)" and labels the single rate as Clasica, Tropical, Mexico y USDT; the destination-amount note passes via); `Agente Remesas` system message (ZELLE POR TRAMOS paragraph: price applies to the whole amount, split deposit = total, 999 USD pays its own tier price, no rounding up, one brief mention when just below a tier).
  - RED: harness115.js on the pre-change JSON: 14 FAILED (1,000 -> 260,000, 2,000 -> 520,000, 1,999, 250,000 GYD -> 961, 490,000 -> 1,884, 259,740 -> 999, no tier text). GREEN: same harness on the published workflow: ALL PASS (500 -> 130,000; 1,000 -> 250,000; 2,000 -> 490,000; 999 -> 259,740; 50 -> 13,000; 1,999 -> 499,750; from GYD 250,000 -> 1,000 @250, 249,999 -> 961 @260, 490,000 -> 2,000 @245, 259,740 -> 1,038 @250, 13,000 -> 50; Clasica/Tropical/Mexico unchanged at 260 and 961/1,884). Tool queries run on staging in a rolled-back transaction; Decisor syntax `node --check` OK.
  - Published via the public API: active True, versionId == activeVersionId, 123 nodes, changes present in the live JSON.
  - NOT VERIFIED: no real agent turn (the $fromAI `via` param with default '' was not exercised by the LLM); the owner's staging WhatsApp test is T4.
  - FINDING (owner decision "999 objective sends 999" does NOT hold on staging): with a 999 USD objective (cerebro_objetivo_envio monto 259,740, pedido '999 USD') and a 259,740 GYD deposit, the operation's quoted_destination_amount is 1,038 @250, same as the control without an objective. Nothing reads the objective's `pedido` for the destination: crm_calcular_monto_destino is floor(source / tier rate). Before 215 the same case gave 999 @260 (floor(259,740/260)). Evidence SQL: scratchpad chk115-objetivo999c.sql (self-reverting). No migration written; waiting for the owner.
- 2026-10-05 T3b done on staging (migration 217 recorded in schema_migrations, version 217), commit 6e94105.
  - Rule: when the operation's conversation has an OPEN USD objective X (cerebro_objetivo_envio.pedido 'X USD', cerrado_en NULL) and the deposit lies in [X*p, (X+1)*p) with p = cerebro_tasa_zelle(X) (floor(gyd/p) = X), the Zelle amount is X USD at p. New helper cerebro_zelle_cotizar_op(operation_id, gyd) (service_role only) falls back to cerebro_zelle_cotizar_gyd in every other case.
  - Switched (one call each): crm_calcular_monto_destino, crm_monto_resto_zelle, cerebro_resolver_operacion_beneficiario, calculator_feed_operation, crm_resolve_pending_entry. Unchanged on purpose: cerebro_aplicar_reparto (a split deposit keeps its tier-from-total rule; with a matching objective a reparto still has to add up to the GYD-tier amount), cerebro_fijar_objetivo, the 215/216 helpers.
  - Non-matching deposits keep the 215/216 behaviour (best GYD tier of the deposit, objective ignored): 999 + 300,000 -> 1,200 USD @250; 999 + 260,000 -> 1,040 @250; 999 + 259,739 -> 1,038 @250; 999 + 200,000 -> 769 @260; no objective, 259,740 -> 1,038 @250; closed objective ignored; Clasica keeps the single rate.
  - RED: supabase/staging/assertions/zelle-objective-tier.sql before 217: `case 1: objective 999 + 259,740 GYD must be 999 USD at 260, got 1038 at 250`. GREEN after 217: ALL PASS, as is and with every promo discarded (cases: 999 objective before and after the deposit, no objective, 1000+250,000, 500+130,000, the non-matching cases above, calculator ZELLE line 999 billed 259,740 at 260 vs 1,038 billed 259,500 at 250, pending line resolve, Zelle remainder of a split, bot resolver "999 zelle").
  - Regressions after 217 (as is and promos discarded): PASS zelle-tiered-rate, zelle-tier-prices, split-deposit-minimums, requested-amount-target (+split helpers), target-origin-label (+both helpers), reparto-keeps-zelle, reparto-guards, reparto-auto, reparto-usd-card-rail, zelle-remainder-amount, zelle-confirmed-name, resolve-pending, deal-free-money-rules, visa-model, combo-model, rate-versions, calculator-access/cash/entries-realtime/entry-correction/recarga.
  - Rollback round trip: 217 then ROLLBACK-217 in one rolled-back transaction: md5 of the five redefined functions equal the pre-217 ones (feed 291d25bc..., resolver 359123ef..., calcular 5490fdd8..., resto c6d86945..., resolve_pending 36c6892c...); helper gone.
  - Open: the Cerebro tool calcular_usd_desde_gyd (T3, n8n) still quotes 1,038 @250 for 259,740 GYD when asked from GYD without an objective (correct per the rule); with an objective set, its text is not changed by 217. Production untouched.
- 2026-10-05 parent: re-ran zelle-objective-tier on staging (ALL PASS); test contact 529622896918 reset; T4 owner
  WhatsApp test handed over.
- 2026-10-05 T3c done on staging (migration 218 recorded in schema_migrations, version 218), commit 0e4ec2a.
  - Finding (owner's staging test): the bot quotes with calcular_usd BEFORE the account is given and cerebro_fijar_objetivo refuses until a beneficiary/receipt exists, so no objective existed; 217 did not apply (999 -> 1,038 @250). The quote is in cerebro_ultima_cotizacion (153).
  - Rule: only cerebro_zelle_cotizar_op changes. X = open USD objective, else the conversation's USD quote (destino_moneda 'USD', any tool); same match rule floor(gyd/p) = X with p = cerebro_tasa_zelle(X), else the 215/216 best GYD tier. The objective wins over the quote even when it does not match. CUP quotes are ignored.
  - Recency follows B1.1 (153): quote younger than 24 h counted from the operation's creation (stable, so a late completion bills what the beneficiary got) and newer than the last OTHER closed remesa (the operation itself is excluded, otherwise its own completion would drop the quote in the calculator feed). cerebro_cotizacion_vigente (171, 6 h, GYD quote) is a different table and was not reused.
  - The five readers of 217 already call the helper (verified in pg_proc); cerebro_aplicar_reparto still uses the GYD tier on purpose.
  - RED: supabase/staging/assertions/zelle-quote-tier.sql before 218: `case 1: quote 999 + 259,740 GYD must be 999 USD at 260, got 1038 at 250`. GREEN after 218: ALL PASS, as is and with every promo discarded (quote 999 + 259,740 -> 999 @260 and beneficiary 999; 1000 + 250,000 -> 1000 @250; 500 + 130,000; no quote -> 1,038 @250; CUP quote ignored; non-matching deposits 1200/1040/1038/769; objective 500 + quote 999 + 259,740 -> 1,038 @250 (objective wins, no match); objective 999 + quote 500 -> 999 @260; 25 h quote ignored, 23 h applies, quote older than the last closed remesa ignored; calculator ZELLE line 999 billed 259,740 vs 1,038 billed 259,500).
  - Regressions after 218 (as is and promos discarded): PASS zelle-objective-tier, zelle-tiered-rate, zelle-tier-prices, split-deposit-minimums, requested-amount-target, target-origin-label (run chained with their helpers), reparto-keeps-zelle, reparto-guards, reparto-auto, zelle-remainder-amount, zelle-confirmed-name, resolve-pending, deal-free-money-rules, visa-model, combo-model, rate-versions, ultima-cotizacion, calculator-access/cash/entries-realtime/entry-correction/recarga. reparto-usd-card-rail now fails (`null value in column "conversation_id" of relation "cerebro_destino_pendiente"`, end of the DO block) identically with 218 and 217 rolled back inside the transaction, so it is not caused by 217/218 (it was listed as PASS in the T3b entry; cause not investigated).
  - Rollback round trip: 218 then ROLLBACK-218 then 218 again in one rolled-back transaction: md5 of cerebro_zelle_cotizar_op 343b6c56... (pre-218, equal to the 217 version) after the rollback, a324e302... applied; privileges (anon no, service_role yes) kept.
  - Open: the Cerebro tools themselves are not changed; a quote stays usable for 24 h from the operation's creation. Production untouched.
- 2026-10-05 parent: zelle-quote-tier re-run on staging: ALL PASS. reparto-usd-card-rail's new failure is environment
  (class b of staging-assertions-repair): its fixture takes `FROM conversations ... LIMIT 1` with no open operation, and
  staging's only conversation was the owner's test chat with an open operation, so v_conv is NULL. Not a 215-218
  regression; fixture follow-up. Test contact reset for the owner's 999 USD test.
- 2026-10-05 T4 owner test (staging, test number): "quiero mandar 999 dólares" -> bot quoted 999 USD = 259,740 GYD
  (cerebro_ultima_cotizacion 259740/999 USD); Zelle account by e-mail saved (beneficiary zelle). Simulated deposit
  259,740 GYD (owner request) -> "movido", operation f42fbf6b deposit_verification 259,740, beneficiary 999 USD (218
  quote match). Earlier round: 1,000 USD quoted at 250,000. Pending: owner verifies/completes in the panel and checks
  the calculator ZELLE line (expected billed 259,740 at 260). The bot did not mention the lower price from 1,000 USD
  (optional by design).
- 2026-10-05 T4 PASSED: owner verified and completed f42fbf6b ("listo, sí quedó así"). Calculator entry ZELLE 999 USD,
  facturado 259,740, invertido 239,760 (240), retorno 19,980, rate version 2a65978c.
- 2026-10-05 T5 PRODUCTION done (owner go-ahead "si pasalo": migrations 215-218, the app release, Cerebro gate115; nothing else).
  - DB pre-check: the md5 of the 7 functions 215 redefines equal ROLLBACK-215's pre-215 md5 (calculator_feed_operation 5abd9629...,
    cerebro_aplicar_reparto 41a3f79b..., etc.) and crm_set_calculator_rates equals the pre-216 md5 (019e7e76...). cerebro_zelle_*,
    cerebro_tasa_zelle, the 3 calculator_rate_versions columns and cerebro_config 'zelle_tiers' were absent. 215-218 do not touch
    cerebro_servicios (resumen/palabras_clave not involved).
  - Backups: produccion-20261005T203704Z.dump (sha256 f7bfb46ef572f76383eb...; public, auth, storage, cron, realtime,
    respaldos, supabase_migrations, vault; 1,538 TOC entries, 141 table data) and produccion-20261005T203448Z.dump (sha256
    577a9e42b5ea0485...; the respaldar-base.sh default of public/auth/storage; 1,397 TOC entries, 108 table data).
  - Helper zz_wu5b_exec created via the Supabase MCP (SECURITY DEFINER, EXECUTE only for postgres/service_role).
    gate116-aplicar-db.py (BUNDLE 215-218; GATE_BUNDLE=ida-y-vuelta adds the four rollbacks in reverse order):
    - ensayo (rolled back): fingerprint df99e84f... fn=12 chk=7994851f... equal to staging's current one (same query);
    - ida-y-vuelta (rolled back): d4e28c2e... fn=7 chk=- cols=- cfg=0, equal to production's pre-215 state;
    - aplicar {"r":"ok"}: schema_migrations 20261005203959..62 (215-218); production fingerprint now equal to staging's;
    - probar in production, all pass: zelle-tiered-rate, zelle-tier-prices, zelle-objective-tier, zelle-quote-tier, rate-versions,
      resolve-pending, calculator-cash, calculator-recarga, deal-free-money-rules, visa-model, combo-model, operations-board,
      read-rpc, split-deposit-minimums, zelle-remainder-amount, reparto-keeps-zelle, reparto-guards (run one by one).
    - cerebro_zelle_tiers() = 50/260, 1000/250, 2000/245. The newest rate version (the one 216 appended, 6 versions now)
      carries the other rates unchanged (cup 3, buy 240, sell 260, sell CUP 1030, cash 290, recarga 23.1).
    - Helper dropped; ACLs of the 5 new functions: anon and authenticated cannot execute, service_role can; no leftover
      contacts, conversations, users or operations.
  - Cerebro jEzlVLCLUaJhVwzs (gate115, --seco first, then applied; notifier untouched): backups
    cerebro-produccion-antes-115-20261005T144335.json (seco) and ...T144340.json (before the apply). Published: active,
    versionId == activeVersionId, 122 nodes. Changed nodes vs backup: Decisor, Agente Remesas, Ultima cotizacion,
    calcular_usd, calcular_usd_desde_gyd; the first four are byte-identical to staging's published ones; Agente Remesas holds
    the ZELLE POR TRAMOS paragraph (production's prompt differs from staging's, as before). Decisor `node --check` OK.
    harness115.js can only run against staging (psql-staging.sh), so it was NOT run on production; instead the helpers the
    tools call were queried in production (read-only): USD 50/500/999/1000/1999/2000 -> 13,000/130,000/259,740/250,000/
    499,750/490,000 GYD; GYD 13,000/250,000/249,999/259,740/490,000 -> 50/1,000/961/1,038/2,000 USD. The tool nodes
    themselves were not executed in production.
  - App release 0b43dac (BUILD_ID EBWrdyPYb0GqksLPeGelE; manifest production / hqztotshnlzaiziwjyzh; 114 money-path tests
    passed in the build): pm2 wacrm cwd = the new release, wacrm.onlinefreedom.site serves the BUILD_ID, the build contains
    "Tasa a cambiar", 0 staging refs, anterior -> 8953277. prod-build is left at 0b43dac, clean.
  - NOT VERIFIED: no real agent turn in production; the production Calculator page was not opened in a browser.
  - Next: T6 (Yoandrys' 9166f4be) is a separate, not yet authorized task.
- 2026-10-05 T6 DONE in production (owner authorization "si dale", then the coordinator's go-ahead for the revert), only operation 9166f4be-8688-48ba-ad90-407792156e0d (Yoandrys).
  - Before: operation completed (closed_manually, muted 'completed', destination 1000); beneficiary f86343e8 vigente 961 USD; calculator entry 75381479 ZELLE 961 USD, facturado 249,860, invertido 230,640, retorno 19,220 (sell 260, buy 240).
  - Why not the plain RPCs: crm_corregir_beneficiario refuses a completed operation; crm_corregir_entrada_calculadora only changes facturado/invertido (guard 149 locks amount); the panel has no revert-from-completed RPC.
  - Method: one guarded DO block run as the owner (jwt claims sub ca797265..., role authenticated), asserting the before values first: (1) human status revert completed -> ready_to_transfer as a raw UPDATE (migration 096 completion_guard lets a human through; trigger 104 voids the entry keeping its figures), with customer_notice_muted_for='ready_to_transfer' in the same statement (191 mechanism) and one human_correction audit row for the revert (no panel path writes one); (2) crm_corregir_beneficiario(f86343e8, {"amount":1000}); (3) crm_cerrar_operacion_manual(op, reason, p_notify=false, NULL) (re-complete, closed_manually, muted 'completed'; the revert revived the same entry row from the current operation data).
  - Notification analysis: trigger notify_operation_status_change posts every status change to the Cerebro notifier through pg_net. The notifier skips the customer notice when customer_notice_muted_for equals the new status. The block asserted every queued post carried that mute for its own status.
  - DRY RUN (rolled back) result: operation completed/closed_manually/muted completed/dest 1000; new beneficiary 4b41578f amount 1000; entry 75381479 ZELLE 1000, facturado 250,000, invertido 240,000, retorno 10,000, sell 250, buy 240; two pg_net posts (completed->ready_to_transfer muted_for ready_to_transfer; ready_to_transfer->completed muted_for completed); audit rows human_correction (status), human_correction (amount 961->1000), human_manual_close, all by the owner; messages 566/566, message_outbox 62/62, notifications 42/42.
  - REAL RUN: same block without the final exception, no assertion failed. Re-read after: operation completed (version 10, completed_at unchanged 13:22:57), closed_manually, muted 'completed', destination 1000; beneficiary a08f7916 vigente 1000 USD (source admin_correction); one non-void entry 75381479 ZELLE 1000 / 250,000 / 240,000 / 10,000 (sell 250, buy 240); audit human_correction (revert) and human_manual_close by the owner.
  - No-message check after the real run: messages 566 (last 2026-10-04 17:40), message_outbox 62 (last 2026-10-04 16:37), notifications 42 (last 2026-09-21) for the conversation, all unchanged; net.http_request_queue empty (the two posts were drained).
  - NOT VERIFIED: the notifier's own run for the two posts (n8n executions not inspected); an admin-side WhatsApp alert, if the notifier sends one on completion, is not covered by the customer-message check. The entry's rate_version_id moved to the current version (revival rewrite).
