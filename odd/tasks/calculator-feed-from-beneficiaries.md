# Calculator feed: resolve the service from the beneficiaries

## Objective
Every remesa completed since the feed started reaches the calculator. The feed does not depend on
the stale `remittance_operations.delivery_method`, and anything it cannot resolve is visible, never
silently skipped.

## Problem / why
- User, 2026-09-28: "ya se han completado algunas transferencias y no se suman automáticamente a la
  calculadora... eso era parte del objetivo".
- Evidence (prod, read-only):
  - The feed started on 2026-09-27 at 18:33Z (`calculator_feed_state`). Everything completed
    before that is excluded by design (104, assumption A1: no backfill).
  - Since then, 4 completed: 3 fed; 1 missing, `53d4e1f0` (23,400 GYD, 2 Zelle beneficiaries,
    40 + 50 USD, `source = admin_addition`, completed 2026-09-28 13:46Z).
  - Its `delivery_method` is NULL. `calculator_service_for_operation(NULL)` returns NULL, and
    `calculator_feed_operation` returns early with no entry.
  - `calculator_unfed_operations` also filters `service IS NOT NULL`, so the view is empty: the miss
    is silent.
  - Same root cause as the panel caption bug (per-beneficiary-delivery-proof P1):
    `delivery_method` is set only by the legacy notes trigger (042); the add-beneficiary RPC (123)
    and the reparto RPCs (127/129) never set it.
- Open remesas right now: 4, none with a NULL method (checked 2026-09-28).

## Approach
- Migration 141 (P2 of per-beneficiary-delivery-proof moves to 142):
  - A resolver: the operation's service comes from its CURRENT beneficiaries.
    - All zelle → ZELLE;
    - all cuban_card → CUP (one or many);
    - all clasica / tropical → that service;
    - mixed types → unresolved.
    - With no beneficiaries → the existing `delivery_method` mapping (legacy).
  - `calculator_feed_operation` uses the resolver. An unresolved operation does not vanish: it
    stays in `calculator_unfed_operations` with a reason, e.g. `service = NULL` shown.
  - `calculator_unfed_operations`: include completed-since-start operations whose service is NULL,
    so the gap is visible.
  - Optional, recommended: keep `delivery_method` in sync from the beneficiaries (trigger on
    remittance_beneficiaries), mapping to the existing vocabulary. Many cards →
    `multiple_distribution`; many Zelle → `zelle`.
