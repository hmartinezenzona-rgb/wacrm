# Split deposits: service minimums as the remesa target

## Objective
A remesa paid in several MMG deposits stays ONE operation: a deposit that does not reach the service
minimum (or the amount the customer asked for) waits for the rest, and the next deposit is added to it.

## Problem (real case, Yais 5927166900, 2026-09-28)
Customer asked for a 50 USD Zelle (13,000 GYD) and paid 3,000 + 10,000. The bot opened two operations:
3,000 in incident ("importe no esta claro", MMG email never consumed) and 10,000 auto-verified with no
beneficiary, told "se le transfiere el equivalente". Unified by hand on 2026-10-01 (op 9d6e344c).
Why: `cerebro_registrar_deposito` only sums into an open deal with an objetivo (saldo > 0); the objetivo
is only set when the LLM calls `calcular_usd`; and the sum branch still filters on `deals.stage_id`,
which nothing writes since 114. Production never summed a deposit (0 deals with SALDO notes).

## Business rules (user, 2026-10-01)
Minimum deposit per service, in GYD: CUP 5,000; Zelle / Clasica / Tropical 13,000; visa extension and
translations 5,000; recargas 5,200 or 6,200 depending on the promotion; (catalog) Mexico 13,000,
cash USD 29,000, combos 25,000. A deposit below the minimum of the rail the customer chose is a part
payment, not a remesa. What the customer said they want to receive (rail, amount) is context too.

## Scope
- DB only (migration 170) + assertion; no n8n change. Staging out of scope (user: production directly).

## Tasks
- [x] T1 Assertion `supabase/staging/assertions/split-deposit-minimums.sql`: Yais both orders, CUP
      3,000 + 2,000, negatives (two complete Zelle, sum never into a ready op). RED on production.
- [x] T2 Migration 170: minimums in cerebro_config + `cerebro_minimo_gyd(op)`; registrar sums a
      deposit into the open waiting op of the conversation when that op is below its minimum, has
      saldo, or the new deposit alone is below the smallest minimum; an op below its minimum gets an
      objetivo = minimum so the cross waits; earlier uncrossed receipts of the op are crossed;
      168's job handles multi-receipt deals. GREEN.
- [ ] T3 Customer-stated target from the bot's own quote (deterministic objetivo), separate migration.

## Checks
TDD: assertion RED before T2, GREEN after, run in a rolled-back transaction on production.

## Progress
- 2026-10-01: document created; design from the Yais conversation and the user's minimums.
- 2026-10-01: T1 RED on production (rolled back): Yais -> 2 ops, first 3,000 incident; CUP 3,000 alone ready.
- 2026-10-01: T2 migration 170 (renumbered: 169 was taken by the other session's renumbered reparto
  migration). Trial of migration + assertion in one rolled-back DO block: 5/5. Applied; deployed prosrc
  md5 of the 5 functions equal the file; assertion GREEN 5/5 against production, rolled back; cron job
  succeeding, no Cerebro errors, no test rows left. Rollback: ROLLBACK-170 (restores 125's registrar,
  prosrc md5 a0251d99, and 168's job).
- WARNING for the eliminate-deals work on this branch: 160 and 167_operation_incident_reason redefine
  cerebro_registrar_deposito. Whoever deploys them must carry 170's sum branch, objetivo minimum and
  cerebro_cruzar_pendientes call over, or production goes back to splitting deposits.

## Next step
T3: set the objetivo from what the customer asked for (the bot's own quote), so a remesa above the
minimum (e.g. 100 USD paid as 13,000 + 13,000) also waits for its rest.
