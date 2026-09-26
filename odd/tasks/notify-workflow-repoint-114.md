# Repoint the customer-notification n8n workflow to migration 114's payload

## Objective
Keep the customer/admin WhatsApp messages the old deals-based notifier sent,
after the cutover retires the deals pipeline (migration 114, production
cutover Sunday 2026-09-27).

## Problem
Migration 114 replaces the `deals_stage_notify` trigger with a relay on
`remittance_operations` (`{type:'UPDATE', table:'remittance_operations',
record, old_record}` on any status change). The notifier
(`[STAGING] WaCRM - Notificar cliente por etapa del deal`, n8n id
`OCdJoHTkV6S0aAdk`) still filters on deals fields (`pipeline_id`, `stage_id`),
so every status notification is silently dropped while the execution list
shows `success` (verified on execution 232153). 114's own header defers this
repoint to 11.5 ("import n8n workflow").

## Decisions (user, 2026-09-25)
- Keep the messages.
- Manual deposit verification from the panel → "depósito verificado" (with the
  missing-beneficiary-field variant). Automatic MMG-cross verification → silent
  (the bot already confirms it in its reply).
- Completed: "remesa completada" for EVERY delivery mode (`proof_sent`,
  `no_proof`, `skip_proof`). Revised 2026-09-25 after the live smoke: the proof
  image the panel sends has no text, so silence left the customer without a
  written confirmation; this matches the previous notifier. Coming from
  `incident` → silent (existing rule).
- Incident → admin WhatsApp alert (the CRM bell keeps working on its own via
  `notify_operation_incidencia`).
- `DERIVACION` / `LIMITE` / `CRUCE_APROXIMADO` branches untouched.

## Design (from read-only research)
- Manual vs automatic verification signal: a `remittance_admin_audit` row
  (`table_name='remittance_operations'`, `row_id = operation id`, `action IN
  ('human_deposit_verification','human_forced_verification')`), written in the
  same transaction as the status change; pg_net posts after commit, so n8n sees
  it. Fetched in the existing pre-filter Postgres node (`Leer secreto`) together
  with the vigente beneficiaries (`remittance_beneficiaries`, same rule as
  `crm_beneficiarios_completos`: Zelle → name + account; other → card + phone)
  and the deal notes tail (incident reason still lives in `deals.notes`).
- `Buscar telefono` keeps its "what the beneficiary receives" subquery (the
  2026-09-15 decision), joined by operation id instead of `deal_id`.
- Staging keeps sending "remesa completada" as plain text (the test account
  lacks the `remesa_completada` template) — environment wiring, NOT promoted.
  Production must use the template with `{{1}}` = what the beneficiary receives.

## Tasks
- [x] T1 — Rollback snapshot of the current staging notifier
  (`~/cerebro-fase1/ROLLBACK-notificador-staging-antes-repoint-114.json`,
  versionId `c9bc8a7e-d951-46a5-a430-1b709d3bef7b`).
- [x] T2 — Test bench `~/cerebro-fase1/pruebas/banco-notificador.js` +
  `casos-notificador-repoint-114.json` (28 cases), over the REAL downloaded
  `Filtrar` code (`actual-notificador-filtrar.js`). RED observed: 12/28 — the
  5 special-type regressions pass, all 16 new positive cases fail, the old
  deals payload is still processed.
- [x] T3 — Candidate = real head up to the unique `const rec = b.record || {};`
  marker (byte-identical, verified) + new tail
  (`cola-notificador-repoint-114.js`) → `candidato-notificador-repoint-114.js`.
  GREEN: 28/28.
- [x] T4 — SQL validated read-only on staging with a real operation
  (`f5323bbb…`: beneficiary JSON, deal notes, recibe = "225,000 CUP") plus
  empty and garbage ids (no error, empty results). Comparisons are
  `::text = $1`, never `$1::uuid`, because `Leer secreto` runs BEFORE the
  secret check and a folded cast would let garbage input raise errors.
- [x] T5 — Applied to STAGING only via `n8n.py put` from a workflow assembled
  from the rollback snapshot (no hand-retyped code). Re-downloaded: all 3
  nodes identical to the tested files; new versionId
  `7a71fd11-7677-40b4-89aa-6745b29c8729` is both draft and active. In-n8n
  smoke (execution `237604`, manual, real operation id, NO secret, fake
  conversation): `success`, `Leer secreto` ran the new SQL with n8n's
  credential, `Filtrar` cut on auth, `Enviar` never ran — zero messages.
  (`validate_workflow` is SDK-code-only; not applicable to a parameter edit.)
