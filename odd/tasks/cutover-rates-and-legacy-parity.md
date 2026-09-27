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
- [x] R1 — rates seed script + guards.
- [x] R2 — legacy parity backfill script + undo log.
- [x] R3 — full rehearsal on a local restore of a fresh production backup; report counts and
  sample panel output.
- [ ] R4 — cutover plan updated, pushed to GitHub.

## Progress
- 2026-09-27: document created; rates confirmed by the user; branch pushed to `privado` (6367021).
- 2026-09-27: R1/R2/R3 done, rehearsed end-to-end on a LOCAL Docker restore of
  `~/wacrm-respaldos/produccion-20260927T173432Z.dump` (never staging/production). Local DB:
  official `public.ecr.aws/supabase/postgres:17.6.1.167` image (matches production's Postgres 17,
  full Supabase role/schema bootstrap). The image's built-in `auth`/`storage` schemas are a
  different GoTrue/Storage revision than production's — restoring on top produced cascading
  "column does not exist" errors; fixed by `DROP SCHEMA auth/storage/public CASCADE` (their
  extensions live in the separate `extensions` schema, untouched) before `pg_restore`. One real
  gap: `ai_knowledge_chunks` needs `pgvector`, not installed by default — `CREATE EXTENSION vector`
  then a second `pg_restore` pass picked it up cleanly (13 relations + the `vector` type were the
  only real errors; everything else across two passes was cosmetic "already exists"). `pg_net`
  installed too, to assert `net.http_request_queue` stays untouched.
  - R1 (`2026-09-27-04-tasas-calculadora.sql`): RED confirmed — after 113 without the seed,
    `SELECT * FROM tasas` returns 0 rows (proven in a rolled-back transaction). Applied between 103
    and 113: seeds `calculator_rate_versions` for account `465fb4ce-…` (usdt_sell_gyd 260,
    cup_global_rate 3, usdt_buy_gyd 240, usdt_sell_cup 975, set_by NULL). GREEN confirmed —
    post-113 `SELECT * FROM tasas` returns exactly usd 260 / gyd 3. Second run correctly refuses
    ("already has a calculator rate version").
  - Migrations 095→118 (skip 112, verified its 3 tables already exist with the same shape in the
    restored production data), 121, 123: ALL applied cleanly on real production data, zero errors.
    119/120/122 confirmed already live by object (120's function shape, 122's Guyana-day logic
    present). 114's `#variable_conflict use_column` fix confirmed present via
    `pg_get_functiondef`. `crm_agregar_beneficiario(uuid,jsonb)` (123) confirmed present.
  - R2 (`2026-09-27-06-relleno-remesas-legado.sql`): RED — 377 non-cancelled remesas missing
    `quoted_destination_amount` before. GREEN — 228 filled (single beneficiary or zero-beneficiary
    with a known delivery_method, USD via zelle/clasica/tropical floor(source/rate), CUP via
    cuban_card round(source*rate), historical rate from `tasas_historico` by Guyana day), 149
    correctly left NULL and listed (145 no beneficiary + no delivery_method, 2 with 0 source
    amount, 2 with an unmapped delivery_method). `cerebro_sync_beneficiarios` step affected 0
    operations on this dump (the ~1-case estimate predates today's manual op closures). Second run
    inserted 0 new log rows and changed 0 additional operations — idempotence proven.
    `remittance_calculator_entries` and `net.http_request_queue` row counts asserted unchanged
    (0 → 0 both times; the script's own guard would have raised otherwise). `admin_locked_fields`
    is set on touched fields as a side effect of running as `wacrm.origin='admin'` (096) — intended,
    documented in the file's header.
  - Panel RPC (`crm_operaciones_de_conversacion`, called as an authenticated member via
    `request.jwt.claims`) verified for 3 legacy conversations: one completed CUP remesa (10,000 GYD
    → 30,000 CUP), one completed Zelle remesa (26,000 GYD → 100 USD), and one of the still-open
    ones (`unica` resolver result, `ready_to_transfer`, 13,000 GYD → 50 USD, beneficiary amount
    also 50 — set earlier by 100's own live trigger since the op was already open). All render an
    amount instead of "amount missing".
  - Row counts of messages (15,853), conversations (216), contacts (218), deals (404),
    remittance_operations (569), remittance_beneficiaries (411) and depositos_mmg (1,398) are
    IDENTICAL before vs after the entire chain (only the new `cutover_legacy_backfill_2026_09_27`
    table and the one `calculator_rate_versions` row are new) — no row deleted or spuriously
    created anywhere.
  - `check-production-clean.sql` run against the restore: ALL PASS. `check-shared-fingerprint.sql`
    ran to completion (373 objects fingerprinted; it is a compare-against-a-baseline tool, not
    pass/fail on its own — no baseline to diff against here).
  - No migration failed on real production data anywhere in the chain — the most important finding
    of this rehearsal is a negative one: the whole 095→123 chain (with R1 inserted before 113)
    applies cleanly, in order, on today's actual production data.
  - `wacrm-ensayo` container left running for inspection:
    `docker exec -it wacrm-ensayo psql -U supabase_admin -d postgres` (password `ensayo`,
    port 127.0.0.1:55432). `supabase/cutover/ensayar-cutover.sh` reproduces the whole rehearsal
    from a fresh dump.
