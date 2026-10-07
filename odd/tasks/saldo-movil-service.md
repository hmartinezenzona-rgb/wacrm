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
- [ ] T1 DB: RED assertion saldo-model.sql; migration 223 + rollback on staging; GREEN; regressions (recarga-model,
  combo-model, visa-model, change-operation-service, calculator-recarga, resolve-pending, operations-board, corrections).
- [ ] T2 App: lists, selector, card, filters, rates UI, i18n; vitest RED then GREEN; typecheck, lint, full suite.
- [ ] T3 Staging deploy + owner's look.
- [ ] T4 Production with the owner's go-ahead; then Yilian's operation.
- [ ] T5 (later, separate go-ahead) Bot: recognise, quote and open saldo; notice text and Meta template.

## Progress
- 2026-10-06 document created after mapping.

## Next step
T1.