- [x] T5b — Regression found and fixed before the live smoke: 114's
  `cerebro_registrar_deposito` INSERTs the deal AND the operation straight
  into incident (e.g. impossible TransID, 087), so the AFTER-UPDATE relay
  never fires; the only signal is `deals_insert_notify` (NOT retired by 114).
  The first candidate dropped it → admin WhatsApp alert lost (the CRM bell
  still fires: `trg_notify_operation_incidencia` is AFTER INSERT OR UPDATE).
  Added 4 cases (RED 31/32 on the deployed candidate), restored a
  deal-INSERT-into-Incidencia admin branch, GREEN 32/32. Redeployed from a
  fresh snapshot (`ROLLBACK-notificador-staging-antes-insert-incidencia.json`,
  versionId `7a71fd11…`); live version now
  `b9b2fc45-039a-4134-83b0-817143ff83a2`, verified identical to the tested file.
- [x] T6 — Live smoke in staging via the panel, test contact only (user runs
  the panel actions; staging sends real WhatsApp).
  - 2026-09-25 progress: seeded a COMP block in both test deals' notes and
    an MMG deposit `99900000000001` (manual Verify needs a depositos_mmg match).
  - Manual verify op 08130d2e → n8n 237850, "deposito de *30,000 GYD* ya fue
    verificado" sent (WaCRM msg c26c63a0). WhatsApp status `failed`, most
    likely because the 24h window was closed (the customer sent "." 30 s later); not a notifier defect.
  - Force op 7f834cfb → n8n 237863, same template with 20,000 GYD, status `read`.
  - Complete op 08130d2e with skip_proof → n8n 237880, "su remesa de *90,000 CUP*
    ya fue completada", status `read` ({RECIBE} substituted correctly).
  - Complete op 7f834cfb with proof_sent → n8n 237919 cut at Filtrar (silence
    by design); the customer only got the captionless proof image. The user
    rejected that: decision revised (see Decisions).
  - Fix (TDD): case changed to expect "remesa completada" → RED 31/32; removed
    the proof_sent early return in cola + candidato → GREEN 32/32. Rollback
    `~/cerebro-fase1/ROLLBACK-notificador-staging-antes-proof-sent.json`
    (versionId b9b2fc45…). Live version `e0f95676-c2e9-410f-9613-a8a6acd33db0`,
    Filtrar identical to the candidate, other 4 nodes unchanged.
  - Re-test op baa28cdf (PRUEBA 3) with proof_sent → n8n 237995: image 17:11:20.4,
    text "su remesa de *75,000 CUP* ya fue completada" 17:11:22.5, both read.
    Photo and text arrive separately (2 messages, WhatsApp media latency);
    user accepted for Sunday. Follow-up after cutover: send the text as the
    proof caption from the panel instead.
  - Cleanup done 2026-09-25: 3 PRUEBA ops + 4 synthetic ops (2026-09-24),
    their beneficiaries, audit rows, 3 ledger entries (voided then deleted —
    the append-only guard only allows deleting void rows), 3 deals, MMG
    deposit 99900000000001. No status change, no notifier runs. Backup:
    `~/cerebro-fase1/BACKUP-limpieza-prueba-notificador-2026-09-25.json`.
- [x] T7 — Prepare the production version for Sunday (template path, prod
  wiring) — applied by the user during the cutover, never by the assistant.
  - Prepared 2026-09-25. Runbook `~/cerebro-fase1/PASOS-notificador-produccion-114.md`.
  - Snapshot `ROLLBACK-notificador-PRODUCCION-antes-repoint-114.json` (versionId 2433f9d5…).
  - Filtrar prod = staging candidate + one replacement (completion → template
    `remesa_completada`, params ['{RECIBE}']), generated by
    `pruebas/generar-candidato-produccion-114.py`. Bench extended with a
    `plantilla` assertion: prod cases RED 29/32 → GREEN 32/32; staging 32/32.
  - Enviar prod replaces '{RECIBE}' in template params (fallback 'hoy') and in
    text. New `pruebas/banco-enviar.js` over the real expression: current prod
    RED 3/6 → candidate GREEN 6/6.
  - Buscar telefono / Leer secreto = staging-tested SQL; prod credentials, URL
    and webhook path kept. Verified read-only: prod notify_url points to
    `wacrm-notify-etapa`, notify_secret present (legacy absent, optional).
  - ORDER: apply only AFTER migrations incl. 114 (prod has no
    remittance_admin_audit yet). Post-check: `verificar-notificador-produccion-114.py`.
  - Pending (user, Sunday): pre-check SQL, `n8n.py put`, verify.

## TDD
Strict TDD (global rule). Runner: `node` over the n8n Code-node source,
following `~/cerebro-fase1/pruebas` practice (test the real downloaded node,
never a retyped copy; rollback file before deploying).

## Acceptance criteria
- Every row of the case matrix passes; special-type branches unchanged.
- In the live smoke: manual verify → message; automatic verify → silence;
  complete without proof → "remesa completada"; complete with proof → "remesa completada";
  incident → admin alert.
- Nothing outside `OCdJoHTkV6S0aAdk` modified.

## Progress
Design approved. Starting T1.

## Next step
T1–T3.
