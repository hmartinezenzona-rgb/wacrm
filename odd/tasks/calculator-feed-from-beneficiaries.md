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
- [ ] F1 — Assertions RED on staging; migration 141 + rollback; applied on staging; GREEN;
  feed-matrix.sql unchanged GREEN.
- [ ] F2 — Production: 141 + replay `53d4e1f0`; verify its entry (expected ZELLE 90 USD at 260,
  per the rates in force); the unfed view is empty.

## Progress
- 2026-09-28: root cause found (read-only); document created.

## Next step
F1.
