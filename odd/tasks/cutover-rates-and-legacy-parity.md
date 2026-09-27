# Cutover prep: calculator rates seed + legacy parity backfill + full rehearsal

## Objective
Get production ready so that, right after the cutover, (1) the bot still quotes rates and (2) the
legacy remesas (completed and open) render in the new operations panel like panel-made ones —
proven first on a local restore of a fresh production backup, never on production itself.

## Why (user, 2026-09-27)
- Migration 113 turns `tasas` into a view over `calculator_rate_versions`, which 095/103 create
  EMPTY in production → without a seed the bot has no rate. User confirmed the rates:
  usdt_sell_gyd 260, cup_global_rate 3, usdt_buy_gyd 240, usdt_sell_cup 975.
- Legacy rows lack structured fields the panel reads: of 398 completed only 5 have
  `quoted_destination_amount`; 0 of the 5 open ones. The panel then shows "amount missing".
  The user approved filling ONLY empty structured fields, never overwriting or deleting.
- Everything must be in GitHub (`privado` remote) so the cutover deploys a complete branch.

## Scope
- R1 `supabase/cutover/2026-09-27-04-tasas-calculadora.sql`: after 103, before 113. Inserts ONE
  `calculator_rate_versions` row for the business account `465fb4ce-33b6-4473-ad2c-42818772f587`
  (`crm_set_calculator_rates` needs an admin session, unusable from the SQL editor). Guards: refuse
  if the table is missing or already has a version for that account; verify with
  `calculator_rates_vigentes`. Post-113 check: `SELECT * FROM tasas` returns usd 260 and gyd 3.
- R2 `supabase/cutover/2026-09-27-06-relleno-remesas-legado.sql`: after all migrations (123
  included). Fills, only where NULL, on legacy `remittance_operations` (service_type 'remesa'):
  `destination_currency`, `quoted_destination_amount` (source amount × the rate in force on the
  operation's date, from `tasas_historico`/the 113 archive: usd 260 since 2026-08-06; gyd 3 since
  08-10, 2.8 since 08-05, 2 since 07-11; rounding: CUP = round, USD = floor, as the business rule),
  `delivery_method` from the beneficiary type; and beneficiaries from deal notes via the existing
  `cerebro_sync_beneficiarios` where notes have them and rows are missing (~1 case). Currency rule
  per op: from beneficiary type / delivery_method / notes (Zelle, Clásica, Tropical → USD;
  cuban_card → CUP); undecidable rows are LEFT EMPTY and listed, never guessed. Every change logged
  in a new table `cutover_legacy_backfill_2026_09_27` (op id, field, old, new) for undo; triggers
  that notify or feed the ledger must NOT fire.
- R3 Full rehearsal on a LOCAL Postgres 17 restore of a fresh production dump: pre-checks → 095…103
  → R1 → 104…118 (skip 112) → 121 → 123 → R2 → checks (tasas view, 114 fix present, panel RPC
  `crm_operaciones_de_conversacion` output for a few legacy conversations, counts before/after,
  no rows deleted in messages/conversations/contacts/deals/remittance_operations).
- R4 Update the cutover plan with R1/R2 in place, push to `privado`.

## Out of scope
- Production writes (the cutover itself is a separate, user-run step).
- Cerebro beneficiary-capture improvement (after the cutover).

## Constraints
- Production untouched. The fresh dump is taken with the read-only user `respaldo_lectura`
  (`bash supabase/cutover/respaldar-base.sh produccion`).
- Never delete data; the rehearsal proves it by counts.
- TDD: SQL behavior proven by RED/GREEN in the rehearsal (checks fail before R1/R2, pass after).

## Tasks
- [ ] R1 — rates seed script + guards.
- [ ] R2 — legacy parity backfill script + undo log.
- [ ] R3 — full rehearsal on a local restore of a fresh production backup; report counts and
  sample panel output.
- [ ] R4 — cutover plan updated, pushed to GitHub.

## Progress
- 2026-09-27: document created; rates confirmed by the user; branch pushed to `privado` (6367021).
