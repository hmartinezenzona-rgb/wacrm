# Production cutover — Sunday 2026-09-27

Everything built so far on `feat/port-chat-operations-calculator` must be live in production
on Sunday. The business is closed on Sundays; Monday 2026-09-28 starts on the new system.
Who executes: the user (production writes are human-run), the assistant prepares and checks.

## State of production (verified read-only 2026-09-26)

Already live:
- Migration 119/120 (aged operations RPC) — applied 2026-09-24.
- Migration 122 (promo validity by Guyana day) — applied 2026-09-26.
- ETECSA monitor filter fix (n8n `vk6aEa4bOZtl5xSz`, version ca7d5557…) — applied 2026-09-26.

Missing (none of these objects exist in production yet):
- Migrations 095–118 (calculator ledger, operations panel RPCs, deposit review, delivery,
  rates, ledger feed, retire of the sync pipeline 114, dashboard RPCs 116–118).
- Migration 121 (financial close on /resumen).
- The application code of this branch (production still runs the old build).
- The repointed customer notifier (n8n `wGud0KGR6eMqqfMQ`).

Note: production's `supabase_migrations` also holds the Cerebro series (`102_pausa_humana_caduca`,
`108_reintento_avisado`, …). Same numbers, different migrations — check by object, not by name.

## Checklist, in order

1. [ ] Pre-checks (read-only, production SQL editor):
   `supabase/staging/check-production-clean.sql`, `supabase/staging/check-shared-fingerprint.sql`.
   Stop if anything FAILs.
2. [ ] Backup of the production database before any write. Supabase Free plan: NO automatic
   backups and no point-in-time recovery (Supabase docs recommend exporting yourself).
   `bash supabase/cutover/respaldar-base.sh produccion` → `~/wacrm-respaldos/produccion-<UTC>.dump`
   (pg_dump 17 in the postgres:17 image, schemas public/auth/storage, custom format) + .list +
   .sha256. Needs `~/.config/wacrm/prod-db.env` with `PROD_DATABASE_URL=` (session pooler URI,
   created by the user; the script refuses a URL of the other project). Tested 2026-09-26 on
   staging: 101 tables with data, 187 functions; test-restore into an empty Postgres 17 gave
   identical counts (messages 23, conversations 1, operations 4, auth.users 2); only errors were
   `ai_knowledge_chunks` needing pgvector (present on Supabase) and "schema public exists".
   Take one on Saturday as well, so there are two.
   - 2026-09-26 (user OK): production read-only backup user `respaldo_lectura` (LOGIN, INHERIT,
     BYPASSRLS, member of pg_read_all_data, default_transaction_read_only=on, connection limit 3;
     only a SCRAM verifier was sent; password generated locally, lives only in
     `~/.config/wacrm/prod-db.env`, host aws-0-us-east-1.pooler.supabase.com). Chosen instead of
     resetting the `postgres` password, which n8n uses (Cerebro, notifier, vigilantes, outbox).
     Verified: reads (15,633 messages, 562 operations, 6 users), writes refused.
     Remove with `DROP ROLE respaldo_lectura;`.
   - SATURDAY BACKUP TAKEN: `~/wacrm-respaldos/produccion-20260926T162600Z.dump` (5.8 MB, 96
     tables with data, 133 functions). Test restore: messages 15,633, operations 562, users 6 —
     identical to production. Take the Sunday one right before step 3.
