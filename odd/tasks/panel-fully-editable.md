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
- [~] T2 (code + tests done, staging panel check and production pending) Create an operation from scratch: `crm_crear_operacion` (migration 378), POST on the collection route, command, "New operation" control next to the panel title
- [x] T3a (code + tests done; staging panel check and production pending) Attach a chat image as a receipt: `crm_adjuntar_comprobante(operation, wamid, ref?, amount?)` creates the `comprobantes_hashes`
      mapping and a `remittance_operation_receipts` row (source admin), prefilled from the vision reading of that image when the bot already
      read it (`cerebro_lecturas_vision`: referencia, monto), otherwise typed; then the card's existing verify flow runs. Reuses the image
      picker. Attach only, no automatic verification
- [x] T3b (code + tests done; staging panel check and production pending) Link a deposit from the MMG ledger that has no owner (61 in the last 30 days): a list (newest first, amount, TransID, date) and a
      pick; it runs the same crossing as `crm_verificar_deposito` with that TransID and amount
- [x] T3c (code + tests done; staging panel check and production pending) Release a linked deposit from an operation or move it to another one (36 of the 298 audited developer corrections of 2026-10-03
      to 2026-11-13 were deposit links), reusing the core of the bot's `mover_deposito`
- [x] T4 (code + tests done; staging panel check and production pending) Move an open operation between open states from the panel (new -> awaiting deposit -> deposit verification -> ready to transfer, and back),
      audited, with the notify-customer bell. Needed: verify and force-verify only work from `deposit_verification` / `incident`, so an
      operation created from scratch (T2) cannot be verified today (PROPOSED)
- [x] T5 (code + tests done; staging panel check and production pending) Edit closed operations (completed / cancelled): recipients, service / rail, amounts, audited, with a banner that the calculator
      and the inventories are not recomputed (they are edited in the calculator, which already allows it). Re-feeding the calculator line
      from the operation is NOT in scope unless the owner asks
- [ ] T6 Panel publish for the finished groups, with the migrations 377+ in order (needs go-ahead)

## Evidence for the scope (production audit, read-only, 2026-11-17)
298 audited corrections made by the developer on 2026-10-03..2026-11-13 (`remittance_admin_audit`, actor `claude-code:*`): deposit <-> operation
links 36 (depositos_mmg), operation status 11 + 9 deleted + 8 manual close, delivery_method 115 (one bulk backfill), contact name 15,
bot objective 8, conversation history 7, service type 3, mixed split 4, recipient amount 3, source amount 3, calculator line delete 4.
151 closed operations were touched. Verify / force-verify require status `deposit_verification` or `incident`.

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

- T2 SQL (commit a76c5c5e): assertion `create-operation.sql` RED on the base (function absent), GREEN with migration 378
  (`staging-migracion.sh aplicar`: dry-run/apply/assertion/rollback OK, function md5 7e8a8de3). Design: `crm_crear_operacion(conversation,
  service, amount)`: an open remesa (collecting_information, GYD) with the typed amount, then the panel's own `_cambiar_servicio_core`
  applies the service (type, rail, destination currency, rail lock; a Mexico send pays out in MXN). Amount > 0 required except for a
  combo (its total is the sum of its recipients): a 0 GYD operation is a ghost (the Elisvan case). Audit `human_operation_created`
  (the audit-action constraint is re-created with the staging list after 377 plus the new action; ROLLBACK-378 re-adds the old list NOT VALID).
  Related assertions (pattern crm_cambiar_servicio|_cambiar_servicio_core|crm_crear_operacion|admin_audit_action_chk|human_operation,
  --ya-aplicada): TOTAL 13, SAME 12, DIFF 1 (create-operation RED->GREEN); grants-mirror-production and saldo-model fail identically on the base.
- T2 app: route POST `/api/remittance-operations` (10 tests, `route.post.test.ts`), command `crearOperacion` (3 tests), component
  `operation-create-control.tsx` (7 tests: button -> inline form with service + deposit, combo without amount, other services need an amount,
  refusal shown, cancel), the container shows it next to the title when the user can edit (also with no open operation), refetches and
  opens the new card (3 container tests, the control stubbed there like DepositReviewContainer). RED first on each. `npx vitest run
  src/components/inbox/operations` 38 files, 637 tests; `npx tsc --noEmit` clean; eslint clean on the new files.

