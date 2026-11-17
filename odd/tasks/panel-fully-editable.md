# Feature: the operations panel is fully editable, so an admin fixes data without calling the developer

## Objective
An admin can, from the operations panel: remove a recipient, create any operation from scratch, attach the receipt image from the chat,
and edit any value, including closed operations. Every change is audited. Today fixing a case like the Elisvan one (2026-11-17) needs
a developer.

## Problem / why (owner, 2026-11-17)
- "quiero poder crear desde cero cualquier operacion y poder editar cualquier valor"; if a receipt is missing "poder elegir del chat la
  imagen del comprobante"; add or delete a beneficiary. "actualmente para poder arreglar errores ... tengo que contactar contigo".
- Panel map (read-only, 2026-11-17; code + production DB):
  - exists: PATCH `crm_corregir_operacion` (5 fields only: destination_currency, delivery_method, deposit_method, quoted_source_amount,
    quoted_destination_amount; refuses completed/cancelled), POST `crm_agregar_beneficiario`, PATCH `crm_corregir_beneficiario` (refuses
    closed operations), POST `crm_reasignar_beneficiario`, `crm_cambiar_servicio`, `crm_repartir_envio`, `crm_verificar_deposito`,
    `crm_forzar_verificacion`, close-manual, deliver, `crm_eliminar_operacion` (not for finished or verified), calculator entry
    correct/delete/manual add, chat-images picker (`crm_imagenes_de_conversacion`, used only for a cash recipient's ID photo).
  - missing: remove a recipient; create an operation from scratch; attach a chat image as a receipt; edit closed operations.

## Owner decisions
- 2026-11-17: asked for the panel changes ("y los cambios al panel x fin?"). Order proposed earlier and not objected to: remove a
  recipient, create from scratch, attach receipt from chat, then closed operations.
- Pending (asked when the task comes up): what attaching a chat image to an operation must do (evidence only, or also verify the
  deposit); how far editing a closed operation may go (the calculator and card inventories are append-only: void + re-feed).

## Scope
In: SQL functions (migrations 377+) with ROLLBACK and staging assertions, API routes, client commands, panel components, messages es/en,
vitest. Staging and the local staging panel first; production DB and panel publish each with an explicit go-ahead.
Out: the bot, the Decisor, the notifier.

## Constraints
- Strict TDD (source: user CLAUDE.md). Runners: SQL assertions through `infra/db/staging-migracion.sh` (rolled-back transactions);
  `npx vitest run <path>`; `npx tsc --noEmit`. RDD off. No AI attribution in commits (user CLAUDE.md wins over the harness reminder).
- AGENTS.md: this Next.js has breaking changes; copy the patterns of the sibling routes and components, read
  `node_modules/next/dist/docs/` before inventing an API. `node_modules` of this worktree is a symlink to the main checkout's.
- Every write goes through a SECURITY DEFINER `crm_*` function that checks `is_account_member(account, 'agent')`, refuses what it must,
  writes a `remittance_admin_audit` row and locks the touched fields against automation (`admin_locked_fields`).
- Never touch the other session's files (`pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`,
  `pruebas/decisor/decisor-notas.test.ts`, `odd/tasks/bot-brevedad.md`).
- The panel is published with `wacrm-publicar-panel` (release branch to remote `privado`, build in prod-build), only with a go-ahead.

## Tasks
- [~] T1 (code + tests done, staging panel check and production pending) Remove a recipient: `crm_quitar_beneficiario` (migration 377) + assertion; DELETE route; client command; button with inline
      confirm on each recipient; messages es/en; vitest
- [ ] T2 Create an operation from scratch (design first: conversation, service, amount, recipients)
- [ ] T3 Attach a chat image as a receipt (owner decision first)
- [ ] T4 Edit more values of an open operation (status, deposit, conversation links) with audit
- [ ] T5 Edit closed operations, ledger-safe (owner decision first)
- [ ] T6 Panel publish for each finished group (needs go-ahead)

## Acceptance criteria
- T1: an agent removes a current recipient of an open operation: the row becomes `reemplazado` (history kept), the operation is locked
  against automation for beneficiaries, an audit row `human_beneficiary_removed` keeps the removed data, a combo total follows. A closed
  operation, a recipient that is not current, an unknown id or a non-member are refused. The panel shows the button only to who can edit,
  asks for confirmation and refreshes the card.

## Progress / evidence
- T1 SQL (2026-11-17, commit a81727cb): assertion `remove-beneficiary.sql` RED on the base (function absent), GREEN with migration 377
  (`staging-migracion.sh aplicar`: dry-run/apply/assertion/rollback OK, function md5 cd1fffcc). The first run failed on the audit table:
  `remittance_admin_audit_action_chk` only accepts listed actions, so 377 re-creates the constraint with the production list plus
  `human_beneficiary_removed` (ROLLBACK-377 re-adds the old list as NOT VALID so audit rows already written are kept). Related
  assertions (pattern crm_agregar_beneficiario|crm_corregir_beneficiario|crm_quitar_beneficiario|admin_audit_action_chk|human_beneficiary,
  --ya-aplicada): TOTAL 14, SAME 13, DIFF 1 (remove-beneficiary RED->GREEN). The SAME failures (grants-mirror-production, saldo-model)
  fail identically on the base. Removal = `status 'reemplazado'` + `replaced_at` (the table only allows vigente/reemplazado), the
  operation is locked for beneficiaries, a combo total is recomputed, the audit row keeps the removed data in `before`.
- T1 app: route POST `/api/remittance-operations/beneficiaries/[beneficiaryId]/remove` (7 route tests), command `quitarBeneficiario`
  (2 tests), component `beneficiary-remove-control.tsx` (4 tests) and a Remove (trash) button beside Edit / Move on every recipient of an
  editable card, one or several (3 card tests), messages es/en. RED first on each (missing route / component / button), GREEN after:
  `npx vitest run src/components/inbox/operations` 37 files, 627 tests; `npx tsc --noEmit` clean; eslint clean on the new files.
- Environment: the symlinked `node_modules` lacked jsdom; replaced with `npm ci --ignore-scripts` in this worktree (git-ignored).
  Also fixed a type error of my notifier test (dotAll regex flag), commit c3e40d76.

## Next step
T1: look at it in the local staging panel with the owner (wacrm-probar-staging), then production migration 377 + panel publish, each
with a go-ahead. Then T2.