- Data fix (prod, only with the user's OK): replay `53d4e1f0` through the existing
  `crm_feed_calculator` after 141.

## Constraints
- Money path: the formulas (104) and `feed-matrix.sql` parity stay unchanged; cards stay CUP.
- The 096 guard order: automation cannot feed or void; only the resolver changes.
- Staging first; prod only with the user's go-ahead.

## TDD
- Mode: strict. Runner: SQL assertions on staging (a rolled-back transaction):
  `supabase/staging/assertions/feed-matrix.sql` + a new `feed-from-beneficiaries.sql`.
- RED: a 2-Zelle op with NULL delivery_method, completed → no entry, and not in the unfed view.
- GREEN: ZELLE entry, amount = ceil(basis / usdt_sell_gyd); a mixed op shows up in the unfed view.

## Tasks
- [x] F1 — Assertions RED on staging; migration 141 + rollback; applied on staging; GREEN;
  feed-matrix.sql GREEN (one assertion updated, see below). Commit `d924890`.
- [x] F2 — Production: 141 + replay `53d4e1f0`; verify its entry (expected ZELLE 90 USD at 260,
  per the rates in force); the unfed view is empty.
- [ ] M1 — Mixed remesas (card + USD rail in one deposit) get one ledger line PER service. The user
  said "arreglemos lo de las mixtas" on 2026-09-28. Today the ledger allows one
  `completed_operation` entry per operation (unique on account_id, operation_id) and the resolver
  leaves mixed ops unresolved. Needs:
  - a GYD basis split per service (derive it the way 129's reparto sums GYD: USD parts =
    usd x usdt_sell_gyd, CUP part = the rest; if the data is missing → verified_pending naming what
    is missing);
  - the unique key and the void/revive paths per (operation, service);
  - the panel readers of the ledger kept correct.
  Staging first; prod with the user's go-ahead.

## Progress
- 2026-09-28: root cause found (read-only); document created.
- 2026-09-28: F1 done, staging only (wacrm-ensayo).
  - Checked `git log -p` first: no migration after 105 redefines
    `calculator_feed_operation` / `calculator_unfed_operations`, but 111 flipped the
    dollar-rail rounding in the SHARED `calculator_amount_from_basis` from ceil to
    floor (105 already routes through it) — confirmed against staging with
    `pg_get_functiondef` before writing assertions. So the task's ZELLE formula note
    ("amount = ceil(...)") is stale; the actual (and correct) LATEST behavior is
    floor, matching `feed-matrix.sql`'s own comment ("floor 98.11" -> 98). Wrote the
    new assertion against floor, not ceil.
  - `supabase/staging/assertions/feed-from-beneficiaries.sql`: RED before 141, for the
    right reasons — case 1 (2-Zelle, NULL delivery_method) and case 2 (2-card, NULL)
    had NO entry (`calculator_service_for_operation(NULL)` is NULL); case 3b (mixed
    card+Zelle) was invisible in `calculator_unfed_operations` (old view filtered NULL
    service out); case 5 (stale `delivery_method='cuban_card'` with current Zelle
    beneficiaries) fed a WRONG CUP entry (39000, off the stale column) instead of
    ZELLE. Case 4 (legacy op, no beneficiaries) passed already, as the control.
  - Resolver `calculator_resolve_operation_service(operation_id, delivery_method)`:
    current ('vigente') beneficiaries win; one shared `beneficiary_type` maps through
    the existing `calculator_service_for_operation` table (same vocabulary as
    `delivery_method` — verified byte-for-byte: cuban_card/zelle/clasica/
    tropical/multiple_distribution); mixed types -> unresolved (NULL); zero current
    beneficiaries -> the legacy `delivery_method` mapping, unchanged.
    `calculator_feed_operation` and `calculator_unfed_operations` both call it.
    Formulas/rates/trigger guard order untouched (verbatim from 105/111).
  - `calculator_unfed_operations` gained `unfed_reason` (additive column;
    `grep -rn calculator_unfed_operations src/` found no reader to keep compatible
    with) and dropped the old `service IS NOT NULL` filter, so a service the resolver
    cannot determine is now listed with `unfed_reason = 'service_unresolved'` instead
    of silently excluded. The `quoted_source_amount > 0` bound is untouched —
    deliberately out of scope for this slice.
  - Migration 141 applied cleanly to staging (wacrm-ensayo). GREEN:
    `feed-from-beneficiaries.sql` 6/6 PASS; `feed-matrix.sql` 20/20 PASS after
    updating case 16 (the fixture's unmapped-delivery-method, no-beneficiaries op is
    now the one expected row in the unfed view, with `unfed_reason =
    'service_unresolved'` — that visibility is this migration's whole point, not a
    money-path change); `reparto-auto.sql` 13/13 PASS; `delivery-feed-evidence.sql`
    2/2 PASS. `delivery.sql` has one pre-existing case-1 failure (deal stage not
    flipping to ENTREGADA) reproduced identically on staging BEFORE 141 too (tested by
    temporarily applying and re-verifying `ROLLBACK-141`, then reapplying 141) —
    unrelated to the calculator feed, not touched by this change.
  - `ROLLBACK-141` restores 105's `calculator_feed_operation` and 104's
    `calculator_unfed_operations` verbatim; had to `DROP VIEW` first (Postgres refuses
    `CREATE OR REPLACE VIEW` when it would drop a column) — caught and fixed by
    actually running the rollback on staging, not just reading it.
  - `delivery_method` sync from beneficiaries: SKIPPED, per the task's "otherwise skip
    and say why" — it would need its own handling of 096's admin-lock guard on
    `delivery_method` (separate from the `beneficiaries` lock the add-beneficiary/
    reparto RPCs already set) and the `wacrm.origin` juggling the reparto RPCs already
    do for their own lock writes, and buys nothing for F1 since the feed now reads the
    beneficiaries directly.
  - Commit `d924890` — `fix(db): calculator feed resolves the service from
    beneficiaries (141)` — 141, ROLLBACK-141, feed-from-beneficiaries.sql,
    feed-matrix.sql (case 16 update).

- 2026-09-28 F2 — production, with the user's go-ahead ("aplica en producción"):
  - Checked first: the prod `calculator_feed_operation` still used
    `calculator_service_for_operation(v_op.delivery_method)`, i.e. the definition ROLLBACK-141
    restores.
  - Applied 141 (MCP). The unfed view then listed exactly `53d4e1f0` as ZELLE.
  - Replayed with `calculator_feed_operation` directly as the DB owner: `crm_feed_calculator` only
    adds an admin check on top, so no impersonation was needed. Entry `dac88541`: ZELLE 90 USD,
    completed, 2026-09-28, Daney Ruiz Ferrer, usdt_sell_gyd 260, facturado 23,400, invertido
    21,600, retorno 1,800.
  - Unfed view: 0 rows.

## Next step
M1 (mixed remesas).
