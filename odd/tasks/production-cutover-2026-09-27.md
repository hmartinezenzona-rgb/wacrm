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
   error. Do NOT re-run 119 (superseded by 120, already live). Review 109/110/112 (capture /
   n8n repoint) against production before running them.
5. [ ] Right after 114: repoint the customer notifier —
   `~/cerebro-fase1/PASOS-notificador-produccion-114.md` (pre-check SQL, `n8n.py put`, verify).
   Between 114 and this step no customer notification is sent.
6. [ ] Migration 121 (`crm_cierre_financiero`, financial close on /resumen).
7. [ ] Deploy the application code of `feat/port-chat-operations-calculator` (commit a558403 or
   later) to production. First confirm the real deploy path: production serves
   `/home/ubuntu/wacrm-releases/current` (pm2 `wacrm`, SSH `oracle`), not the
   `/home/ubuntu/wacrm-deploy` of `.github/workflows/deploy.yml`. Build with production
   `NEXT_PUBLIC_*` values; verify the bundle points to `hqztotshnlzaiziwjyzh`, never staging.
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
