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
- [x] T1 Classify each failing assertion (stale fixture, environment, or real regression) with its first error line.
- [x] T2 Repair the stale fixtures; every repaired assertion passes as is and with no promo.
- [x] T3 Report the real regressions, if any, with evidence, for a separate decision. Result: none found; every failure was a stale fixture or helper dependency (one group also a stale expectation, see deposit-review).

## Progress

Run 2026-10-05 on staging, each file inside BEGIN ... ROLLBACK, both "as is" and with every promo discarded. Result: all 18 pass in both modes; no real regression (class c) found.

Classes: (a) stale fixture, (b) environment or missing helper, (c) real regression.

| Assertion | Class | First error before | After (as is / no promo) |
|---|---|---|---|
| beneficiary-proofs | a | fixture setup failed, an operation was not created (deal no longer creates one) | pass / pass |
| cash-delivery-activation | a | FAIL cases 1, 2, 2b, 2c: delivery_method NULL (no operation for the deal) | pass / pass |
| corrections | a | fixture setup failed, no operation created for deal | pass / pass |
| deal-free-beneficiary-writers | a | FAIL [card_auto ins_nueva] operation count old=0 new=1 (old side relies on retired trigger 125) | pass / pass (27 cases) |
| deal-free-panel-verification | a | FAIL [4] the 125 trigger did not create both deal-linked operations | pass / pass |
| deposit-review | a (+ stale expectations) | fixture setup failed, no operation created for deal | pass / pass (16 expectations) |
| partial-beneficiary-auto | b | function pg_temp.conv_vacia does not exist (helper lives in another file) | pass / pass |
| reparto-auto | a | case 1: reparto answered no_existe (operation id NULL) | pass / pass (13 cases) |
| reparto-destino-node-adapters | a | operation count differs (old side relies on retired trigger 125) | pass / pass (22 parity cases + negative control) |
| reparto-guards | b | function pg_temp.conv_vacia does not exist | pass / pass |
| reparto-keeps-zelle | a | case 1: expected the Zelle and both Clasica cards vigente, got NULL (deal_notas helper returned no operation) | pass / pass |
| reparto-usd-card-rail | none | listed as failing, but it passes unchanged on current staging | pass / pass (unchanged) |
| split-deposit-minimums | a | operation of the deal NULL, beneficiary insert failed | pass / pass |
| verify-deposit-status-drift | a | fixture setup failed, no operation created for deal | pass / pass |
| zelle-confirmed-name | a | case 1: the confirmed name should reach the panel, got NULL | pass / pass (12 cases) |
| zelle-remainder-amount | b | function pg_temp.deal_notas does not exist (helper lives in another file) | pass / pass |
| beneficiary-matcher | none | listed as printing no result line, but it prints PASS 1-9 unchanged | pass / pass (unchanged) |
| zelle-holder-name | none | listed as printing no result line, but it prints PASS 1-4 unchanged | pass / pass (unchanged) |

What changed:
- Operations come from cerebro_crear_operacion (161); where a case still reads a deal's notes (cerebro_sync_beneficiarios and the live trigger trg_sync_z_benef_desde_deal, kept by 172), a deal is created and linked with remittance_operations.deal_id, then the notes sync is re-fired.
- Users and accounts come from whatsapp_config + profiles, not `FROM conversations LIMIT 1`.
- Files that needed another file's pg_temp helpers now carry them (partial-beneficiary-auto, reparto-guards, zelle-remainder-amount).
- split-deposit-minimums follows the deal-free model of deal-free-money-rules.sql; its receipt COMP id is a 20-hex id, otherwise a second deposit of a conversation is read as a repeat of the first.
- The two parity harnesses (deal-free-beneficiary-writers, reparto-destino-node-adapters) re-create trigger 125 inside their own savepoint, because their old side is the deal path; ROLLBACK TO SAVEPOINT removes it.
- deposit-review: expectations updated where a later migration changed the behaviour on purpose: 165/172 no longer move deals.stage_id nor notify on deals (case 3 checks the operation status), and 192 made the forced-verification reason optional (case 8b now accepts an empty reason on its own operation, case 8c checks the 500-character cap).

Left alone (outside the listed files, same dependency problem): requested-amount-target, repeated-receipt and target-origin-label need pg_temp.conv_prueba and pg_temp.depositar from split-deposit-minimums, which now return an operation id.

Parent review (2026-10-05):
- History: the writer rewrote only its own unpushed commits (filter-branch, to drop the commit trailer). The pushed
  branch (b8efb63) is an ancestor of HEAD. The refs/original backup ref was deleted.
- deposit-review: the expectation changes match intended migrations: 192 "Force-verify from the panel takes no typed
  reason"; 165/172 retired the deal stage moves and the deals triggers. Accepted.
- The three dependents of split-deposit-minimums' helpers (requested-amount-target, repeated-receipt,
  target-origin-label) failed with the OLD helpers too ("null value in column operation_id"), so the writer did not
  break them.
  - With the new helpers, requested-amount-target and repeated-receipt pass.
  - target-origin-label looked up cerebro_objetivo_envio by deal_id, but depositar now returns the operation id.
    Fixed to operation_id, with the expectations unchanged.
  - All three now pass as is and with no promo, run with their helper files prepended (split-deposit-minimums, plus
    requested-amount-target for target-origin-label).

Follow-up (2026-10-06): reparto-usd-card-rail
- Its 2026-10-05 failure (`null value in column "conversation_id" of relation "cerebro_destino_pendiente"`) was class b:
  the fixture picked `FROM conversations` with no open operation, and staging's only chat had one, so v_conv was NULL.
- Fixed per the Rules: user and account from whatsapp_config + profiles, its own contact (59901690001) and
  conversation. Expectations unchanged.
- RED: the old file, with every conversation given an open operation inside the transaction, reproduces the error.
  GREEN: the new file passes cases 1-5 as is, in that busy state, and with no promo. Nothing left behind on staging.

## Follow-up tasks (owner, 2026-10-06: "si sigue")
Same Scope and Rules as above (tests only; expectations unchanged unless the parent approves).
- [x] T4 destination-amount: rates set through calculator_rate_versions (append-only) instead of the `tasas` view (113);
  case 5 ("no usd rate -> NULL") reached without DELETE, accounting for Zelle tier pricing (215-218).
  Evidence (2026-10-06, staging, BEGIN ... ROLLBACK, as is and with no promo): RED `cannot insert into view "tasas"`; GREEN
  ALL PASS (11 expectations). Rates are appended to calculator_rate_versions (usd 260 as usdt_sell_gyd and as the Zelle tier
  zelle_sell_gyd, gyd 3). Case 5: an appended NULL version does not hide older ones in the view and rows cannot be deleted
  (remittance_calculator_entries FK), so the usd rate and the three Zelle tier prices are blanked on every version with the
  append-only trigger disabled for that one UPDATE inside the transaction (only way found; Zelle then has no tier price and no
  usd fallback). Expectations unchanged.
- [ ] T5 rounding-parity: same `tasas` view fix.
- [ ] T6 deterministic-usd-destination case 2d: operation built without the retired deal path.
