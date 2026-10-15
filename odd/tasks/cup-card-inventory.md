# Feature: CUP inventory per sending card (lots, priority, daily limit)

## Objective
The profit of every CUP remesa reflects what that CUP really cost the owner (Osmany), according to the sending card
and the lot it came from. The system tracks his own sending cards, the CUP lots loaded on each (amount + purchase
rate in CUP per USDT), the daily transfer limit, and which card to use next.

## Owner decisions (2026-10-14, one question at a time)
- Scope: CUP only for now.
- The SYSTEM picks the card, by an owner-defined PRIORITY order, and shows the operator which card to use.
- Cost per LOT, FIFO inside each card (not a weighted average).
- When the card's remaining daily limit or balance is short, the remesa is SPLIT across cards (priority order).
- Deduction happens in BOTH cases: a CUP operation is completed (panel, crm_entregar_operacion) AND a manual CUP line
  is registered in Control Semanal (crm_registrar_entradas_manuales, 228).
- Manual lines: the rate Osmany typed WINS; inventory only deducts the CUP. CRM/bot operations: the consumed lots'
  rate becomes the entry's cup_rate.
- No card with limit today: the operation waits for the next day (manual lines, already transferred, register anyway
  with a warning).
- Daily limit 120,000 CUP per card, reset at MIDNIGHT CUBA (America/Havana), unlike the rest of the system (Guyana).
Claude defaults (stated to the owner):
- A manual rate edit on an entry (236-238) changes only that entry's profit; inventory untouched.
- An inventory failure never passes silently: alert.
- Manual lines cannot be deleted today, so their CUP cannot be returned yet (later).
- Cards are stored by name + optional last 4 digits (no full card number).

## Current state (mapped 2026-10-14)
- No sending-card model exists (only beneficiary receiving cards in remittance_beneficiaries, deposit accounts
  depositos_mmg). account_id is the tenant.
- CUP op completion is human: crm_entregar_operacion (101) -> completed -> trigger feeds calculator_feed_operation
  (235) inside EXCEPTION WHEN OTHERS (audits calculator_feed_failed, never blocks delivery). cup_rate from
  calculator_rates_vigentes usdt_sell_cup (235:126, 182).
- Manual: crm_registrar_entradas_manuales (228:74), Guyana day, advisory lock calculator-cut:<account>.
- Void paths: trigger 104:375 (op leaves completed -> entry void), 226 delete (chat entries only).
- Delivery UI: src/components/inbox/operations/complete-transfer-*.tsx, route deliver.

## Phases
1. Inventory CUP: tables + admin screen (cards, lots, balance, remaining limit today). <- this document's first slice
2. Automatic deduction on completion and manual registration, FIFO + split, lot rate for CRM ops, return on void.
3. Delivery panel shows "usa tarjeta X: n" and the wait-until-tomorrow warning.

## Phase 1 scope
- Migration 239 (+ROLLBACK, staging assertion): tables cup_cards (account_id, name, last4, priority, daily_limit_cup
  default 120000, active, timestamps), cup_lots (card, amount_cup, remaining_cup, rate_cup_per_usdt, loaded_at, note,
  created_by), cup_lot_consumptions (lot, entry/operation refs nullable, amount_cup, consumed_at, cuba_day) - empty in
  phase 1, created now so the report computes remaining limit. RLS: members read; writes only through admin
  SECURITY DEFINER RPCs: save card (create/update/reorder/deactivate), load lot, correct/delete a lot only while
  unconsumed, inventory report (per card: balance, lots, used today and remaining limit for the current Cuba day).
- API routes + tests; admin-only page "Inventario CUP" (Spanish), sidebar entry for admins, i18n es/en.
- Out of scope in phase 1: any deduction, delivery panel, bot.

## Constraints
- Staging first; production only with explicit go-ahead. Conventional Commits, no AI trailer. Do not restyle.
- TDD strict (RED -> GREEN -> REFACTOR). Runner `npm test` (vitest); SQL assertions in supabase/staging/assertions/.
- RDD off.

## Tasks
- [x] T1 Migration 239 tables + RPCs + rollback + staging assertion (07b3fda; SQL NOT run, pending staging run in T4)
- [x] T2 API routes + tests (fcf8040)
- [x] T3 "Inventario CUP" admin page + sidebar + i18n (+ tests for pure logic) (7310a83)
- [ ] T4 Staging apply + deploy + owner check (needs authorization)
- [ ] T5 Production (needs go-ahead)
- [ ] Phase 2 and 3: planned after phase 1 is in use

## Acceptance criteria (phase 1)
- Admin creates cards A (priority 1) and B (priority 2), loads 500,000 CUP at 960 on A and 250,000 at 1060 on B,
  sees balances and 120,000 remaining limit for today (Cuba day) on each.
- Agents/viewers cannot see the page nor call the write RPCs.

## Progress / evidence
- 2026-10-14: document created after design Q&A and exploration (16102fe).
- 2026-10-14 T1-T3 done. T2/T3 strict TDD: RED observed (missing modules) then GREEN. Final: npx vitest on new files green
  (routes+lib 100 tests, page+lib 95), npm test 201 files / 2724 tests pass, npx tsc --noEmit clean, eslint on changed dirs clean.
  Migration 239 and assertion cup-card-inventory.sql were written without a SQL engine (psql unavailable): UNVERIFIED until T4.
  Open choices made by default: report RPC is admin+ (not any member); lots fully consumed drop out of the report; inactive
  cards hidden unless includeInactive=1; decimal parsing treats a lone "." + 3 digits as thousands (es habit).

## Next step
T4: apply 239 to staging and run the assertion (needs owner authorization), deploy, owner check.
