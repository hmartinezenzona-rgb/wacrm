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
- [x] T1 DB: RED assertion change-operation-service.sql (each target from a CUP remesa; card rail switch keeps the card
  and recomputes USD; to zelle retires the card; to recarga clears destination and recipients; closed operation
  refused; non-member refused; no messages/outbox/notifier posts; audit row); migration 222 + rollback on staging;
  GREEN; regressions.
- [x] T2 App: selector + route + i18n + tests (RED then GREEN); typecheck, lint, full suite.
- [ ] T3 Staging deploy + owner's look.
  - 2026-10-06 owner look on staging (release 33fd0e2): works, but the separate selector above "Deliver to" looks bad.
- [ ] T2b App rework (owner, 2026-10-06): move the service choice INTO the operation card's existing edit mode (the
  pencil): it appears there next to the other editable fields, coexisting with them; confirm with the check (✓) and
  cancel with the X, the same controls the other inline edits use. Remove the standalone selector. Keep the warning
  that the quote is recalculated and the customer is not messaged, in the edit-mode style.
- [ ] T4 Production with the owner's go-ahead.

## Progress
- 2026-10-06 document created.
- 2026-10-06 T1 done (commit 77e2fc7): assertion supabase/staging/assertions/change-operation-service.sql written first; RED before 222:
  `function crm_cambiar_servicio(uuid, text) does not exist` at case a1 (setup a, the CUP fixture, passed). Migration 222 +
  ROLLBACK-222 applied on staging (round trip in a rolled-back transaction, rollback drops the RPC; real apply + schema_migrations
  row 222; anon/public cannot execute, authenticated can). GREEN as is and with promos discarded ("ALL PASS (change-operation-service)",
  cases a1-a10, b-i). Regressions green as is and with no promo: clasica-card-from-delivery-method, deterministic-usd-destination,
  destination-amount (11), zelle-tiered-rate, recarga-model, combo-model, visa-model, corrections (10), reparto-guards.
  Leftovers 0 (contacts 5990222%).
- 2026-10-06 T2 done (commit below, see git log): POST /api/remittance-operations/[operationId]/service (agent, beta flag, 400/403/404
  mapping), commands.cambiarServicio, OperationServiceControl ("Servicio" select, confirmation step, success/error toast, refetch)
  placed in the expanded operation card above "Deliver to", only when the card is editable (open, not history, canEdit). vitest RED
  (23 failed) then GREEN; typecheck clean; eslint clean on touched paths; full suite 163 files / 2035 tests green.

### Decisions beyond the defaults
- Card rails re-type the card IN PLACE (same recipient id, so proofs survive) instead of retire + insert; recipients that do not fit are
  retired (status reemplazado). A lone recipient has amount/currency cleared and is repriced by the existing calculation.
- Several card shares with their own amounts: kept on a USD rail change (clasica <-> tropical), REFUSED (22023) across CUP <-> USD.
- The quote is recalculated, so the manual locks on quoted_destination_amount and destination_currency are released; delivery_method and
  service_type are locked (also for recarga/combo/visa, where delivery_method stays NULL) so the bot's writers cannot flip it back
  (verified: cerebro_marcar_destino_usd is suppressed and audited).
- An existing 'beneficiaries' lock is kept and the lone recipient still gets the recalculated amount; no new beneficiaries lock is added
  (it would freeze the recipient's amount against later deposit changes).
- Leaving a combo clears combo_costo_gyd. The deposit amount (quoted_source_amount) is never changed.
- Choosing the service the operation already has is a no-op (no audit row). Operations of type traduccion/mexico are refused.
- Selector options reuse the catalog labels closing.method.* ("Tarjeta CUP", ...); new copy under serviceChange.* (en/es).

- 2026-10-06 T3 staging deployed (owner's look pending; T3 NOT checked off): release 33fd0e2844176466879ab43fcb4add26e422e6c8,
  BUILD_ID MRoiqtquBpeyWFVM8cTTb, same procedure as 45d6825 (clean prod-build worktree, docker node:20 uid 1000, staging-build.env with
  NEXT_PUBLIC_APP_LOCALE=es, built off oracle2). Manifest staging / kolppplawzdsjfydwejr, 114 money-path tests passed, 0 production
  refs / 32 staging refs, sha256 OK. `current` -> 33fd0e2, `anterior` -> 45d6825; pm2 wacrm-staging cwd resolves to the new release,
  restarts 66 -> 67 and stable; /login 200 with the new BUILD_ID and "Bienvenido de nuevo"; unauthenticated POST
  /api/remittance-operations/<uuid>/service 401; "No se le escribe al cliente" (es.json serviceChange.warning) present in .next/server.
  No DB change. Rollback: `ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/45d6825ddfedb94d50623d1f195a50816f22e540 ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`. Production not touched.

## Next step
T3: staging deploy of the app and the owner's look.
