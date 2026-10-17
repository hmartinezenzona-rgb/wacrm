# Feature: per-tier recharge cost and per-operation cost edit (recargas / saldo móvil)

## Objective
The Calculator/Finanzas investment of ETECSA recharges and saldo móvil reflects what Osmany really pays:
(1) two recharge costs, one per ETECSA promotion tier (starts at 500 CUP / starts at 600 CUP), each recharge costed
with its tier; (2) from "Editar" in Control Semanal, an admin can change the cost in USDT of one recharge or saldo
operation (provider discount, cheaper provider), recomputing invertido/retorno everywhere.

## Owner facts (voice notes 2026-10-16, Engram negocio/recargas-saldo/costos-osmany)
- Promo from 500 CUP: provider 19.5 USDT; sold 5,200 GYD. Promo from 600 CUP: 23.1 USDT (sometimes 22.8); sold
  6,200 GYD. USDT cost 238 or 240 GYD. invertido = cost_usdt x usdt_buy_gyd; retorno = facturado - invertido.
- Saldo móvil: per 360 CUP, provider A 1.6 USDT, provider B 2 USDT; sold 1,000 GYD.
- Owner go-ahead 2026-10-17: "sí, empieza con las dos cosas".

## Current state (production 2026-10-17)
- calculator_rate_versions latest: recarga_costo_usdt 23.1 (ONE value for both tiers), saldo_costo_usdt 2,
  usdt_buy_gyd 240. cerebro_servicios 'recargas' prices 5,200 / 6,200 (no per-tier cost).
- A 500-tier recharge is costed 23.1 x 240 = 5,544 > 5,200 billed -> shown as a loss (real profit ~520).
- Per-entry rate edit (migrations 236-238, crm_corregir_tasas_entrada_calculadora) edits usdt_buy_gyd / cup_rate only;
  manual RECARGA / SALDO_MOVIL rows are refused (unit cost only in raw_line).
- Relevant: migrations 198/199 (recarga_costo_usdt, cerebro_recarga_unidades), 223 (saldo_costo_usdt, SALDO_MOVIL),
  235 feed, 236-238 rate edit, src/lib/calculator/*, Calculadora rates UI.

## Design (Claude defaults, to confirm with the owner when shown)
- Tier of a recharge decided by its sale price per unit (5,200 -> 500 tier, 6,200 -> 600 tier); unknown price ->
  the 600-tier cost (current behaviour) and flagged.
- New global rate field for the 500-tier cost (recarga_costo_usdt stays as the 600-tier cost), editable in the
  Calculator rates panel like the other rates; snapshotted per entry.
- Per-operation cost edit: Editar on a RECARGA / SALDO_MOVIL entry shows "Costo por recarga (USDT)" /
  "Costo por 360 CUP (USDT)" and Compra USDT (GYD); changing them recomputes invertido/retorno; no audit row
  (owner rule for rate edits). Manual lines included when their cost can be read from the typed line.
- Staging first; production only with explicit go-ahead.

## Constraints
- TDD strict (RED -> GREEN -> REFACTOR); runner `npm test` (vitest); SQL assertions in supabase/staging/assertions/.
- Conventional Commits, no AI trailer. Do not restyle. Next migration number after 241.

## Tasks
- [ ] T1 Map the recharge / saldo cost flow (feed, manual lines, rates UI) and confirm the tier rule
- [ ] T2 Migration: 500-tier cost rate + feed uses the tier; rollback; assertion
- [ ] T3 Migration/RPC: per-operation cost edit for RECARGA / SALDO_MOVIL (chat + manual); rollback; assertion
- [ ] T4 UI: rates panel field + Editar cost fields + read model + tests
- [ ] T5 Staging apply + deploy + owner check (needs authorization)
- [ ] T6 Production (needs go-ahead)

## Acceptance criteria
- A 500-tier recharge with rates 19.5 / 240 shows invertido 4,680 and retorno 520 on 5,200.
- Editing a 600-tier recharge cost to 22.8 recomputes invertido 22.8 x buy; facturado unchanged.
- Editing a saldo entry cost to 1.6 recomputes invertido.

## Progress / evidence
- 2026-10-17: document created from the owner's voice notes and a read-only production check.

## Next step
T1.