- T4 (2026-11-17, owner approved the scope: "si dale"): SQL commit acb79072: assertion `change-status.sql` RED on the base, GREEN with migration
  379 (`staging-migracion.sh aplicar` OK, function md5 19d3e715). `crm_cambiar_estado(op, estado, notify)`: any OPEN state -> collecting_information |
  awaiting_deposit | deposit_verification | ready_to_transfer; leaving an incident clears its reason; same state = no-op; the customer notice
  of the new state is muted unless notify and target ready_to_transfer (then a `human_forced_verification` audit row lets the notifier speak);
  audit `human_status_change` (constraint list = staging after 378 + the new action). The assertion proves the reason for it: force-verify from
  collecting_information is still refused, but after moving to deposit_verification an operation created from scratch force-verifies.
  App: route POST `/api/remittance-operations/[operationId]/status` (8 tests), `cambiarEstado` (2), `operation-status-control.tsx` (7: four
  states minus the current one, the bell only for ready_to_transfer and off by default), a Flag button in the card's action row (2 new tests; 2
  layout tests updated for the new button). `npx vitest run src/components/inbox/operations` 39 files, 646 tests; tsc clean.

- T3b (commits 621db910, d81c8f61): `crm_depositos_mmg_libres` (migration 380) read function + assertion; route
  `/free-deposits` (107-line test), `free-deposits-picker.tsx` (153-line test), command and types, wired into `deposit-review-container`.
  Linking reuses the existing verify crossing (`crm_verificar_deposito`), no new write function.
- T3c (commits 5f563c8d, 4bf72184): `crm_mover_deposito` (migration 381) + assertion (235 lines, replaces the older move-deposit
  assertion), route `/move-deposit`, `consumed-deposits-control.tsx` (169-line test), command and messages.
- T3a (commits 4fd8b584, 8471c66a): `crm_adjuntar_comprobante` (migration 382) + assertion; route `/receipts`, `attach-receipt-control.tsx`,
  command, wired into the deposit block. Attach only: it does not verify.
- T5 SQL (commit 0c786efb): migration 383 relaxes the closed guard of `crm_corregir_operacion`, `crm_corregir_beneficiario`,
  `crm_agregar_beneficiario`, `crm_quitar_beneficiario` and `crm_cambiar_servicio` for owner/admin (agent still refused, 22023); every closed
  edit writes `human_closed_operation_edit`; the calculator is not fed and the destination amount is not recomputed. Assertion
  `closed-operation-edit.sql` covers completed, cancelled and the agent refusal on the five functions.
- T5 app (commit 3afd000d): the card splits `editable` (open-only) from `closedEditable` (owner/admin + completed/cancelled) and
  `sharedEditable` (amounts, recipients add/edit/remove, service). Status, deliver, verify, close-manual, delete, split and reassign stay
  open-only. New `closed-edit-banner.tsx` (es/en: audited, calculator and inventories are not recalculated). History cards in
  `operations-panel-container.tsx` now receive `canEdit` and the real `accountRole` on both the plain and grouped paths. TDD: RED observed on
  the three touched test files (20 failed), GREEN `npx vitest run src/components/inbox/operations` 44 files / 703 tests, `tsc --noEmit` clean,
  eslint clean. Parent spot check re-ran the two new test files: 23 passed.
- T6 staging (2026-11-17): migrations 380-383 were already applied on staging (verified: the nine functions of 380-383 exist and
  `remittance_admin_audit_action_chk` includes `human_closed_operation_edit`). The four assertions run against the applied state with
  `ALL PASS (rolled back on purpose)`: free-deposits, move-deposit, attach-receipt, closed-operation-edit. Re-applying 380 ended with the
  rollback test failing because the function already existed; that test only applies to a first apply, not to an idempotent re-apply.
- Staging fixtures (2026-11-17): `PRUEBA quitar destinatario` (conv ec09ae34) cleaned with a dry run shown first and zero rows left. New
  fixture `PRUEBA panel editable` (59902530378, op 238c536d now completed) for the closed-operation edit, and `PRUEBA comprobante chat`
  (59902530379, op 83988f69) with a free deposit 21402978530091 and one chat image.
- Bug fixed from the owner's browser test (commit 7d7e0905): the deposit block returned null when there were no receipts and no
  verification to run, so the attach control never rendered on `ready_to_transfer`/`awaiting_deposit`. Now the attach (and the
  deposit-release control) render on any open editable operation; TDD RED `expected null not to be null`, GREEN 44 files / 704 tests, tsc clean.
