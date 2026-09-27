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
- [ ] A1 — Migration 123 `crm_agregar_beneficiario` + rollback + staging assertion (RED on staging
  without 123, GREEN with it).
- [ ] A2 — API route POST + tests (RED → GREEN).
- [ ] A3 — Panel UI "Add beneficiary" + tests (RED → GREEN) + i18n.
- [ ] A4 — Apply 123 to staging, deploy code to staging, user checks it on crm.onlinefreedom.site.
- [ ] A5 — Add 123 to the cutover plan (after 118, before 121) with its check.

## Acceptance criteria
- An operator can add a card / Zelle / phone beneficiary with amount to an open remesa; the
  panel then shows it and, once complete, "Completar transferencia" works.
- Adding to a completed/cancelled operation is refused.
- The row survives a later n8n/bot write (admin lock), and an audit row records who added it.
- `npm test` green; staging assertion GREEN; nothing in production changes before the cutover.

## Progress
- 2026-09-27: document created.
