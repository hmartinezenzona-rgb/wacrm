# Feature: Zelle share of a mixed reparto priced by its own tier

**Status: PARKED (owner, 2026-10-06).** The rule is decided; build it only when the first large mixed reparto
appears. Until then a person corrects such an operation by hand.

## Objective
In any operation that splits a deposit between Zelle and another rail (Clasica/Tropical in USD, or CUP cards), the
Zelle share is priced by the tier of the USD sent through Zelle (cerebro_tasa_zelle(zelle USD)). The other rails keep
their single rates.

## Problem
Since 215 the Zelle tier of a mixed operation comes from the WHOLE deposit, and an all-USD Zelle + Clasica/Tropical
reparto ignores the tiers (everything at the single rate). So the same Zelle amount gets a different price depending
on what else the deposit carries, and the bot node "Detectar repartos" (single rate only) disagrees with the DB from
250,000 GYD up.

## Why (owner decision, 2026-10-06, Engram decision/zelle-mixed-reparto-tier)
The Zelle price depends only on what goes through Zelle, like a Zelle-only request; no customer earns a Zelle discount
with money that goes through another rail. Example: 780,000 GYD = Zelle 1,040 USD @250 + Clasica 2,000 USD @260.
Extension to CUP-card mixes announced to the owner as the default.

## Scope
- DB (migration 219 + ROLLBACK-219, staging first): cerebro_aplicar_reparto, crm_monto_resto_zelle,
  calculator_feed_operation (mixed operations only), crm_resolve_pending_entry (line with its own basis).
  Unchanged: calculator_operation_parts (already gives Zelle the remainder basis), crm_calcular_monto_destino (calls
  crm_monto_resto_zelle), Zelle-only paths and the 218 objective/quote logic for single-service operations.
- Bot: n8n "Cerebro - Repartos automaticos" node "Detectar repartos" (~/cerebro-fase1/pruebas,
  nodo-repartos-automaticos.v5-live.js, generar-workflow-repartos.py) prices Zelle shares by their own tier.
- App TypeScript: no change (no mixed pricing in the panel).
- Production only with the owner's go-ahead, per step.

## Constraints
- Zelle amounts stay whole USD rounded down. Remainder Zelle: highest tier T with floor(resto / rate_T) >= min_T.
- All-USD Zelle + Clasica/Tropical: checked in GYD with the same tolerance as the mixed branch (leftover < Zelle rate).
- zelle-tiered-rate.sql cases 6 and 7 encode the 215 rule; their expectations change by owner decision
  (case 6: Zelle 500 USD is tier 260, card carries 120,000 GYD; case 7: remainder 224,000 GYD -> 861 USD @260, not
  896 @250).

## TDD
Strict TDD on (user config). Runner: staging assertions via psql-staging.sh (BEGIN ... ROLLBACK), as is and with no
promo; bot node via banco-repartos.js with casos-banco-repartos.json / casos-reparto-rieles-usd.json.

## Tasks
- [ ] T1 RED: new staging assertion zelle-mixed-reparto-tier.sql (reparto Zelle >= 1,000 USD + CUP card; all-USD Zelle
  + Clasica on a large deposit; remainder Zelle; ledger feed and pending resolve of a mixed op) and the updated
  zelle-tiered-rate cases 6-7; observed failing on staging.
- [ ] T2 Migration 219 + ROLLBACK-219 on staging (gate117: ensayo, ida-y-vuelta, aplicar, probar); T1 GREEN; Zelle and
  reparto regressions pass as is and with no promo.
- [ ] T3 Bot node "Detectar repartos": Zelle shares by own tier; bank cases RED then GREEN; staging workflow updated.
- [ ] T4 Owner test on staging (test number reset first).
- [ ] T5 Production: DB (backup, md5 pre-check, gate) and workflow, each with the owner's go-ahead.

## Acceptance criteria
- The DB check, the ledger and the bot give the same Zelle amount and rate for the same mixed reparto.
- Zelle-only operations, Clasica/Tropical/CUP shares and the 218 objective behaviour are unchanged.

## Progress
- 2026-10-06 document created after mapping (no source change yet). Delivery strategy: ask-on-risk.

- 2026-10-06 production evidence (read-only): since 2026-08-06, 249 operations with Zelle; only 2 mix Zelle with
  another rail, both at the base tier (10f159be: 39,000 GYD = Zelle 100 + Clasica 30 + 20; 581471b1: 27,500 GYD =
  Zelle 67 + two CUP cards of 15,000). Only one Zelle operation ever reached 1,000 USD (Zelle only). No real customer
  would have been priced differently under any of the three rules.
- 2026-10-06 owner: park it ("si dejalo asi"). No task started.

## Next step
Parked. Resume at T1 when a mixed reparto with a Zelle share of 1,000 USD or more (or a deposit of 250,000 GYD or more
split between Zelle and another rail) shows up in production.
