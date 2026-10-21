# CUP inventory: current balance you can adjust, lot history, and choosing the source card

## Objective
In the "Inventario CUP" page, each sending card shows its CURRENT CUP balance clearly and the owner can EDIT it (set the
real balance today); every loaded lot stays visible as history (loaded amount and what is left). Then, when an operator
completes a CUP transfer, they can CHOOSE the card the CUP left from (optional; default = the highest-priority card with
balance and limit, as today).

## Problem (verified 2026-10-20)
- Production has only phase 1 (migration 239): no automatic deduction, so a card's balance never goes down; the owner
  saw Eliaba ·6118 at 490,000 while the real balance is 222,840.
- The report `crm_inventario_cup` hides lots with remaining 0 (the used-up 250,000 lot of 15-oct vanished from view).
- A lot is editable only while untouched (`remaining = amount` and no consumptions); once it goes down it cannot be
  corrected, so a wrong balance cannot be fixed from the page.
- 2026-10-20 production data fix (owner): Eliaba lots set to remaining 0 (250,000 @960, 15-oct) and 222,840
  (240,000 @1015, 20-oct), loaded amounts kept, audited as human_correction by claude-code:owner-request. Done with
  direct UPDATEs (no consumption rows), to be expressed as adjustments once B1 exists.
- Phases 2 (240 deduction) and 3 (241 delivery panel plan) + 242 (recharge cost) are on staging only, blocked until now
  on "real balances first" because lots could not be edited after being consumed (odd/tasks/cup-card-inventory.md).

## Owner requests (2026-10-20)
1. Show the current balance of each card, editable; what was loaded stays as history.
2. Then (staging): choose the source card when completing a CUP transfer; not mandatory; default = priority.

## Design (Claude defaults, stated to the owner)
- Adjustment = consumption-ledger rows of kind `ajuste` (no operation/entry), so the history explains every change:
  setting a LOWER balance consumes the difference FIFO from the card's lots; a HIGHER balance returns CUP to the card's
  lots newest-first, never above a lot's loaded amount; more than that is refused ("load a new lot").
- Adjustments never count toward the card's daily limit (used today = operation/manual consumptions only).
- The report lists every lot of the card (used-up ones flagged), with loaded amount and remaining; the card shows
  "Saldo actual" prominently and an "Ajustar saldo" action (admin), with an optional reason; audited.
