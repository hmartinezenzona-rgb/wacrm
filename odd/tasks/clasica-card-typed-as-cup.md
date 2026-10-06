# Feature: a card for a Clasica/Tropical operation is stored as Clasica/Tropical, not as a CUP card

## Objective
When the bot already knows the operation goes to Clasica or Tropical (remittance_operations.delivery_method), the card
it registers is stored with that type, quoted in USD, and the ledger records it on that rail.

## Problem (production, 2026-10-06, Yusmila, operation 45dde511)
- The customer asked for 20 USD to a Clasica card. The bot called marcar_destino_usd('clasica'): the operation was
  created with delivery_method 'clasica' (cerebro_marcar_destino_usd, 163:420-536), but that function never writes
  cerebro_destino_pendiente.
- The card came through "Registrar beneficiario auto" (cerebro_registrar_beneficiario_auto, 162:141-253), which
  hard-codes beneficiary_type 'cuban_card'.
- The re-type trigger cerebro_destino_pendiente_antes_insert (157, last 169:215-242) only reads
  cerebro_destino_pendiente, so it did nothing; crm_calcular_monto_destino (217) priced the card in CUP
  (5,200 x 3 = 15,600 CUP). The completion text said "15,600 Clasica" and the calculator entry was CUP.
- No assertion covers "delivery_method set by marcar_destino_usd, no pending row, card by registrar_beneficiario_auto".

## Data fix already done (owner: "fue clasica")
Operation 45dde511 corrected in production to Clasica 20 USD (beneficiary, operation, calculator CLASICA 20 USD,
5,200 billed / 4,800 invested / 400 return), silently (gate120, guarded block, notifier posts muted, 0 messages).
Only affected operation found: production has no other clasica/tropical operation with a lone CUP card (a29ef5e8 is a
deliberate mixed reparto).

## Scope
- DB migration 221 (+ ROLLBACK-221, staging first):
  - cerebro_destino_pendiente_antes_insert: for a cuban_card insert (source not 'reparto_auto'), when there is no
    recent pending row, use the operation's delivery_method when it is 'clasica' or 'tropical' (pending row keeps
    precedence when present).
  - cerebro_marcar_destino_usd: for Clasica/Tropical also record the pending destination through
    cerebro_registrar_destino (so a card already registered is re-typed too, same rules as 157).
- Repartos (reparto_auto source, mixed CUP + Clasica) and locked fields behave as before.
- Out of scope: the USD minimum for Clasica/Tropical (separate owner decision).

## Constraints
- Production only with the owner's go-ahead (gate script, backup, ensayo, ida-y-vuelta).
- No change to Zelle, efectivo, combos, recargas, visas.

## TDD
Strict TDD on. Runner: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK), as is and with no promo.

## Tasks
- [ ] T1 RED assertion clasica-card-from-delivery-method.sql (card after marcar_destino_usd clasica -> clasica 20 USD
  for 5,200 GYD; tropical; card before the tool -> re-typed; reparto_auto untouched; efectivo untouched; locked
  respected); migration 221 + rollback on staging; GREEN; regressions (deterministic-usd-destination,
  reparto-usd-card-rail, reparto-destino-node-adapters, reparto-guards, reparto-auto, reparto-keeps-zelle,
  zelle-tiered-rate, destination-amount).
- [ ] T2 Production with the owner's go-ahead.

## Progress
- 2026-10-06 document created after root-cause mapping; data fix of 45dde511 done in production.

## Next step
T1.
