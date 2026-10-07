# Feature: "Saldo móvil" as an operation service

## Objective
A mobile balance top-up to a Cuban phone ("recarga de saldo") is an operation service of its own: the team can choose
it in the chat panel, and when the operation is completed the calculator records the "Saldo Móvil" line by itself.

## Problem
"Saldo Móvil" exists only as a manual calculator line (`• <name> <units> saldo movil (<USDT cost>/<GYD sale>/<USDT rate>)`,
src/lib/calculator/web-calculator.ts:64-74,154-159; remittance_calculator_entries already accepts SALDO_MOVIL, 213:48).
Operations have no such service_type (remittance_operations_service_chk, 046:36): on 2026-10-06 Yilian's 5,000 GYD
saldo top-up (operation 6709a0cd, production) had to be stored as 'recarga', which is promo-bound and priced by
precio_recarga, so its ledger line would stay verified_pending (recargaPrecioGyd).

## Owner decisions (2026-10-06)
- "inclúyelo también en los servicios, es lo mismo que las recargas pero en este caso es recarga de saldo".
- Sold in fixed packages: 1,000 GYD = 360 of saldo.

## Defaults chosen by Claude (stated to the owner, open to change)
- Price and package size are data (cerebro_config: precio_saldo_gyd = 1000, saldo_unidad_cup = 360), not code.
- Cost: USDT per package in calculator_rate_versions.saldo_costo_usdt, edited in the Calculator "Tasa a cambiar" like
  recarga_costo_usdt; left NULL until the owner sets it (the manual example used 1.25).
- Not promo-bound: sold all year.
- Minimum: one package (minimo_gyd_saldo = precio_saldo_gyd).
- A deposit that is not a whole multiple of the package price leaves the ledger line pending for a person (no silent
  rounding).
- One Cuban number receives every package of the operation (reuse the recarga recipient row: phone only).
- Bot excluded for now (second step): today "saldo" is routed to recargas and refused without a promo.

## Scope (step 1: DB + ledger + panel)
- DB migration 223 (+ ROLLBACK-223, staging first), modelled on 213 (visa) and 198/199 (recarga):
  - 'saldo' in remittance_operations_service_chk; recipient = the existing phone-only recarga row type;
  - cerebro_config rows; calculator_rate_versions.saldo_costo_usdt + crm_set_calculator_rates key;
  - service enumerations: cerebro_riel_op, cerebro_minimo_gyd, cerebro_objetivo_minimo,
    crm_operaciones_de_conversacion, crm_cerrar_operacion_manual, crm_cambiar_servicio, crm_beneficiarios_completos;
    remesa writers leave a saldo alone;
  - ledger: calculator mapping functions (SALDO_MOVIL), a SALDO_MOVIL branch in calculator_feed_operation
    (units = basis / price when exact, facturado = units x price, invertido = units x saldo_costo_usdt x usdt_buy_gyd,
    missing inputs when the cost or an exact multiple is missing);
  - existing gap: crm_resolve_pending_entry / canResolveWithRates would price a pending RECARGA line as a USD service.
    Fix for RECARGA and SALDO_MOVIL (own branch, or excluded like COMBO/VISA).
- App: services list and selector, close-manual picker, API route lists, Tablero filter, Finanzas filter, dashboard
  colour, operation card (count/label, phone recipient), Calculator rates UI + API + ledger read model, i18n en/es.
- Data: after production, reclassify Yilian's 6709a0cd from recarga to saldo (silent), with the owner's go-ahead.
- Out of scope: the n8n bot (recognise/quote/open saldo), the customer notice text and Meta template.

## Constraints
- Production only with the owner's go-ahead (gate script; normal app deploy).
- No customer message from any panel action; recargas, combos, visas and remesas unchanged.

## TDD
Strict TDD on. Runners: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK, as is and with no promo); vitest.

## Tasks
- [x] T1 DB: RED assertion saldo-model.sql; migration 223 + rollback on staging; GREEN; regressions (recarga-model,
  combo-model, visa-model, change-operation-service, calculator-recarga, resolve-pending, operations-board, corrections).
- [x] T2 App: lists, selector, card, filters, rates UI, i18n; vitest RED then GREEN; typecheck, lint, full suite.
- [x] T2b Follow-up (owner 2026-10-06): the automatic ledger line of a saldo shows the saldo amount in SM ("1,800 SM"),
  not the package count in 'REC'. DB (migration 223 amended in place, staging only) and app, see Progress.
- [ ] T3 Staging deploy + owner's look.
- [ ] T4 Production with the owner's go-ahead; then Yilian's operation.
- [ ] T5 (later, separate go-ahead) Bot: recognise, quote and open saldo; notice text and Meta template.

