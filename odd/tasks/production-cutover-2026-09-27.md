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
     - 2026-09-27 — Josefa +5926176300: one 25,400 GYD deposit (Ref MMG 10401353010941,
       2026-09-23) was really Zelle 50 USD + 2 recargas × 6,200. SPLIT (silently: deals_insert_notify
       and deals_stage_notify disabled inside the DO block, queue unchanged): deal 2cd9a053… / op
       487564e6… → "Remesa Zelle +5926176300", 13,000 GYD, USD 50 (keeps the receipt and the
       THETANDEM TEAM LLC beneficiary); new deals dbe7a7e8… and 650f6a87… "Recarga (1|2 de 2)",
       6,200 each, their ops created by the bridge and set to recarga. Sum checked = 25,400. All
       three then completed silently (ops completed, deals Entregada/won; queue unchanged). No
       other open ops for this client.
     - 2026-09-27 — Yaquelin +5927414004, remesa 13,000 GYD (op 2a4fde65…) → completed, deal
       c94018b2… → Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Yohandi +5926132064, remesa 5,000 GYD (op b4a75197…) → completed, deal
       fb96a1c8… → Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Jose +5926328415, remesa 68,400 GYD (op a8fcb7f2…) → completed, deal
       e6a236c1… → Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Kirenia +5927511485, remesa 5,000 GYD (op 7afa23fc…) → completed, deal
       e64b1b2b… → Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Norma +5926800266, 2 remesas: 14,300 GYD (op 0f476cb9…, deal 7c9d1671…) and
       27,560 GYD (op 6b19e3eb…, deal 1aae3065…) → completed, Entregada/won; queue unchanged. No
       other open ops.
     - 2026-09-27 — Juan Carlos Marrero +5927657827: remesa Zelle 26,000 GYD (op 3f0fec82…, deal
       80fe201c…, deposit verified with MMG) → completed, Entregada/won; and 39,000 GYD (op
       dc2d7139…, deal d08598ef…, was "Por verificar", deposit not crossed with MMG) → completed,
       Entregada/won after the user's rule below; queue unchanged. No other open ops.
     - RULE (user, 2026-09-27): whatever the user pastes here was already done and checked
       visually by the user in the chat, so it is completed REGARDLESS of its current status.
       Do not ask about the status again.
     - 2026-09-27 — zuleika7610 +5927221885, 4 ops of 2026-09-21: remesa 12,400 (35176e5d…) and
       recargas 6,200 (088429f1…), 12,400 (184f4627…) — all three "Por verificar" — plus recarga
       12,520 (9769c783…, Lista para transferir) → completed, Entregada/won; queue unchanged. No
       other open ops.
     - 2026-09-27 — Frexi +5927567438, 3 remesas: 15,000 (6f15978b…), 20,000 (cd5266d4…),
       100,000 GYD (254415ab…) → completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Rubislandi +5926338345: remesa 28,600 (dab0ad10…), recarga 14,400 (e6f4bc83…),
       remesa 10,000 GYD (58cab916…) → completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Michel Pérez +5926538679, remesa 52,000 GYD (op 969a7627…, deal 42aab435…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Suleidy +5927030476, remesa 24,700 GYD (op f8a0441d…, deal 677033ce…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Onelsi Suriel Gamboa +5927570987, remesa 13,000 GYD (op 5ff8d00c…, deal
       bc21b770…) → completed, Entregada/won; queue unchanged. Leftover op 712d5b2d…
       (collecting_information, 0 GYD, 2026-09-12, deal d4ecb01c… already LOST) → CANCELLED on the
       user's OK (op only; the deal was left lost); queue unchanged.
     - 2026-09-27 — bladimir +5926095231, 3 remesas: 15,000 (20d3a23b…), 5,000 (c28a1618…),
       15,000 GYD (5f89d983…) → completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Idalmis +5927641874, remesa 13,000 GYD (op 7844b27d…, deal 7e143741…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Luis Enrique +5927661903: remesa 52,000 GYD (op 4433d370…, deal 35b635b7…) →
       completed, Entregada/won. DUPLICATE verified: the "Incidencia" 15,000 (op 0c8b2e2e…, deal
       71c62953…, 2026-09-26 18:22) carries the SAME MMG Ref 20401623619989 as the open 15,000
       (op d034cc51…, deal 27b05adb…, 17:37, verified) — the bot itself flagged "TransID ya fue
       usado". Duplicate deal → lost (stage kept, note added; NOT deleted, since deleting a deal
       frees its deposits), op → cancelled; deals_stage_notify and trg_notify_deal_incidencia
       disabled only inside the block; queue unchanged. KEPT OPEN: the verified 15,000.
       Then, on the user's request ("solo ensucia"), the duplicate op and deal were DELETED (op
       first, 0 beneficiaries; the deal had no deposit attached, and the MMG deposit stays attached
       to the good deal 27b05adb…, checked inside the block; queue unchanged). Row backup:
       `~/cerebro-fase1/BORRADO-duplicado-luis-enrique-2026-09-27.json`.
     - 2026-09-27 — Katia +5926432832, 2 remesas: 120,000 (97bdadb3…) and 52,000 GYD (91a605f9…)
       → completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Eliandro +5927604004, remesa 41,600 GYD (op b0f3237c…, deal 96608ff3…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — zulemysd +5926412028, 2 remesas of 5,000 GYD — NOT duplicates (different MMG
       refs 20400924714357 / 20400995214519, 18-sep and 19-sep, both verified): ops 27ece136…,
       0cd781ce… → completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Nesty +5926047103, remesa 26,000 GYD (op 5c10a23d…, deal d2e27791…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Wander +5926669732, remesa 52,000 GYD (op 38885a02…, deal e7138fc0…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — "Osmany Services" +5926762167 (the business's own MMG agent number; admin test
       sends, per the user): 114,000 (c7c8d5cc…, Lista), 5,000 (fc30e135…, Por verificar), 5,000
       GYD (f254d0ea…, Por verificar) → completed, Entregada/won; queue unchanged. No other open ops.
       MMG email check: the 114,000 (Ref 10400751412195) IS in depositos_mmg and attached to its
       deal. The two 5,000 (Refs 20400749845117, 20401268979551) are NOT in the MMG emails, neither
       exact nor any nearby 5,000 email. The user decided to leave them completed anyway.
     - 2026-09-27 — Suset +5926142690, remesa 5,000 GYD (op a1b31bd5…, deal 5f330d08…) →
       completed, Entregada/won; queue unchanged. No other open ops.
     - 2026-09-27 — Yuni +5926508036, remesa 5,000 GYD (op 18308748…, deal 5fdaa71e…) →
       completed, Entregada/won; queue unchanged. No other open ops.
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
