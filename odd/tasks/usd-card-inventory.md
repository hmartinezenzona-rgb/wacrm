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
- [ ] T2 Migration 356: plan / consume / return for USD, feed cost from lots, manual lines, void and delete paths,
      hard block in crm_entregar_operacion + crm_cerrar_operacion_manual, panel plan RPC; rollback; assertion
- [ ] T3 API routes + lib (read model, payloads, forms, format) for USD cards and lots + tests
- [ ] T4 Unified "Inventario de tarjetas" page per the approved design (CUP + Clásica + Tropical), sidebar, i18n, tests
- [ ] T5 Delivery panel: USD plan block + refusal mapping for the insufficient-balance block + tests
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

## Next step
T2.
