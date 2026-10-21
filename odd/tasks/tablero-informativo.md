# Operations board that says what each operation is

## Objective
The operations board (`/tablero`) card shows the real rail (Zelle, Clásica, CUP, Tropical, efectivo…) instead of the
generic "Remesa", what the recipient gets next to the GYD deposited (e.g. `18.200 GYD → 70 USD`), who receives it, and
a mark for mixed sends. Owner request 2026-10-21.

## Problem (verified 2026-10-21, production, last 30 days)
- 102 of 110 remesas (93 %) have `delivery_method` NULL; the rail lives in the vigente beneficiaries (all 102 have one).
  `operationServiceId` (src/lib/service-name.ts:125) can derive the rail from `beneficiaryTypes`, but the board passes
  only serviceType + deliveryMethod (src/components/tablero/operations-board.tsx:67), so the card says "Remesa".
- 90 of those 102 have `quoted_destination_amount`; the board RPC `crm_tablero_operaciones` (last defined in migration
  219) does not return it, nor the recipient.

## Scope
- Migration (next free number, 258 expected): `crm_tablero_operaciones` also returns, per operation: the vigente
  beneficiary types (text[]), `quoted_destination_amount`, `destination_currency`, a recipient label and the recipient
  count, and `mixed_group_id`. Recipient label rule: the first vigente beneficiary by position: its name if present;
  otherwise for cards "Tarjeta ·<last4>", for Zelle the account, for recargas/saldo the phone; "+N" handled in the UI from
  the count. Live staging body first (pg_get_functiondef), ROLLBACK, self-reverting assertion.
- `src/lib/tablero/{board,fetch}.ts` read the new fields; `operations-board.tsx` card: rail name via operationServiceName
  with beneficiaryTypes; `18.200 GYD → 70 USD` (destination only when present and not GYD; reuse
  `mixedShareDestination`-style formatting); recipient line (label, and "+N" when more than one); a small "Envío mixto"
  mark when mixed_group_id is set. i18n es/en. Minimal style consistent with the board.
- Out of scope: chat operations panel (already shows beneficiaries).

## Constraints
- Staging first (skill wacrm-migraciones), browser check on staging (wacrm-probar-staging), production with the owner's
  go-ahead (wacrm-migraciones previa/aplicar/verificar, then wacrm-publicar-panel).
- Card numbers only as last 4.

## TDD
Strict. Runners: staging assertion via `infra/db/staging-migracion.sh aplicar`; `npx vitest run` for board/fetch/card.

## Tasks
- [x] T1 — Migration + rollback + assertion; applied on staging.
- [x] T2 — Board read model + card UI + tests.
- [ ] T3 — Browser check on staging (PRUEBA fixture), owner check.
- [ ] T4 — Production: migration (previa/aplicar/verificar) then panel publish, with go-ahead.

## Progress
- T1 (migration 258, cf9f169) and T2 (board read model + card UI) were implemented and checked on staging (local :3100).
- 2026-10-21 owner check: GYD too large and CUP amount missing; adjusted in 92847c4.

## Status: CANCELLED by the owner (2026-10-21)
Owner: "déjalo como está ahora el de producción, no me gustó ese cambio que le hicimos al panel".
- Production never touched (no migration 258, no panel publish).
- Staging: ROLLBACK-258 applied; crm_tablero_operaciones md5 back to 11379ddcbc226d516f4a422ab1f95ca5 (pre-258).
- Branch: commits cf9f169, f288d42, 92847c4 reverted.

## Next step
None.
