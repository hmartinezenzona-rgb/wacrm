# Feature: Clásica and Tropical card inventory (USD lots, monthly limit, real cost)

## Objective
Clásica and Tropical sends draw from the owner's own bank-issued USD cards. The system tracks those cards, the USD
lots bought on each (USD amount + USDT paid), the monthly limit, and blocks a completion when the balance is short.
The profit of every Clásica/Tropical send uses the real cost of the lot it came from.

## Owner answers (Osmany via the owner, 2026-11-06)
- Clásica/Tropical balance is always bought with USDT at a discount in his favor (500 USD at 5% = 476.19 USDT; sometimes 1x1).
- Balance is tracked in USD (what the beneficiary receives). The lot cost applies to every send drawn from that lot.
- Clásica and Tropical are separate accounts: one bank card per service, like CUP cards.
- Limit: no bank figure yet; use the old MLC reference, 5,000 USD PER MONTH per card.
- Money leaves the matching Clásica/Tropical card; today he records it in the normal CRM record.
- Client price is 260 GYD per USD (usdt_sell_gyd); accounting cost uses the USDT cost (usdt_buy_gyd, lately 238) and the lot rate.
- Zelle stays out. USDc is not used.
- Insufficient balance: the send cannot be completed until more balance is bought (no fallback to the global rate).
- Minimum 20 USD for Clásica/Tropical is already live (migration 306/307); nothing to do.
- Visual design approved 2026-11-06: one "Inventario de tarjetas" page, service totals strip, service filter chips,
  compact card rows (service chip, last4, balance, limit bar: today for CUP, this month for USD), expandable lots
  table, red row when a card has no balance. Mockup: https://claude.ai/artifact/V72CaPU7NoGQw3QwiYxzzE

## Claude defaults (stated to the owner)
- Parallel table set (usd_cards, usd_lots, usd_lot_consumptions) instead of a service column on cup_cards: the CUP
  inventory has 6 SQL callers and 6 staging assertions bound to its signatures; a parallel set leaves them untouched.
- Each USD card has a service (CLASICA | TROPICAL), priority, monthly_limit_usd default 5000; FIFO lots; split across
  cards of the same service by priority (same algorithm as CUP). Month = Cuba calendar month (America/Havana).
- Lot rate stored as usd_per_usdt = amount_usd / usdt_paid (5% lot: 1.05; 1x1: 1.00).
- Entry cost for CLASICA/TROPICAL CRM entries: invertido_gyd = sum(part_usd / lot_usd_per_usdt) * usdt_buy_gyd.
- Hard block in crm_entregar_operacion and crm_cerrar_operacion_manual (22023, mapped refusal in the panel) ONLY when
  the account has at least one active card of that service; an account with no USD cards keeps today's behavior, so
  production does not stop before Osmany loads his cards.
- Manual Clásica/Tropical lines (already transferred) consume inventory; typed numbers win; a shortfall alerts, never blocks.
- Void / delete of a CLASICA/TROPICAL entry returns its USD to the lots.

## Scope
In: DB (tables, admin RPCs, report, plan/consume/return, feed cost, block, manual lines, void paths), API, the
unified page per the approved design (CUP + USD), the delivery panel plan for USD ops, tests, staging.
Out: Zelle, bot/n8n changes, the 20 USD minimum (done), production (needs explicit go-ahead).

## Constraints
- Staging first; production only with the owner's explicit go-ahead. Read the LIVE staging bodies before redefining.
- Strict TDD (RED -> GREEN -> REFACTOR). Runner `npm test` (vitest); SQL assertions in supabase/staging/assertions/
  (self-reverting psql, `\set ON_ERROR_STOP on`). Migrations start at 355, each with ROLLBACK-NNN.
- Conventional Commits, no AI attribution. Push only to remote `privado`. Scan diffs for real customer data before push.
- Never touch the other session's uncommitted files (pruebas/decisor/decisor.jscode, correr.ts, decisor-notas.test.ts,
  odd/tasks/bot-brevedad.md).
- RDD: off (default source). TDD: on (user global CLAUDE.md "Strict TDD Mode: enabled"), runner `npm test`.
- Delivery: commits on feat/port-chat-operations-calculator, as in every previous feature of this repo (no PRs).
  Forecast well above 400 authored lines; slices are the tasks below.

## Tasks
- [x] T1 (64c523f) Migration 355: usd_cards / usd_lots / usd_lot_consumptions + admin RPCs (save card, load lot, correct/delete
      untouched lot, adjust balance, report with balance and month usage) + rollback + staging assertion
- [x] T2 (a0c4b05; assertion helper fix cc50294) Migration 356: plan / consume / return for USD, feed cost from lots, manual lines, void and
      delete paths, hard block in crm_entregar_operacion + crm_cerrar_operacion_manual, panel plan RPC; rollback; assertion
