# Feature: change an open operation's service from the chat panel

## Objective
When the bot understood the wrong service (e.g. a recharge registered as a CUP remesa, Zelle instead of a CUP card),
the team changes it from the operation panel in the chat in one step, without messaging the customer.

## Problem (production 2026-10-06, Yilian 6709a0cd)
crm_corregir_operacion (098) accepts destination_currency, delivery_method, deposit_method and the two amounts, but not
service_type; crm_corregir_beneficiario (212) can re-type one beneficiary only. There is no way to turn a remesa into a
recarga (or back), and switching rails needs several manual corrections that lock the amounts. Yilian's operation had
to be fixed with SQL.

## Owner decisions (2026-10-06: "si me sirve")
A "Servicio" selector on the operation in the chat panel with: tarjeta CUP, Zelle, Clasica, Tropical, efectivo USD,
recarga, combo, visa. Open operations only (completed ones are corrected as before). The quote is recalculated; the
recipient is kept when the new service can use it, otherwise the operation asks for the missing data. No customer
message; the change is recorded in the history.

## Defaults chosen by Claude (stated to the owner, open to change)
- Rails map to service_type remesa + delivery_method (cuban_card, zelle, clasica, tropical, efectivo_usd); recarga,
  combo and visa are their own service_type with delivery_method NULL (check the existing models: 211 recarga, 212
  combo, 213 visa).
- Recipient handling: card rails (cuban_card <-> clasica <-> tropical) re-type the current card recipients and recompute
  their amounts; to zelle or efectivo_usd the current card recipients are retired (status reemplazado) and the
  operation asks for the new recipient; to recarga or visa every recipient is retired; to/from combo the recipients that
  do not fit are retired.
- Amounts: the destination quote and recipient amounts are recomputed by the existing calculation
  (crm_calcular_monto_destino and its rules: Zelle tiers, single rate, CUP rate), not locked as manual values. The
  chosen service/delivery method is locked against the bot so it does not flip it back.
- Statuses allowed: every status except completed and cancelled; the status itself does not change.

## Scope
- DB migration 222 (+ ROLLBACK-222, staging first): RPC crm_cambiar_servicio(p_operation_id uuid, p_servicio text)
  (SECURITY DEFINER, account members with the same role rule as crm_corregir_operacion, authenticated only), one
  human_correction audit row with before/after, no message/outbox/notifier side effects.
- App: the selector in the operation panel of the chat (where the other operation corrections live), API route like
  the existing remittance-operations correction route, i18n en/es, tests.
- Out of scope: completed operations, n8n bot changes.

## Constraints
- Production only with the owner's go-ahead (DB via gate script; app via the normal build/deploy).
- Never message the customer from this action.

## TDD
Strict TDD on. Runners: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK, as is and with no promo); vitest.

## Tasks
- [ ] T1 DB: RED assertion change-operation-service.sql (each target from a CUP remesa; card rail switch keeps the card
  and recomputes USD; to zelle retires the card; to recarga clears destination and recipients; closed operation
  refused; non-member refused; no messages/outbox/notifier posts; audit row); migration 222 + rollback on staging;
  GREEN; regressions.
- [ ] T2 App: selector + route + i18n + tests (RED then GREEN); typecheck, lint, full suite.
- [ ] T3 Staging deploy + owner's look.
- [ ] T4 Production with the owner's go-ahead.

## Progress
- 2026-10-06 document created.

## Next step
T1.