3. [ ] Legacy open operations — DECIDED (user, 2026-09-26): start from zero, not carried over.
   Must run BEFORE migrations 095+ (at the latest before 104, the ledger feed).
   - 3a `supabase/cutover/2026-09-27-01-revisar-operaciones-legado.sql` (read-only): totals and the
     ones touched in the last 48 h. On 2026-09-26: 98 open (55 ready_to_transfer → completed,
     43 others → cancelled), 10 touched in the last 48 h — review those with the team.
   - 3b `supabase/cutover/2026-09-27-02-cerrar-operaciones-legado.sql` (write): put live
     customers' ids in `v_keep`, run once. Deals are not touched (they carry notification
     triggers). Keeps a record in `cutover_legacy_ops_2026_09_27`; refuses if 104 is applied;
     aborts if any row does not reach its new status. Tested on staging (rolled back): completed,
     cancelled and kept cases correct; the 104 guard refuses.
   - CHANGED (user, 2026-09-27): NOT from zero. Many legacy open operations are still to be
     done, so they STAY OPEN and move to the new panel. Only the ones the user confirms, one by
     one, as already done in the chat are closed, without any customer message:
     before the migrations → `status = 'completed'` on remittance_operations only (deals are not
     touched: their stage trigger notifies customers; ops only have the timestamp trigger);
     ALSO move the deal, because the legacy CRM shows DEALS ("Lista para transferir"): in ONE DO
     block, `ALTER TABLE deals DISABLE TRIGGER deals_stage_notify` → `UPDATE deals SET stage_id =
     Entregada (1b36b34c…)` guarded by id + stage + status (the remaining triggers mark it won,
     stamp entregado_en and keep the op completed) → `ENABLE TRIGGER` → RAISE if the
     net.http_request_queue count changed or if the row count is not 1. The MCP role (postgres,
     table owner) CAN do this; it CANNOT `SET session_replication_role` in production (42501).
     After the cutover (114 applied) → same pattern on remittance_operations: disable
     `trg_notify_operation_status_change` and `zzz_remittance_operations_calculator_feed`, set
     completed, re-enable, check the queue (and that no ledger row was added). Always completed
     (user, 2026-09-27), never cancelled. Step 3b is NOT run.
   - Manual closes log:
     - 2026-09-27 07:54 GY — `feecb06d-4e08-4503-9b48-f3e6561dc162`, Carlos +5926731279,
       6,200 GYD (a recarga, recorded as remesa), ready_to_transfer → completed; its deal
       4a0a5a0a… moved silently to Entregada/won at 08:01 GY (pg_net queue unchanged).
     - 2026-09-27 08:06 GY — `602282f3-7286-435e-90b4-397bca4d526d`, Carlos +5926731279,
       55,000 GYD, deposit_verification → completed; deal c3cb8ec8… Por verificar → Entregada/won
       (done in the chat by an admin; pg_net queue unchanged).
     - 2026-09-27 ~08:15 GY — Yilian Barbara Hernandez +5926595697, 4 ops ready_to_transfer →
       completed, deals Lista para transferir → Entregada/won (26,000 · 80,600 · 26,000 · 56,000
       GYD; ops 8d73bd48…, 751eeeb1…, fab2bd87…, 824ae732…). No other open ops; queue unchanged.
     - Same client: recarga 6,200 GYD d50d7fc7… was ALREADY completed/Entregada since 2026-09-22.
     - 2026-09-27 — Yusmila +5927212465, recarga 6,200 GYD (op 77369f06…) → completed, deal
       f2ceac94… → Entregada/won; queue unchanged. KEPT OPEN (not done yet): recarga 15,500 GYD
       (op 12510beb…).
4. [ ] Migrations 095 → 118 in numeric order, one file at a time, checking each ends without
   error. Do NOT re-run 119 (superseded by 120, already live).
   - 109: verified 2026-09-26 — the 7 production functions are byte-identical (md5 of
     pg_get_functiondef) to 109's bodies: a true no-op. Apply.
   - 110: builds on those same bodies (adds the remittance_operations dual-write). Apply.
   - 114: FIXED 2026-09-26. As first written, its `cerebro_registrar_deposito` creado path
     raised `column reference "deal_id" is ambiguous` on EVERY new receipt (found by a live
     staging smoke). The file now carries `#variable_conflict use_column`. Apply the file from
     the final commit, never an older copy. Right after applying it, run
     `supabase/staging/assertions/registrar-deposito-creado.sql` against STAGING (BEGIN …
     ROLLBACK) for reference, and in production check that
     `pg_get_functiondef('public.cerebro_registrar_deposito(uuid,numeric,text,uuid,text,text)'::regprocedure)`
     contains `#variable_conflict use_column`.
   - 112: SKIP in production. Its tables already exist with the same columns and RLS; its only
     effective statement would be `GRANT ALL ... TO anon, authenticated`, which production
     does not have today (hardened by 064). Skipping loses nothing.
5. [ ] Right after 114: repoint the customer notifier —
   `~/cerebro-fase1/PASOS-notificador-produccion-114.md` (pre-check SQL, `n8n.py put`, verify).
   Between 114 and this step no customer notification is sent.