- [x] T2b (c64241c) Migration 357: crm_resolve_pending_entry consumes USD for a resolved pending CLASICA/TROPICAL line; rollback; assertion usd-inventory-pending.sql
- [x] T3 (56466f9) API routes + lib (read model, payloads, forms, format) for USD cards and lots + tests
- [x] T4 (e27247f) Unified "Inventario de tarjetas" page per the approved design (CUP + Clásica + Tropical), sidebar, i18n, tests
- [x] T5 Delivery panel: USD plan block + refusal mapping for the insufficient-balance block + tests
- [ ] T6 Staging: apply 355-356, run assertions, deploy, demo cards/lots, owner check
- [ ] T7 Production (needs the owner's explicit go-ahead)

## Acceptance criteria
- Admin creates a Clásica card and a Tropical card, loads 500 USD for 476.19 USDT on Clásica, sees 500 USD balance
  and 0 / 5,000 USD used this month.
- Completing a 100 USD Clásica send consumes 100 USD from the oldest lot; the entry's invertido_gyd =
  100 / 1.05 * usdt_buy_gyd; the page shows 400 USD left and 100 / 5,000 used.
- A Tropical send larger than the Tropical balance cannot be completed; the panel says how much is missing.
- Cancelling the completed send returns the USD to its lot.
- CUP inventory behavior and its staging assertions are unchanged.

## Progress / evidence
- 2026-11-06: document created after the design approval and a read-only map of the CUP inventory.
- 2026-11-06: T1 written in 64c523f (355, ROLLBACK-355, assertion usd-card-inventory.sql). SQL UNVERIFIED: RED/GREEN runs pending the T6 staging run; no local SQL engine.

- 2026-11-06: T2 verified on STAGING in rolled-back transactions only (nothing applied). RED: assertion without 355/356 ->
  'relation "usd_lots" does not exist'; with 355 only -> 12 FAIL lines (no consumption, invertido = 100*238 not 100/1.05*238) then
  'function usd_planificar(uuid, unknown, integer, timestamp with time zone) does not exist'. GREEN: 355+356+assertion -> 60 PASS,
  'ALL PASS (rolled back on purpose)'. T1 assertion (first real run) needed helper fixes (cc50294, claims were reset), then GREEN on 355.
  CUP regression, base vs 355+356: cup-inventory-consumption 49/49, cup-inventory-panel 27/27, cup-source-card 31/31, cup-card-inventory 52/52,
  cup-balance-adjust 38/38 (identical to base); 54 related assertions base vs mig: 53 SAME, 1 DIFF that is only a uuid in an already
  failing fixture message (delivery-feed-evidence). ROLLBACK-356 gives back the 6 previous md5s and ACLs, 9 new functions dropped.
- Decisions made in T2 (owner defaults, not asked): the 5,000 USD monthly limit is INFORMATIONAL (balance only restricts); the block works
  PER OPERATION (the feed consumes per operation; the group-wide logic in delivery only concerns verified funding); Mexico operations
  (priced as CLASICA) never consume nor block; notifications reuse type 'inventario_cup'; cost_gyd of USD entries stays NULL, the lot
  cost lands in invertido_gyd. Refusal: 22023 'usd_inventory_insufficient:<SERVICE>:<missing> (needs N USD, M USD available)'.
- 2026-11-06: T2b (c64241c) closes that gap. Parent default: a resolved pending line is treated like the feed (kind 'operacion', or 'manual'
  without operation); the entry's recorded buy rate wins; shortfall/failure alert, never block; Mexico excluded. Live md5 874a3f1b62cb
  replaced; ROLLBACK-357 restores it (same md5 and ACL). RED (355+356 only): 7 FAIL (e.g. invertido=23800 instead of 100/1.25*238, nothing
  consumed, no alert), GREEN with 357: 13 PASS, 'ALL PASS (rolled back on purpose)'. Regression with 355+356+357 loaded: usd-card-inventory 89,
  usd-inventory-consumption 60, usd-inventory-pending 13, cup-inventory-consumption 49, cup-inventory-panel 27, cup-source-card 31,
  cup-card-inventory 52, cup-balance-adjust 38: 0 FAIL.
- 2026-11-06: T3 (56466f9). RED: `Cannot find module './format'` (4 lib files) and `Cannot find module '/src/app/api/inventario-usd/route'` (6 route files).
  GREEN: usd-inventory lib 4 files + cup-inventory = 190 tests pass; inventario-usd routes + inventario-cup routes 12 files / 75 tests pass; tsc and eslint clean.
  Only change to CUP code: cup-inventory/payloads.ts now exports its small validation helpers (fail, isObject, unknownKey, isPositive, parseNote, limits) for reuse.
- 2026-11-06: T4 (e27247f). RED: 20 page tests failed (e.g. `TypeError: Cannot read properties of undefined (reading 'querySelector')`), unify lib `Cannot find module './unify'`.
  GREEN: page 39 tests, unify 8, sidebar-nav after label change; tsc/eslint clean. Adapted CUP tests: page.test.tsx (mount() now expands rows, fetch mocked by URL because the page also reads
  /api/inventario-usd and /api/calculator/rates) and sidebar-nav.test.ts (nav label now "Inventario de tarjetas"/"Card inventory"). card-panel.tsx replaced by card-row.tsx.
  Cost per USD column uses GET /api/calculator/rates (usdtBuyGyd/usdtSellGyd, today's rates, not historic); omitted when rates are absent.
- 2026-11-06: T5. RED: panel.ts `Cannot find module './panel'`, usd-plan route module missing, refusal `expected null to deeply equal {...}`, usd-plan-block module missing.
  GREEN: full `npm test` 289 files / 3973 tests pass; tsc and eslint clean. Complete button disabled while the plan is blocked (container test).

## Next step
T6 (staging). T5 maps the refusal prefix and renders crm_inventario_usd_operacion.
