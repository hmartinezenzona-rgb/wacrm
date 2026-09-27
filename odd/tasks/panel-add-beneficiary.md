# Operations panel: add a beneficiary by hand

## Objective
Let an operator ADD a beneficiary (Cuban card, Zelle, or phone top-up data, with its amount) to an
open remesa from the in-chat operations panel, so it can be completed even when the bot never
captured the beneficiary.

## Problem / why (found 2026-09-27, before the production cutover)
- `crm_entregar_operacion` (latest body in migration 114) refuses delivery unless
  `crm_beneficiarios_completos(op)`; the panel can only EDIT (`crm_corregir_beneficiario`) or
  REASSIGN (`crm_reasignar_beneficiario`, 098) an EXISTING beneficiary. There is no add path.
- Production: the bot records a beneficiary for only part of the remesas (week of 2026-09-21:
  29 of 68). The rest were handled by humans in the chat. From Monday 2026-09-28 those could not
  be completed from the panel. 3 of the 5 open legacy operations have no beneficiary.
- User decision (2026-09-27): do this first (before the production code deploy); improving the
  Cerebro's beneficiary capture comes after.

## Scope
- New migration `123_add_beneficiary_rpc.sql` (+ `ROLLBACK-123-…`): `crm_agregar_beneficiario`,
  following the exact conventions of 098 (auth via account membership, `wacrm_current_actor()`,
  audit row in `remittance_admin_audit` as a human correction, admin locks so n8n cannot overwrite
  the admin-entered row, status rules for terminal operations).
- API route under `src/app/api/remittance-operations/[operationId]/beneficiaries` (POST).
- Panel UI: an "Add beneficiary" control on an open remesa card, in the style of the existing
  correction form; i18n keys in every locale file the panel already uses.
- Staging: apply 123, SQL assertion (self-reverting, BEGIN … ROLLBACK), deploy code to staging.

## Out of scope
- Cerebro capture improvements (next feature).
- Legacy parity backfill of destination amounts (separate, already approved).

## Constraints
- Production untouched: 123 is added to the cutover migration list, applied there only with the
  rest of the cutover.
- Never delete data. Additive migration only.
- TDD: Strict TDD enabled (user global config). Runner: `npm test` (vitest). SQL behavior: scripted
  staging assertion, RED before GREEN.
- Advisory ~400 authored lines per task; not a hard cap.

## Tasks
- [x] A1 — Migration 123 `crm_agregar_beneficiario` + rollback + staging assertion (RED on staging
  without 123, GREEN with it). Commit 67918d4.
- [x] A2 — API route POST + tests (RED → GREEN). Commit b867ed7.
- [x] A3 — Panel UI "Add beneficiary" + tests (RED → GREEN) + i18n. Commit a016f52.
- [ ] A4 — Apply 123 to staging, deploy code to staging, user checks it on crm.onlinefreedom.site.
- [x] A5 — Add 123 to the cutover plan (step 6c, after 121) with its check.

## Acceptance criteria
- An operator can add a card / Zelle / phone beneficiary with amount to an open remesa; the
  panel then shows it and, once complete, "Completar transferencia" works.
- Adding to a completed/cancelled operation is refused.
- The row survives a later n8n/bot write (admin lock), and an audit row records who added it.
- `npm test` green; staging assertion GREEN; nothing in production changes before the cutover.

## Progress
- 2026-09-27: document created.
- 2026-09-27: A1 done (commit 67918d4). `supabase/migrations/123_add_beneficiary_rpc.sql` +
  `ROLLBACK-123-add-beneficiary-rpc.sql` + `supabase/staging/assertions/add-beneficiary.sql`.
  Mirrors 098's auth/lock/audit conventions; requires amount+currency (unlike a correction) since a
  new beneficiary has no prior row to inherit them from. Discovered mid-task: 114 retired the
  deals→remittance_operations INSERT/UPDATE mirror trigger, so `corrections.sql`'s
  "INSERT INTO deals auto-creates an operation" fixture pattern no longer holds — this migration's
  assertion inserts `remittance_operations` rows directly instead (a deal row is still created for
  the one case, cerebro_sync_beneficiarios, that needs the deals join). Also had to restate the full
  current `remittance_admin_audit_action_chk` vocabulary (through 104), not just 098's, since 099/
  101/104 each redefined that CHECK. RED: staging assertion against staging without 123 fails with
  "function crm_agregar_beneficiario(uuid, jsonb) does not exist". GREEN: `BEGIN; \i 123; \i
  add-beneficiary.sql; ROLLBACK;` — 9/9 PASS. Rollback verified clean (`BEGIN; \i 123; \i
  ROLLBACK-123; ROLLBACK;`). Nothing applied to staging or production.
- 2026-09-27: A2 done (commit b867ed7). `POST /api/remittance-operations/[operationId]/beneficiaries`
  + `route.test.ts`, same auth/beta-flag/RPC-error-code pattern as the sibling routes; added
  `agregarBeneficiario` to `commands.ts`. RED: 15/15 failing (route.ts missing) →
  GREEN: 15/15 passing (`npx vitest run`).
- 2026-09-27: A3 done (commit a016f52). `BeneficiaryAddControl` (type select + per-type fields +
  amount/currency, client-side validation mirroring the RPC) plus its wiring into
  `RemittanceOperationCard` (icon button next to "Deliver to", hidden when not editable/history/
  terminal); i18n keys added to `messages/en.json` (the only locale file the panel uses). RED:
  component import missing / new card tests failing → GREEN: 10/10 (control) + 77/77 (card) passing.
- 2026-09-27: full-suite verification for A1-A3: `npm test` → 1531 passed, 2 pre-existing failures
  (`src/lib/dashboard/date-utils.test.ts`, `mondayIndex`, timezone-related) confirmed present on the
  base commit before this work (stashed and re-verified) — unrelated to this feature. `npx tsc
  --noEmit` clean. `npx eslint` on all changed files clean. A4/A5 intentionally not started (require
  applying to staging / touching the cutover plan — out of this writer's scope).
- 2026-09-27: parent spot check: staging assertion 9/9 PASS (BEGIN…ROLLBACK), new tests 102/102;
  review assess = medium (sonnet writer → writer self-verification + parent spot check). A5 done.