## Progress
- 2026-10-06 document created after mapping.
- 2026-10-06 T1 done on staging (migration 223 applied, schema_migrations row 223; production untouched).
  - RED: assertion saldo-model.sql before 223 failed at its first statement, `ERROR: unknown rate: saldo_costo_usdt`
    (crm_set_calculator_rates, DO block line 14).
  - Round trip (one rolled-back transaction): 223 changed all 17 redefined functions; ROLLBACK-223 restored 17 of 17 to
    the pre-223 md5, removed cerebro_saldo_precio/cerebro_saldo_paquetes, the column and the two config rows, and the 5
    remittance_operations CHECKs came back identical.
  - GREEN: saldo-model.sql ALL PASS as is and with promos discarded (16 cases). Regressions, as is and no promo, all
    PASS: recarga-model, combo-model, visa-model, change-operation-service, calculator-recarga, resolve-pending,
    operations-board, corrections, clasica-card-from-delivery-method, destination-amount, zelle-tiered-rate,
    reparto-guards, rate-versions. Leftovers 0 (contacts, saldo operations/lines, saldo cost versions).
  - Pre-223 md5 (pg_get_functiondef, staging) are in ROLLBACK-223's header.
- 2026-10-06 T2 done (app only, nothing deployed).
  - RED: with the new tests and the source reverted, vitest showed 24 failed / 2000 passed (services, card, picker,
    add control, board, rates API, resolve API, read model, calculator rates list).
  - GREEN: 2053 passed in 163 files (full suite, includes the en/es parity test); tsc --noEmit clean; eslint clean on
    the touched files.
  - Touched: services list + saldoPackages, selector/picker (Coins icon, teal, distinct from recarga's Smartphone),
    close-manual and service route lists, Tablero filter + known services, Finanzas filter, dashboard colour,
    operation card (package count + saldo = packages x 360, phone recipient, quote hidden, one-number add control),
    beneficiary add form (phone only), calculator rate "Costo saldo (USDT)" in the UI, rates API whitelist and select,
    resolve API whitelist, read model, i18n en/es.
- 2026-10-06 T2b DB (staging only, 223 amended in place, no 224).
  - Owner: "5 SALDO_MOVIL ... ahi va un monto ... el saldo movil es CUP tambien ... puede ser SM".
  - Change: calculator_feed_operation stores amount = packages x saldo_unidad_cup (new cerebro_saldo_unidad(), 360) and
    amount_currency 'SM' for SALDO_MOVIL; RECARGA keeps units/'REC'. facturado/invertido/retorno still come from the package
    count. crm_resolve_pending_entry sets the same amount/'SM' when it resolves a saldo line. No reader derives units from
    a saldo amount (feed and resolver use the basis and the config); amount_currency only has a 1..12 length CHECK (095).
  - Pending line: exact package count with the cost missing shows 1,800 SM (amount and currency as if completed, figures
    NULL); not a whole multiple shows the raw deposit as 'GYD' (never SM; it used to be 'REC'). Resolver refuses the
    non-multiple as before.
  - RED: saldo-model.sql (expectations updated first) against the applied 223: `case 7: expected SALDO_MOVIL completed
    1800 SM (5 packages x 360), got SALDO_MOVIL completed 5 REC`.
  - Staging re-apply: ROLLBACK-223 from git HEAD (its guard refuses while a saldo op/line exists, so the owner's test row was
    parked in the same transaction: line voided with figures untouched, op read as 'recarga', session_replication_role
    replica, guard block skipped), 17 of 17 pre-223 md5 matched the ROLLBACK header (header unchanged: the pre-223
    definitions did not move). Round trip of the amended pair in one rolled-back transaction: 223 changed 17 functions,
    rollback restored 17 of 17, 0 saldo functions/column/config left, 5 of 5 CHECKs identical. Amended 223 applied,
    schema_migrations row 223 re-created once.
  - GREEN: saldo-model ALL PASS as is and with promos discarded; recarga-model, calculator-recarga, resolve-pending,
    change-operation-service, combo-model, visa-model, rate-versions all PASS as is and no promo. Leftovers 0.
  - Owner's staging test row (operation 0595bd28, phone 529622896918): re-applying dropped the saldo_costo_usdt column, so
    the vigente rate version's 1.25 was set again; the op went back to 'saldo' and calculator_feed_operation revived the
    voided line: now 1800 SM, facturado 5000, invertido 1500, retorno 3500 (was 5 REC).
  - T2b app: new src/lib/calculator/entry-display.ts (chatEntryAmountText, ledgerServiceLabel, calculatorCategoryName). The
    Calculator's chat lines, pending banner and the weekly close text export read "1,800 SM" / "Saldo Móvil" (a non-multiple
    pending line reads "5,500 GYD"); the breakdown groups the automatic SALDO_MOVIL under the manual "SALDO MOVIL" category;
    Resumen close detail and summary print "Saldo Móvil" (amount already printed "1,800 SM" via fmtAmount; CSV keeps raw
    values); the operation card reads "5 packages · 1,800 SM" (en/es). RECARGA lines unchanged.
    RED: 2 page tests (page.tsx reverted) and 2 card tests (messages reverted) failed; GREEN: full suite 2059 passed in 164
    files, tsc clean, eslint clean on touched files.