- Source-card choice (B3): an optional card picker in the CUP completion; the allocator starts from the chosen card
  (its balance and today's limit) and continues by priority for any rest; no choice = today's behaviour.

## Scope
In: DB (consumption kind, adjust RPC, report), API, page UI, tests; then the source-card choice; staging first.
Out: changing lot loading, bot changes.

## Constraints
- Staging first; production only with the owner's explicit go-ahead. Read the LIVE staging bodies before redefining
  (staging has 240-242 on top of 239; production has 239 only). Each migration: ROLLBACK file + self-reverting staging
  assertion. Never push origin, never merge to master.
- Production delivery will be the bundle 240 + 241 + 242 + this feature's migrations + the app at the feature branch
  (they depend on each other); after it, adjust Osmany's card when its balance is known.

## TDD
Strict (user global CLAUDE.md). Runners: staging assertions (`supabase/staging/assertions/*.sql`, via docker psql with
.env.staging) and `npm test` (vitest).

## Tasks
- [x] B1 — Migration 256 (4986870; applied on staging 2026-10-20, assertion green): consumption kind (operacion / manual / ajuste), `crm_ajustar_saldo_cup(card, saldo, motivo)`,
  report lists all lots + used today excludes adjustments; rollback; assertion. Staging.
- [x] B2 — (built, not yet deployed to staging; owner check pending) API route + page UI: "Saldo actual" + "Ajustar saldo" dialog + full lot history; vitest. Staging deploy +
  owner check.
- [x] B3 — Source-card choice at CUP completion (DB allocator start card + panel picker + tests). Staging + owner check.
- [x] B4 — Production bundle (240, 241, 242, 256+, app) after the owner's go-ahead; express the Eliaba fix as
  adjustments; adjust Osmany's card when known.

## Acceptance criteria
- Eliaba ·6118 shows Saldo actual 222,840 and both lots in history (250,000 used up; 240,000 with 222,840 left).
- The owner can set a card's balance from the page; the change is audited and does not touch today's limit.
- Completing a CUP transfer with a chosen card deducts from that card first; without a choice nothing changes.

## Progress
- 2026-10-20: mapped (report hides used-up lots; lots frozen once touched); Eliaba production data fixed (see Problem).

- 2026-10-20 B1: assertion RED (column kind does not exist) then GREEN; 256 applied on staging; rollback proof restores the 241/240 bodies
  (md5 d9d34bb0 / 45bf0f7d / 38ab75fc). Sign convention: increases are NEGATIVE ajuste rows (240 deletes on void; an adjustment is an
  audit fact and is appended, never deleted).
- 2026-10-20 B2: route POST /api/inventario-cup/cards/[cardId]/balance, read model (exhausted/adjusted/kind/reason), Saldo actual +
  Ajustar saldo dialog, full lot history; vitest 212 files / 2911 tests, tsc and eslint clean. UI not seen in a browser yet.

- 2026-10-20 B1+B2 verified by the parent: staging assertion cup-balance-adjust ALL PASS; vitest of the inventory
  (12 files / 186 tests) pass. BROWSER on staging (local next dev :3100, owner session): page shows "Saldo actual",
  "Ajustar saldo", "Historial de lotes"; adjusting PRUEBA Tarjeta B 205,000 -> 200,000 ("200.000") saved (POST 200),
  Usado hoy stayed 0, movement "Ajuste 5 000 · prueba de ajuste" listed; back to 205,000 ("205,000" read as thousands)
  saved; DB shows ajuste rows +5000 / -5000, remaining 205,000. Owner check pending.

- 2026-10-20 B3 (built; NOT ticked, parent verifies): migration 257 (eca3d86) + UI/API (d4c9806). Choice stored in
  remittance_operations.cup_source_card_id (FK cup_cards ON DELETE SET NULL), written by crm_entregar_operacion(uuid, jsonb, boolean,
  p_cup_source_card_id DEFAULT NULL) and crm_cerrar_operacion_manual(..., p_cup_source_card_id DEFAULT NULL) in the completing UPDATE; the
  feed passes v_op.cup_source_card_id to cup_consumir(7 args) -> cup_planificar(4 args: chosen card first, then priority). The 3-/6-argument
  cup_planificar / cup_consumir remain as wrappers; the three RPC overloads are replaced (named/positional old calls still resolve).
  Panel RPC crm_inventario_cup_operacion(op, p_source_card_id DEFAULT NULL) adds source_card_id + cards (active cards, balance, room today).
  Strict TDD: assertion cup-source-card.sql RED (column cup_source_card_id does not exist) then ALL PASS on staging; vitest RED 21 failed then
  GREEN. Staging apply + md5s in the commit report; the UI has a "Tarjeta de origen" select in the Transferir desde block (deliver path only;
  manual close supports the card in route/command/RPC but its confirmation control has no picker). Browser check pending.

- 2026-10-20 owner: balance at the size of the other figures and green -> 4499f57 (Figure valueClassName =
  moneyTextClass.profit, "Ajustar saldo" moved to the card header; RED -> GREEN, page tests 18/18, tsc + eslint clean).
  A formatter (not ours) later rewrote card-panel.tsx and page.test.tsx with single quotes / wrapped lines; verified
  formatting-only and restored to 4499f57.
- 2026-10-20 B3 verified by the parent: staging assertion cup-source-card ALL PASS; operations panel + remittance routes
  vitest 47 files / 835 pass. BROWSER on staging (op 008deb15, 260,000 CUP, ready_to_transfer): "Transferir desde" shows
  the "Tarjeta de origen" select (Automática + both cards with balance); choosing PRUEBA Tarjeta B re-read the plan with B
  first (B 120,000, A 120,000, "Faltan 20 000 CUP"); not completed (keeps the demo op). Manual close has no picker (RPC
  and route accept it) — ask the owner if wanted.

- 2026-10-20 manual-close picker (9367f0f): CupPlanBlock with the source-card select in the manual-close control of a
  CUP operation; RED 2 -> GREEN; vitest 212 / 2943; parent saw it in the browser on staging (op 008deb15), cancelled.
- 2026-10-21 B4 PRODUCTION (owner "añade el selector en cerrar manualmente y pásalo a producción"):
  read-only pre-flight: every object replaced by 240/241/242/256/257 byte-identical between production and staging's
  pre-bundle state; 29 dependencies identical; no n8n workflow (159, 33 active) calls the changed functions; SAFE.
  Applied 240, 241, 242, 256, 257 via Supabase MCP (02:47-02:52Z), all 19 function md5 == staging, 0 log errors.
  App release 9367f0f (branch release/prod-cup-bundle, pushed to privado; vitest 212/2943, tsc clean) BUILD_ID
  3OfxHW9WBZHp2Wb3C5coW; rollback release 6265edf. Production report: Osmany 250,000 (unconfirmed), Eliaba 222,840
  with the used-up 250,000 lot visible as history. `recarga_costo_usdt_500` is NULL in production (the owner sets
  "Costo recarga desde 500 (USDT)" in Control Semanal; 19.5 on staging).

## Next step
Owner adjusts Osmany ·9554 with "Ajustar saldo"; owner sets the 500 recharge cost; watch the first automatic deductions.