6. [ ] Migration 121 (`crm_cierre_financiero`, financial close on /resumen).
7. [ ] Deploy the application code of `feat/port-chat-operations-calculator` to production with
   production's own tooling (brought into this branch, commit 6343014; self-test passes):
   ```bash
   export PATH=~/.local/node-v20.20.2-linux-x64/bin:$PATH        # Node 20 = the servers' version
   cd ~/wacrm-worktrees/mejora-legacy && git status --short        # must be empty
   WACRM_BUILD_ENV=$PWD/infra/deployment/wacrm.produccion.build.env bash infra/deployment/build-wacrm.sh
   bash infra/deployment/desplegar-wacrm-produccion.sh <sha printed by the build>
   # rollback: bash infra/deployment/rollback-wacrm-produccion.sh
   ```
   - `infra/deployment/wacrm.produccion.build.env` exists locally (git-ignored): production's
     NEXT_PUBLIC_* + WACRM_ENVIRONMENT=production.
   - The deploy script checks artifact sha256, environment and Supabase project ref, uploads to a
     `.parcial` dir, links `.env.local -> /home/ubuntu/wacrm.env`, switches `current`, restarts
     pm2 `wacrm`, smoke-tests and rolls back by itself on failure.
   - REHEARSED 2026-09-26 (build only, nothing deployed): Node 20.20.2, money-path tests 101/101,
     manifest environment=production, project hqztotshnlzaiziwjyzh, bundle 32 prod refs / 0
     staging refs, no .env inside. Rebuild on Sunday from the final commit.
   - Confirmed on `oracle`: pm2 `wacrm` serves `/home/ubuntu/wacrm-releases/current` (SHA dirs,
     `anterior` link); `/home/ubuntu/wacrm-deploy` is unused; prod currently serves `83422d9`
     (not an ancestor of this branch; file-by-file review done, see 6b).
6b. [x] Before building: port what production has and this branch lacks:
   - `messages.sender_id` on agent sends (production records it on 611/611 human messages in
     the last 7 days; this branch would stop): `senderId` in `send-message.ts` + `route.ts`.
     DONE 2026-09-26, commit `73c4841` (TDD: route test RED → GREEN), deployed to staging.
   - Minor, optional: `ai_generated` in `/api/v1` conversations (n8n does not use it — the
     Cerebro reads it from the DB), inbox "undo" after hiding chats, pin rail alignment.
7b. [ ] Enable the operations panel: `supabase/cutover/2026-09-27-03-activar-panel-operaciones.sql`.
   Gated per user by `profiles.beta_features` containing `operations_panel`; production's 5
   profiles all have it empty. Idempotent; tested on staging (rolled back). Per-user off switch
   in the file's comment.
8. [ ] Smoke test on production: login, inbox + operations panel, /resumen (financial close,
   history with Destino column), /dashboard (no money widgets, no quick actions), /calculadora.

## What arrives with the code deploy (step 7)
- Operations panel (receipts, verify/force, complete transfer), History collapsed to "History (N)".
- /resumen financial close (day/week/month/range by Guyana day, per service, per day, detail,
  voided/pending apart, CSV) + history "Destino" column.
- /dashboard without the money widgets duplicated by /resumen and without quick actions.

## Monday 2026-09-28 checks
- First manual deposit verification and first completion → customer notifier executions reach
  "Enviar por WaCRM" (template `remesa_completada` with what the client receives).
- The ledger starts at zero by design: /resumen and the calculator show only operations
  completed from the feed onward.
- ETECSA monitor: new promos land as `detectada` and the CRM asks for confirmation.

## Related documents
- `odd/tasks/notify-workflow-repoint-114.md`, `odd/tasks/financial-close-resumen.md`,
  `odd/tasks/etecsa-monitor-detection.md`.
- `~/cerebro-fase1/PASOS-notificador-produccion-114.md`, `~/cerebro-fase1/PASOS-vigilante-etecsa-deteccion.md`
  (local only, by the user's choice).

## After the cutover (decided by the user 2026-09-26)
- Cerebro observability T1–T3 (silence reason, token collector, G3 scoped to USD) to production:
  `~/cerebro-fase1/PASOS-cerebro-observabilidad-produccion.md`. Candidates built and benched
  (16/16, 7/7); production snapshot taken; production DB function and columns verified.

## Deferred (not for Sunday)
Calculator manual lines into the ledger, period lock and expenses, Zelle/Clásica type in the
history, caption on the delivery proof, moving account numbers out of the agent prompt,
Cerebro flow review.