## Decisions beyond the defaults (T1)
- crm_resolve_pending_entry: own branch for RECARGA and SALDO_MOVIL (not an exclusion like COMBO/VISA). Reason: the
  feed only revives VOID rows, so nothing re-feeds a pending line; a saldo line is pending by default until the owner
  sets the cost, and excluding it would leave it stuck. The payload gains recarga_costo_usdt / saldo_costo_usdt; what
  the line recorded wins; a saldo deposit that is not a whole multiple (or a recarga matching no price) is refused.
  canResolveWithRates therefore stays true for both.
- Exactly ONE phone recipient per saldo (completeness count = 1; crm_agregar_beneficiario refuses a second).
- crm_cambiar_servicio to saldo retires every recipient (like to recarga); the owner re-adds the number in the panel.
- Writers: cerebro_resolver_operacion_beneficiario, cerebro_escribir_bloque_beneficiario and
  cerebro_avisar_envios_sin_beneficiario also redefined (a saldo is never the remesa target; the no-recipient customer
  notice skips it). crm_agregar_beneficiario redefined for the phone recipient.
- Minimum = cerebro_saldo_precio() (derived from precio_saldo_gyd, no separate minimo_gyd_saldo row).
- Ledger line: amount_currency 'SM' (saldo, packages x 360; T2b, was 'REC' units), pending reasons saldoCostoUsdt / saldoPaquetes.
- (T2) The card mirrors the package price and size as constants (SALDO_PRICE_GYD = 1000, SALDO_UNIT_CUP = 360 in
  services.ts), as VISA_PRICE_GYD does for a visa, instead of reading cerebro_config: no RPC returns those rows to the
  panel today. Change both together if the owner changes the price. A deposit that is not a whole number of packages
  shows the label without a count (no rounding).
- (T2) Dashboard donut: saldo shares --chart-3 with recarga at reduced opacity (only five chart tokens exist).
- Not touched: cerebro_registrar_deposito and the bot (a deposit for a conversation with an open saldo still lands as
  a remesa deposit); that is T5.

- 2026-10-06 T3 staging deployed (owner's look pending; T3 NOT checked off): release ae7c92764b9e84722eb4bddd21094a2e6d12a344,
  BUILD_ID TSQZ7xxZC-1bNfB2-tzxn, same procedure as 1ff1d13 (clean prod-build, docker node:20 uid 1000, staging-build.env with
  NEXT_PUBLIC_APP_LOCALE=es, unchanged). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production refs /
  32 staging files, sha256 OK. `current` -> ae7c927, `anterior` -> 1ff1d13; pm2 wacrm-staging cwd resolves to the new release,
  restarts 69 -> 70 and stable; crm.onlinefreedom.site/login 200 with the new BUILD_ID and "Bienvenido de nuevo"; .next/server has
  "Saldo móvil"; prod-build clean. No DB change (migration 223 already on staging). Production not touched.
  Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/1ff1d1330f5c99f184e4254476584b6676cd03d4 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`.
- 2026-10-06 T3 staging releases (owner's look pending; T3 NOT checked off): 438c0017274593e61dee836d53ef6cfd29a031e2
  (BUILD_ID 8z4Ie62JfeHvyzlht8HQH, saldo movil lines show the saldo amount in SM) and then eb35591020666e9688f24f3e00e1b6ae9ac5c54e
  (BUILD_ID ajGFFfqB6tsxrfdNJNy7k, adds the shared check/X buttons and minimalist edit forms). `current` -> eb35591, `anterior` -> 438c001;
  114 money-path tests passed, manifest staging, 0 production refs, login 200 with "Bienvenido de nuevo", restarts 71 -> 72 and stable.
  No DB change. Production not touched.
  Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/438c0017274593e61dee836d53ef6cfd29a031e2 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`

## Next step
T3: staging app deploy and the owner's look (owner's go-ahead not needed for staging; production waits for T4's go-ahead).
