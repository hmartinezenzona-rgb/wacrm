# Staging assertions triage - 2026-10-22

Staging only (migrations through 279 applied). Read-only: every run was one transaction that ended in ROLLBACK.
Function md5 of the whole `public` schema was identical before and after (`c0dc197d...`).

## Method

1. Full sweep of the 162 `.sql` files in `supabase/staging/assertions` (not 156), each in `BEGIN; ...; ROLLBACK;`
   with `\set`/`BEGIN`/`COMMIT`/`ROLLBACK` lines stripped (same as `lib-migracion.sh quitar_tx`).
2. Base = the same transaction, but first applying ROLLBACK 279, 278, 277, 276, 275, 274, 273, 272, 271, 268, 267,
   266, 265 in that order (none contains BEGIN/COMMIT; 269 has no migration or rollback file, 270 is a GRANT and
   unrelated, skipped). No assertion commits.
3. Scoring: an assertion passes when its only `ERROR` is `ALL PASS`, or when it has no `ERROR` and no `FAIL`
   warning (NOTICE-style files such as `service-catalog`).

## Counts

- 162 assertions. 19 real failures with the files run standalone.
- Four more (`cup-excess-equivalent`, `target-origin-label`, `repeated-receipt`, `requested-amount-target`) fail
  standalone with `pg_temp ... does not exist` because they need the `pg_temp` helpers of
  `split-deposit-minimums` / `deal-free-money-rules` / `requested-amount-target` (see their headers). With those helper
  definitions (the part of the file before its first `DO $$`) loaded in the same transaction all four PASS.
  The earlier "25" most likely counted these four plus the two CAPTURE-mode files below.
- `live-baseline-parity` and `live-tables-baseline` are CAPTURE-mode files ("apply 109/112, then run again"): they
  never assert on a current state. Not failures, not usable as guards any more.
- REGRESSION (passes at base, fails now): **0**.
- PRE-EXISTING: 19 (all of them fail at base with the same first error and, where several expectations exist, the
  same set of failed expectations).
  - Obsolete by the deal-free redesign (migration 172): 15
  - Stale vs later deliberate changes (261, 242, feed rewrites): 3 (`chat-media-members-only-read`, `saldo-model`, `feed-mixed`)
  - Stale data on staging: 1 (`duplicate-receipt-marker`)
- FLAKY: `contexto-envio-mixto` (below).

## Table

