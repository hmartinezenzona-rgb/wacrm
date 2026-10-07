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
- [ ] T2 App: lists, selector, card, filters, rates UI, i18n; vitest RED then GREEN; typecheck, lint, full suite.
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
- Ledger line: amount_currency 'REC' (units), pending reasons saldoCostoUsdt / saldoPaquetes.
- Not touched: cerebro_registrar_deposito and the bot (a deposit for a conversation with an open saldo still lands as
  a remesa deposit); that is T5.

## Next step
T2 (app).
