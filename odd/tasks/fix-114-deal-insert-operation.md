# Fix: deals created by the Cerebro get no operation after 114

## Objective
Every remesas deal created with a conversation must have its `remittance_operations` row again.
Today, deals created by the Cerebro's n8n nodes have none, so their remesa never reaches the
panel, the ledger or the customer notifier.

## Problem (found 2026-09-27, right after the production cutover)
- Migration 114 dropped `trg_sync_operacion_desde_deal`. Its INSERT branch created the operation
  for every new remesas deal.
- 114 replaced that only inside `cerebro_registrar_deposito`'s new-deal branch.
- Six Cerebro nodes still `INSERT INTO deals` without creating an operation:
  - Registrar beneficiario auto
  - Registrar zelle auto
  - gestionar_beneficiario
  - registrar_beneficiario_zelle
  - registrar_reparto_multiple
  - marcar_destino_usd
- What that does to the business:
  - A customer who gives the beneficiary before depositing gets a deal with no operation. That is
    ~11 deals/week, ~13%.
  - The deposit is then attached to that deal by the "movido" branch. Its
    `UPDATE remittance_operations` touches 0 rows.
- Evidence: production deal 053d2936 (test chat, 2026-09-27 15:56 Guyana) has 0 operations.
- Checked and NOT affected: "Cierre automatico de solicitudes zombis" updates `deals.status`, which
  the old bridge never reacted to.

## Scope
- Migration `125_deal_insert_creates_operation.sql`:
  - A narrow AFTER INSERT trigger on deals that restores the old bridge's INSERT branch verbatim:
    - the operation row, with status from the stage;
    - then `cerebro_sync_beneficiarios`.
  - Its name sorts before `trg_sync_z_benef_desde_deal`, the same position the old bridge had.
  - `cerebro_registrar_deposito` (114 body, one line changed): the creado INSERT becomes
    `ON CONFLICT … DO UPDATE SET service_type` so a recarga stays classified. Now the trigger
    creates the row first.
  - Backfill: operations for remesas deals created since 114 that have none.
- Assertion `supabase/staging/assertions/deal-insert-creates-operation.sql` (BEGIN … ROLLBACK).
- Rollback file.

## Out of scope
- The Cerebro beneficiary-capture improvements. That is the investigation which found this.

## Constraints
- Never delete data. Additive migration only.
- Same path as the cutover: rehearsal DB `wacrm-ensayo` → staging → production.
- TDD: Strict TDD enabled (user global config). Runner for SQL is the assertion file (RED before
  125, GREEN after).

## Tasks
- [ ] F1 — Assertion RED on `wacrm-ensayo`.
- [ ] F2 — Migration 125 + rollback, GREEN on `wacrm-ensayo`.
- [ ] F3 — Apply to staging, assertion GREEN there.
- [ ] F4 — Apply to production + backfill, verify (the test deal gets its operation, then that
  test operation is cancelled as admin).

## Acceptance criteria
- A remesas deal inserted with a conversation gets exactly one operation, and its notes'
  beneficiary is attached.
- Beneficiary-first then deposit: the deposit lands on that operation (amount and status set).
- A recarga detected by `cerebro_registrar_deposito` is still `service_type = 'recarga'`.
- A deal outside the remesas pipeline, or without a conversation, gets no operation.

## Progress
- 2026-09-27: document created.
