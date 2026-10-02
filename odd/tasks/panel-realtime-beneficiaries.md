# Panel realtime refreshes on bot beneficiary writes

Objective: the operations panel (and the coming board) refresh live when the bot saves a card, a phone or a
partial beneficiary, not only when the operation row itself changes.

Problem (found 2026-10-02 while checking the production app update): `3b5f5dc` (eliminate-deals WU8) moved
the panel subscription from `deals` to `remittance_operations`. Bot beneficiary writes never UPDATE the operation
row: staging `cerebro_escribir_bloque_beneficiario` / `cerebro_sync_beneficiarios` do not touch it; production's
`cerebro_sync_benef_trigger` and `crm_calcular_monto_destino` update it only when delivery_method or the computed
amount change. So the panel shows a bot-saved beneficiary only after a reload. Live on staging since the
2026-10-02 deploy of `e3fff52`; it blocks the production app update. WU8's E2E only proved a direct operation
UPDATE. Engram: `eliminate-deals/wu8-beneficiary-realtime-gap`.

Fix: migration 186, AFTER INSERT/UPDATE/DELETE row trigger on `remittance_beneficiaries` that touches the parent
operation (`UPDATE remittance_operations SET updated_at = now()`), SECURITY DEFINER, never blocks the beneficiary
write. Checked: on an updated_at-only UPDATE the operation triggers stay inert (status/recalc/calculator/destino
triggers are `UPDATE OF <column>`; the lock guard only acts on changed fields); `cerebro_op_touch` bumps
`version` as on any write.

Scope: staging only (production with the owner's go-ahead, together with 181 and the app deploy).
TDD: on (user global config). Runner: self-reverting SQL assertion on staging (`DO` ending in
`RAISE EXCEPTION 'ALL PASS'`), measured with `pg_stat_xact_user_tables.n_tup_upd`; plus a real Realtime
subscription probe (throwaway user, deleted after).

## Tasks
- [x] T1 Assertion `supabase/staging/assertions/beneficiary-touches-operation.sql`, RED on staging
- [x] T2 Migration 186 + rollback, GREEN in a rolled-back transaction, apply to staging, regressions
- [x] T3 Realtime probe: a subscriber with the panel's exact descriptor receives an event when the bot writes a
      beneficiary (negative control without 186)

## Acceptance
- A bot beneficiary write (card, phone, reparto slot) emits an UPDATE on its operation; nothing else changes on
  the operation (status, amounts, locks, audit, notifications).
- partial-beneficiary-tools, partial-beneficiary-auto, reparto-guards, deal-free-money-rules, operations-realtime
  still pass.

## Progress / evidence
- T1 (2026-10-02): `beneficiary-touches-operation.sql` (4 cases: bot phone on a saved card, nothing else changes on
  the operation / no audit / no notification, reparto slot phone, human-locked operation still touched without
  audit). Witness `pg_stat_xact_user_tables.n_tup_upd` proven live first (a direct UPDATE: 0 -> 1). RED on staging:
  `case 1: a phone saved by the bot did not UPDATE its operation (0 -> 0)`.
- T2 (2026-10-02): `186_beneficiary_change_touches_operation.sql` + ROLLBACK. GREEN in a rolled-back transaction
  (ALL PASS). Baseline before applying: partial-beneficiary-tools, partial-beneficiary-auto, reparto-guards,
  deal-free-money-rules, operations-realtime ALL PASS, the new one RED. Applied to staging; after: all 6 ALL PASS.
- T3 (2026-10-02, staging): throwaway user `probe186@example.invalid` (viewer, account 472917ed; auth row with '' token
  columns + email identity) logged in with the anon key, read the probe operation under RLS (1 row) and subscribed with
  the panel's exact descriptor (`remittance_operations`, `conversation_id=eq.<conv>`): SUBSCRIBED. A: the bot saved the
  phone alone (`cerebro_guardar_beneficiario`) -> 2 UPDATE events on the operation within 15 s. B (negative control,
  trigger disabled): another phone write -> 0 events in 20 s; trigger re-enabled (tgenabled O). Cleanup:
  reset-test-contact.sql for the probe phone (1 contact, 1 conversation, 1 operation), auth user/identity/profile
  deleted; residue 0. Script: scratchpad `probe186.cjs` (not kept).

Next step: production, with the owner's go-ahead: 181 (publication) + 186, then the app `e3fff52`, then check that a
bot beneficiary write refreshes the panel.