- Bug fixed from the owner's browser test (commit 46e610af, migration 384): correcting `quoted_source_amount` left
  `cerebro_objetivo_envio.monto` behind when the open objective belonged to the same operation (the 320 trigger only seeds the objective when
  none is open), so the card showed 29,000 GYD and "missing 24,400 GYD" at once. The trigger gains a third branch: an open objective that
  belongs to the operation follows a corrected amount; conversation-level objectives, another operation's objective, closed operations and
  operations with a consumed deposit stay untouched. TDD RED `case a: the objective did not follow the corrected amount: 24400`, GREEN:
  dry-run/apply/assertion/rollback OK (md5 previo = after rollback), related assertions TOTAL 177 SAME 174 DIFF 3 — the new one RED->GREEN plus
  `contexto-envio-mixto` (flaky in base, identical-created_at ordering) and `delivery-feed-evidence` (fixture setup fails identically in base).
- Not a bug (owner's first close attempt): the audit shows `human_correction quoted_source_amount 24400 -> 29000` on op 83988f69 at 19:34:30,
  so the deposit of 24,400 correctly did not cover 29,000 and the panel refused the verification; the manual close is the deliberate exit.
- Gap fixed from the retest (commit d330d470): an operation created from scratch stays in `collecting_information`, where an attached receipt
  has no verify form (verify/force-verify exist only in `deposit_verification`/`incident`). The deposit block now shows "Pasar a verificación
  de depósito" when the user can edit, the operation is open, there is at least one receipt and `can_verify` is false; it calls the audited,
  muted `crm_cambiar_estado` to `deposit_verification`, refetches and reloads the card. The attach note no longer promises a verify form that
  is not there (`attachReceipt.attachedNeedsStage`). TDD RED 3 failed, GREEN 44 files / 710 tests, tsc clean; parent spot check 37/37.
- Wording fixed from the retest (commit a12c429f): the force path is named "Forzar verificación (sin confirmación en el correo)…" and the
  `ya_reclamado` result now explains it ("Este TransID ya se usó en otra transferencia. Si el depósito no tiene confirmación en el correo,
  puedes forzar la verificación."). Owner's domain rule (2026-11-17): the MMG ledger is fed from email, so a deposit whose email never
  arrived has no row to cross — force exists exactly for that case and must stay. Three distinct cases: a free ledger deposit (link it), a
  claimed TransID (look for the right one, or force with evidence), no email confirmation (force). Tests 44 files / 710, JSON valid.
- Retest evidence (2026-11-17 late): T3b end-to-end worked — the 29.000 PRUEBA deposit was linked with `human_deposit_verification`
  (`saldo 0.00`, exact) and the operation reached `ready_to_transfer` without forcing. The owner then cancelled that operation and created a
  new one from scratch, which released the deposit (`op=libre`) and exposed the missing verification path above.
- Production (2026-11-17, owner go-ahead "aplica las ocho en orden"): `previa` ended `REVISAR (2 diferencias)` both times, both only the
  `NOT VALID` flag of the two constraints the migrations drop and recreate; the allowed lists matched production. Applied versions:
  377 20261117212118, 378 20261117212120, 379 20261117212148, 380 20261117212149, 381 20261117212155, 382 20261117212158,
  383 20261117212201, 384 20261117212205. Two API version collisions (`23505 schema_migrations_pkey`) aborted 379 and later 381 inside the
  batch because the Management API stamps versions at second granularity; both rolled back whole and were re-applied alone. `verificar`:
  **12/12 EQUAL** (`prod = stg` md5 for every function, including `remittance_operations_objetivo_desde_op` 9a9d757d).
- Panel published in production (2026-11-17, owner go-ahead): release branch `release/prod-panel-fully-editable` at `559d2c1b`
  (pushed to `privado`), artifact `build_id gl5T1u8LrDq-8_3wymdpX`, `current -> 559d2c1b...`, rollback `anterior -> a7a469a0...`.
  `compilar --sin-pruebas` because the prod-build `node_modules` has no dev deps (`vitest/config` unresolvable); vitest and tsc had run on
  the same sha in mejora-legacy (710 tests, clean). The build itself ran in `node:20`.
- Pending: staging fixture cleanup. The standard `limpieza.sql` fails on the closed fixture because its completed operation fed the
  calculator and completed calculator rows are append-only (DELETE refused). The dry run succeeds when the fixture's completed calculator
  rows are voided first (`status='void', voided_at=now()`, figures untouched, allowed by the guard) inside the same transaction.

- Operational note for the next production apply: do not send two migrations in the same second through the Management API; apply one per
  invocation or space them, otherwise `schema_migrations_pkey` collides.

## Next step
Owner retest in the browser with the two fixtures (attach on an open operation, then correct the amount and confirm the header and the
"missing" line agree), then production migrations 377-384 in order and the panel publish, each only with an explicit go-ahead. Open product
decisions: owner decision 2026-11-17 — attaching a receipt on a closed operation stays refused (the 382 function rejects completed/cancelled
and the card hides the control; do not change it). Still open: the English fallback message when the image is already a receipt.
