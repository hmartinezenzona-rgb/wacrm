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
2. [ ] Backup of the production database before any write.
3. [ ] DECISION (user): the ~93 legacy open operations (54 ready_to_transfer, 17
   deposit_verification, 11 incident, 11 collecting_information as of 2026-09-25). Close them
   before or after the ledger feed (104) exists — before keeps them out of the ledger, after
   puts them all in the ledger on Sunday. "Start the week clean" implies closing them.
4. [ ] Migrations 095 → 118 in numeric order, one file at a time, checking each ends without
   error. Do NOT re-run 119 (superseded by 120, already live).
   - 109: verified 2026-09-26 — the 7 production functions are byte-identical (md5 of
     pg_get_functiondef) to 109's bodies: a true no-op. Apply.
   - 110: builds on those same bodies (adds the remittance_operations dual-write). Apply.
   - 112: SKIP in production. Its tables already exist with the same columns and RLS; its only
     effective statement would be `GRANT ALL ... TO anon, authenticated`, which production
     does not have today (hardened by 064). Skipping loses nothing.
5. [ ] Right after 114: repoint the customer notifier —
   `~/cerebro-fase1/PASOS-notificador-produccion-114.md` (pre-check SQL, `n8n.py put`, verify).
   Between 114 and this step no customer notification is sent.
6. [ ] Migration 121 (`crm_cierre_financiero`, financial close on /resumen).
7. [ ] Deploy the application code of `feat/port-chat-operations-calculator` to production.
   Deploy path CONFIRMED 2026-09-26 (read-only on `oracle`):
   - pm2 app `wacrm` runs `/home/ubuntu/wacrm-releases/current/server.js`; `current` and
     `anterior` are symlinks to release dirs named by commit SHA (same model as staging).
     `/home/ubuntu/wacrm-deploy` is an old, unused directory.
   - Runtime env: each release has `.env.local -> /home/ubuntu/wacrm.env` (no pm2 env, no
     /etc file). A new release MUST get that same symlink or the server starts without keys.
   - Build with `NEXT_PUBLIC_*` from `/home/ubuntu/wacrm.env` (SUPABASE_URL points to
     hqztotshnlzaiziwjyzh); verify the bundle has no staging ref.
   - Production's own deploy scripts (`infra/deployment/desplegar-wacrm-produccion.sh`,
     `rollback-wacrm-produccion.sh`, `build-wacrm.sh`, `lib-*.sh`) live on branch
     `ui/operations-visibility-v2`, not on this branch.
   - Production currently serves `83422d9` (2026-09-06, branch `ui/operations-visibility-v2`),
     which is NOT an ancestor of this branch. File-by-file review: everything it adds is either
     already ported here (ownership icon, bot pause on agent send, inbox selection/pin, header),
     intentionally retired (pipelines board, deal cards, quick actions), or non-code
     (screenshots, reports, dev pages) — EXCEPT the items in step 6b.
6b. [x] Before building: port what production has and this branch lacks:
   - `messages.sender_id` on agent sends (production records it on 611/611 human messages in
     the last 7 days; this branch would stop): `senderId` in `send-message.ts` + `route.ts`.
     DONE 2026-09-26, commit `73c4841` (TDD: route test RED → GREEN), deployed to staging.
   - Minor, optional: `ai_generated` in `/api/v1` conversations (n8n does not use it — the
     Cerebro reads it from the DB), inbox "undo" after hiding chats, pin rail alignment.
7b. [ ] Enable the operations panel: it is gated by `profiles.beta_features` containing
   `operations_panel` (production has 5 profiles). Without it nobody sees the panel.
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

## Deferred (not for Sunday)
Calculator manual lines into the ledger, period lock and expenses, Zelle/Clásica type in the
history, caption on the delivery proof, moving account numbers out of the agent prompt,
Cerebro flow review.
