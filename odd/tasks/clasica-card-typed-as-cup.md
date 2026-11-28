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
- [x] T1 RED assertion clasica-card-from-delivery-method.sql (card after marcar_destino_usd clasica -> clasica 20 USD
  for 5,200 GYD; tropical; card before the tool -> re-typed; reparto_auto untouched; efectivo untouched; locked
  respected); migration 221 + rollback on staging; GREEN; regressions (deterministic-usd-destination,
  reparto-usd-card-rail, reparto-destino-node-adapters, reparto-guards, reparto-auto, reparto-keeps-zelle,
  zelle-tiered-rate, destination-amount).
- [x] T2 Production with the owner's go-ahead.

## Progress
- 2026-10-06 document created after root-cause mapping; data fix of 45dde511 done in production.

## T1 evidence (2026-10-06, staging, BEGIN ... ROLLBACK, as is and with every promo discarded)
- RED before 221: `case a: Clasica card should be clasica/USD/20 with destination USD, got cuban_card / CUP / 15600 / CUP`
  (the production bug, exactly).
- Migration 221 + ROLLBACK-221 (no BEGIN/COMMIT). Round trip in one rolled-back transaction:
  pre md5 trigger 0740887d..., marcar 9f779e60...; after 221 697eb34e... / f239d898...; after rollback back to
  0740887d... / 9f779e60... Applied for real; schema_migrations row `221 | 221_card_type_from_delivery_method`.
- GREEN: ALL PASS (cases a, a2, b, c, d, e, f, g) as is and with no promo. Case f stores a real beneficiaries lock
  (needs `wacrm.origin = 'admin'`, 096 drops lock writes from automation).
- Regressions pass as is and with no promo: deterministic-usd-destination, reparto-usd-card-rail,
  reparto-destino-node-adapters (parity with the old marcar, return shape unchanged), reparto-guards,
  reparto-auto, reparto-keeps-zelle, zelle-tiered-rate, destination-amount, split-deposit-minimums
  (the ones that end "ALL PASS (rolled back on purpose)" exit 3 by design). Leftovers: 0 test contacts.
- Design: the trigger falls back to delivery_method only when no recent pending row exists; marcar_destino_usd calls
  cerebro_registrar_destino(conversation, lower(rail)) for Clasica/Tropical in its three branches (sin cambios,
  destino marcado, envio nuevo). Side effect (157's "last statement wins"): marcar now also leaves a pending row for 24 h.

## Next step
T2 (production, with the owner's go-ahead).

- 2026-10-06 PRODUCTION DB (owner: "dale pasalo"), migrations 221 + 222 in one transaction:
  backup ~/wacrm-respaldos/produccion-20261007T025555Z.dump (sha256 057504452c3717ab...); pre-check
  cerebro_destino_pendiente_antes_insert 0740887d..., cerebro_marcar_destino_usd 9f779e60... (= ROLLBACK-221 header),
  crm_cambiar_servicio absent; ~/cerebro-fase1/pruebas/gate122-aplicar-db.py with temporary zz_wu5b_exec:
  ensayo trg 697eb34e... marcar f239d898... cambiar=1 anon=false (= staging); ida-y-vuelta back to 0740887d... /
  9f779e60... cambiar=0; aplicar OK (schema_migrations 20261007025829 221, 20261007025830 222); probar (forced
  rollback) clasica-card-from-delivery-method, change-operation-service, deterministic-usd-destination,
  reparto-usd-card-rail, reparto-guards, corrections: all pass (the gate now strips an assertion's own BEGIN;/ROLLBACK;).
  Helper dropped; 0 leftovers; 632 operations, 230 contacts. App release 1ff1d13 BUILD_ID EqlTF6kkrIAy1YVnu21f3.
