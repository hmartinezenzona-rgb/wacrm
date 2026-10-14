# Feature: edit the investment rates of one calculator entry

## Objective
From "Editar" in Control Semanal (/calculadora), an admin sees the rates a single remesa or service was costed with and
can change its investment rates. Invertido and retorno for that entry are recomputed, and the change flows everywhere
(Control Semanal totals, Finanzas Resumen, cierre financiero, dashboard). The customer price, facturado, the global
rates and the bot quote do not change.

## Owner request (2026-10-14)
Osmany invests at different prices. Example: CUP bought at 1060 CUP per USDT, then the card runs out for the day and he
uses another one bought at 960. The internal control must reflect the real investment of each operation. The global
"Tarifa CUP" (3 CUP per GYD) stays the same; this is only internal control.
Owner decisions:
- Both investment rates are editable: "Venta USDT (CUP)" (snapshot `cup_rate`, CUP service only) and
  "Compra USDT (GYD)" (snapshot `usdt_buy_gyd`, every service).
- The change must reach Finanzas as well ("debe repercutir en todo").
- NO audit/history row for rate edits (owner declined it explicitly).

## Current state (mapped 2026-10-14)
- Per-entry rate snapshot on remittance_calculator_entries (095/104): cup_global_rate, cup_rate, usdt_buy_gyd,
  usdt_sell_gyd, rate_version_id; stored facturado_gyd / invertido_gyd / retorno_gyd.
- invertido (SQL calculator_invertido, 105; TS twin src/lib/calculator/formulas.ts calculateEntry). CUP:
  (amount / cup_rate) * usdt_buy_gyd. RECARGA / SALDO_MOVIL: cost_usdt * usdt_buy_gyd.
- Completed rows are locked by remittance_calculator_entries_lock_completed (104, 149 GUC hole
  wacrm.calculator_correction, 228 manual rows). Template: crm_corregir_entrada_calculadora (149, 228).
- Finanzas (crm_cierre_financiero 228, cerebro_dashboard_resumen 234) read the STORED figures, so no Finanzas change.
- Archived weeks (227/228 remittance_calculator_weeks) snapshot figures as jsonb.
- Existing Editar (page.tsx ~358, ~827) edits facturado/invertido in GYD via
  POST /api/calculator/entries/[entryId]/correct.

## Scope
- New migration 236 + ROLLBACK-236 + staging assertion: admin-only SECURITY DEFINER RPC that sets the entry's
  investment rate(s), recomputes invertido from the entry's own stored amount/service/snapshot and retorno =
  facturado - invertido. facturado, cup_global_rate, usdt_sell_gyd untouched. Refuses: non-admin, missing/deleted/void
  entry, entry in an archived week, cup_rate on a non-CUP service, non-positive rates.
- New API route + route test.
- Editar UI shows the snapshot rates and lets the admin change the two investment rates, with recomputed figures.
- Out of scope: audit row, global rate changes, bot quote, editing archived weeks.

## Constraints
- Staging first; production only with the owner's explicit go-ahead.
- Conventional Commits, no AI trailer. Do not restyle anything not asked for.
- TDD strict: RED -> GREEN -> REFACTOR. Runner: `npm test` (vitest); SQL assertions in supabase/staging/assertions/.
  Mode source: user global instructions (Strict TDD Mode: enabled).
- RDD: off (decided by default).

## Tasks
- [x] T1 Migration 236 RPC + rollback + staging assertion file (commit b05acd8; SQL assertion written, NOT run: pending staging run in T4)
- [x] T2 API route + route test (commit be3de6a; RED 21 failed -> GREEN 21 passed)
- [x] T3 Editar UI: show snapshot rates, edit both investment rates, recompute preview; read-model mapping + tests (commit 9104d23)
- [ ] T4 Apply 236 on staging, deploy staging, owner checks (needs owner authorization)
- [ ] T5 Production (needs owner go-ahead)

## Acceptance criteria
- Editing a CUP entry from 1060 to 960 changes only its invertido/retorno; facturado unchanged.
- Control Semanal totals and Finanzas Resumen reflect the new figures.
- Customer price / global rates unchanged.

## Progress / evidence
- 2026-10-14: document created, exploration done.
- 2026-10-14: T1-T3 implemented on feat/port-chat-operations-calculator. No local wacrm database was available (the only local
  Postgres is the unrelated remittance-core container), so migration 236 and its assertion
  (supabase/staging/assertions/calculator-entry-investment-rates.sql) are UNRUN: pending staging run (T4).
- RPC crm_corregir_tasas_entrada_calculadora(entry, usdt_buy_gyd, cup_rate). The 149 lock-trigger hole (wacrm.calculator_correction)
  only guards amount/service/operation_id/rate_version_id, so the rate snapshot columns need no trigger change and the hole does NOT
  force an audit row (only the 149 RPC writes one by its own choice): none is written, as decided.
- Per service: CUP (amount/cup_rate)*buy; RECARGA amount*cost_gyd*buy (cup_rate snapshot = buy rate, kept equal); SALDO_MOVIL
  (basis_gyd/sale_gyd)*cost_gyd*buy (amount is saldo units; cup_rate kept equal to buy); ZELLE/MLC/CLASICA/TROPICAL/USDT/EFECTIVO/DIRECTO
  amount*buy; COMBO/VISA refused (no rates); manual, void, pending and archived-week entries refused; cup_rate refused off CUP.
- Verification: new/changed vitest files green (route 21, entry-rates 13, page 106), npm test 189 files / 2556 tests, tsc 0, eslint 0.

## Next step
T4: apply migration 236 on staging, run the assertion inside BEGIN..ROLLBACK, deploy staging, owner checks (needs owner authorization).
Then T5 production (needs the owner's go-ahead).
