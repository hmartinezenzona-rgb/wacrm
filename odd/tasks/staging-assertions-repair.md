# Feature: repair the stale staging assertions

## Objective
Every SQL assertion under supabase/staging/assertions/ either passes on staging or fails because of a real bug that
is reported. None fails just because its fixture no longer matches the database.

## Problem (found 2026-10-04 while building combos, recharges and visas)
These assertions fail on staging identically with and without the latest migrations, so they no longer guard
anything:
- beneficiary-proofs, cash-delivery-activation, corrections, deal-free-beneficiary-writers,
  deal-free-panel-verification, deposit-review, partial-beneficiary-auto, reparto-auto,
  reparto-destino-node-adapters, reparto-guards, reparto-keeps-zelle, reparto-usd-card-rail, split-deposit-minimums,
  verify-deposit-status-drift, zelle-confirmed-name, zelle-remainder-amount;
- beneficiary-matcher and zelle-holder-name print no result line.
Seen causes:
- (a) a fixture inserts a deal and expects the deal to create an operation; the deal-free path (161/172/183) no
  longer does;
- (b) a fixture reads `FROM conversations LIMIT 1`, and staging can have no conversations after a test-contact reset;
- (c) "schema pg_temp does not exist" or missing pg_temp helpers;
- (d) possibly real regressions hidden among them.
They cover remesas, repartos and Zelle, the most used paths.

## Scope (owner, 2026-10-05: "sigue con la 1")
Tests only: supabase/staging/assertions/*.sql. No migration, function, n8n or app change. A failure that is a real
behaviour regression is reported to the parent with evidence, never papered over by changing the expectation.

## Rules
- Fixtures must build their own data: user and account from whatsapp_config + profiles, their own contacts and
  conversations, operations created by the current functions (or inserted directly), not through deals.
- Each assertion keeps its original intent and expectations. Change only how the fixture reaches the state under test.
- Run each assertion on staging both as is and with every promo discarded inside the transaction (staging keeps a fake
  confirmed promo; production has none). Use BEGIN … ROLLBACK when the file uses SAVEPOINTs.
- Before calling a failure a regression, compare it with the expectation's history (git log -p on the assertion and
  the migration it guards).

## Tasks
- [ ] T1 Classify each failing assertion (stale fixture, environment, or real regression) with its first error line.
- [ ] T2 Repair the stale fixtures; every repaired assertion passes as is and with no promo.
- [ ] T3 Report the real regressions, if any, with evidence, for a separate decision.

## Progress