| assertion | now | at base | class | first breaking migration | cause | suggested fix |
|---|---|---|---|---|---|---|
| deal-insert-creates-operation | FAIL case 1: 0 operations | same | PRE-EXISTING, obsolete | 172 | The assertion guards 125 (INSERT into `deals` creates the operation). 172 dropped `trg_sync_operacion_al_crear_deal`; `deals` now has only `set_updated_at` and `trg_sync_z_benef_desde_deal`. | Retire the file (or move to a "retired" folder). |
| delivery | FAIL fixture: no operation for deal | same | PRE-EXISTING, obsolete | 172 | Fixture builds its operation by `INSERT INTO deals` (5 inserts). | Rewrite fixtures to create operations directly (like `operation-creator-without-deals`). |
| delivery-feed-evidence | FAIL fixture: no operation for deal | same | PRE-EXISTING, obsolete | 172 | Same fixture path. | Same. |
| field-lock-persistence | FAIL fixture: deal->operation sync did not create an operation | same | PRE-EXISTING, obsolete | 172 | Same. | Same. |
| history-readiness | FAIL fixture: no operation created for deal | same | PRE-EXISTING, obsolete | 172 | Same. | Same. |
| n8n-repoint | FAIL fixture: no operation created for deal | same | PRE-EXISTING, obsolete | 172 | Same. | Same. The guarded n8n functions are covered by newer deal-free assertions; check before retiring. |
| objetivo-requiere-compromiso | FAIL fixture: no operation for deal | same | PRE-EXISTING, obsolete | 172 | Same. | Same. |
| operation-creator-without-deals | FAIL [2] "old deal path should have made 1 operation, got 0" | same | PRE-EXISTING, obsolete | 172 | Case 2 compares against the old deal trigger path, which 172 removed on purpose. | Drop case 2 (the rest of the file is deal-free). |
| operation-keyed-money | FAIL [1a] "125's trigger created no operation" | same | PRE-EXISTING, obsolete | 172 | Needs trigger 125. | Rewrite or retire. |
| rekey-shipment-alerts-onto-operations | FAIL fixture operations not created (a,b NULL) | same | PRE-EXISTING, obsolete | 172 | Same fixture path. | Same. |
| stale-operations-alert | FAIL case 1: body lists other real staging remesas, not "Test134 Vieja" | same | PRE-EXISTING, obsolete | 172 | `UPDATE remittance_operations ... WHERE deal_id = v_deal` matches 0 rows because no operation is created from the deal; the notification then lists whatever real old remesas staging holds. | Create the operation directly in the fixture. |
| operation-incident-reason | FAIL [1] status NULL (cases 0, 2-5 pass) | same | PRE-EXISTING, obsolete | 172 | `SELECT id INTO v_op FROM remittance_operations WHERE deal_id = v_deal` finds no operation, so the REFERENCIA IMPOSIBLE check reads NULL. Only case 1 is affected. | Create the operation directly in case 1. |
| guard12-matrix | FAIL 7 expectations: "expected suppressed, got stage_id=..." for postgres/service_role/viewer -> Entregada, etc. | same, identical warnings | PRE-EXISTING, obsolete | 172 | The matrix moves `deals.stage_id` to Entregada and expects the BEFORE guard to suppress it. The `UPDATE OF stage_id` triggers were dropped by 172, so the stage simply changes and no guard runs (`deals` is inert). The guard that still matters (operations `status` completion) is exercised by other files (`operation-incident-reason` case 2 shows the coercion still works). | Re-point the matrix at `remittance_operations.status`, or retire. |
| deals-free-views-and-inert-edits | FAIL 3: [5a] fixture (125 creates no operation), [5a] delivery raised `operation not found`, [5a] "new body ADDS non-comment lines" | same | PRE-EXISTING, obsolete + stale body baseline | 172 (fixture); 257 (body diff) | Fixture needs the dropped trigger; the body-diff guard compares `crm_entregar_operacion` with the 164 body and 257 added `cup_source_card_id` lines. | Refresh the frozen body in the assertion, rewrite the fixture. |
| tag-sync-without-deals | FAIL 7 checks: tags stay `Nuevo`, `[7.5] deals_sync_tags is gone` | same | PRE-EXISTING, obsolete | 168_tags_off_delivered_operations / 172 | Fixture drives tags through deals; 172 dropped `deals_sync_tags` (its own header says the DROP TABLE owns it). | Rewrite on operations or retire. |
| chat-media-members-only-read | FAIL case 4 "chat-media must stay public" | same | PRE-EXISTING, stale vs redesign | 261 (private bucket; before the 265-279 range) | `storage.buckets.chat-media.public = false` on staging since 261; assertion 260 still demands public. | Update case 4 to expect private (261 has its own assertion that passes). |
| saldo-model | FAIL case 11 "a RECARGA line was priced with a USD sale rate and no recharge cost" | same | PRE-EXISTING, stale vs later change | 242 (before range) | The pending RECARGA line already carries `cost_gyd = 19.5` (500-tier cost snapshot from 242) while `missing_inputs` still lists `recargaCostoUsdt` (242 left `calculator_missing_rates` untouched). `crm_resolve_pending_entry` uses `coalesce(v_entry.cost_gyd, payload)`, so it resolves instead of raising 22023. Debug output confirmed. | Update case 11 to the tier-cost behaviour; decide separately whether `missing_inputs` should keep asking for `recargaCostoUsdt` (this is a real inconsistency visible in the panel). |
| feed-mixed | FAIL [5] found 0 pending lines (expected 2), [6] close counts 2 ops (expected 1). Cases 1-4 pass. Deterministic (3/3 runs) | same | PRE-EXISTING, stale vs later change | between 142 and 265 (feed body rewritten by 209/215/223/242/257; not bisected, outside the requested range) | The "gap" op (card 30000 CUP + Zelle with NULL amount) is now fed with 2 completed lines (CUP 30000, ZELLE 207): the Zelle share is inferred as the rest of the deposit, so it is never pending and the op counts in the close. | Decide if inferring the rest is the intended rule; if yes change cases 5-6 (expect completed, close counts 2). |
| duplicate-receipt-marker | FAIL duplicate key `comprobantes_hashes_pkey` | same | PRE-EXISTING, stale data on staging | n/a | A committed row `test-hash-duplicate-receipt-marker` (reenvios=3) was left in `comprobantes_hashes` by an earlier run outside a transaction (the file uses SAVEPOINT, not BEGIN). With that row deleted inside the transaction the assertion passes (ALL PASS). | `DELETE FROM comprobantes_hashes WHERE hash_imagen='test-hash-duplicate-receipt-marker';` on staging (not done here, read-only task). |
| contexto-envio-mixto | PASS, FAIL, PASS (3 runs) | FAIL 3/3 | FLAKY | n/a | Failure is `FAIL 1d: first part` = the recarga part instead of the clasica part: the two parts have the same `created_at` (one transaction), so their order is a tie. At base it fails 3/3 on the old resolver; with 265-279 it mostly passes. | Add a deterministic tiebreaker (e.g. order by id/position) in the function or in the fixture. |
| cup-excess-equivalent, target-origin-label, repeated-receipt, requested-amount-target | FAIL standalone (`pg_temp` helper missing) | n/a | HARNESS (prerequisite load) | n/a | Need helpers from other files. PASS with helpers loaded. | Make `relacionadas` load the prerequisites named in the header, or inline them. |
| live-baseline-parity, live-tables-baseline | CAPTURE mode, no assertion | n/a | HARNESS | n/a | One-shot capture files for migrations 109/112. | Retire. |

## Notes and limits

- No regression introduced by 265-279. For files that abort early on a fixture error (the "obsolete" group), later
  cases never run, so they say nothing about 265-279 either way: those later cases are unguarded until the fixtures are
  rewritten. Rolling back 172 itself on staging is not possible in a transaction: its rollback re-adds
  `depositos_mmg_deal_id_fkey` and fails validation against current rows ("violates foreign key constraint").
- `n8n-repoint`, `delivery` and `operation-incident-reason` guard functions that production still runs
  (`cerebro_registrar_deposito`, `cerebro_cruzar_deposito(s)`, `crm_entregar_operacion`); verify the same ground is
  covered by deal-free files before retiring.
- Runner scripts were kept outside the repo (scratchpad); the method is reproducible with `staging-migracion.sh
  relacionadas --ya-aplicada` semantics plus the rollback chain above.
