# Eliminate the `deals` dependency (product-wide)

## Objective
Remove `deals`/`pipelines`/`pipeline_stages` from the product entirely: the remittance bot must
create operations, register beneficiaries, and compute deposit balances without ever touching
`deals`; the generic CRM's "Deals" tab (Contacts) and the "create_deal" automation action are
removed too. End state: `deals`/`pipelines`/`pipeline_stages` tables dropped.

## Why
User (2026-09-29): the operations panel/RPCs (114's cutover) were built specifically to stop
depending on `deals`, but the remittance flow still creates operations and registers beneficiaries
through it. Wants it eliminated completely — confirmed this includes the generic CRM "Deals" tab
and "create_deal" automation action too, not just the remittance path (a scoping fork's first
exploration wrongly claimed deals had no non-remittance use; corrected after finding
`contact-detail-view.tsx`'s Deals tab and `automations/engine.ts`'s `create_deal` step both live and
wired).

## Constraints
- Staging first, same as every other task in this project. Production only with explicit
  per-migration go-ahead, same discipline as migration 144 today.
- The final `DROP TABLE deals/pipelines/pipeline_stages` needs one more explicit confirmation right
  before it runs, even though the user already authorized full elimination — it's irreversible and
  this plan spans many separate work sessions.
- Strict TDD: RED before GREEN, real command output, never fabricated.
- No FK exists from any table to `deals(id)` (confirmed) — so a missed dependency fails SILENTLY
  (a remesa just never reaches the panel), not with a constraint error. Every phase below must be
  verified by actually exercising the behavior, not just "the migration applied cleanly."

## What's actually left (confirmed by exploration, 2026-09-29)
1. **Operation creation** — the only path to a `remittance_operations` row is a `deals` INSERT
   (trigger `trg_sync_operacion_al_crear_deal`, 125). Six n8n nodes insert into `deals` for this:
   `Registrar beneficiario auto`, `Registrar zelle auto`, `gestionar_beneficiario`,
   `registrar_beneficiario_zelle`, `registrar_reparto_multiple`, `marcar_destino_usd`.
2. **Beneficiary registration** — the main path, not a legacy leftover: `trg_sync_z_benef_desde_deal`
   (043) parses `deals.notes` with regex (`cerebro_parsear_beneficiarios`, 042).
3. **Deposit balance** — `cerebro_saldo_envio(p_deal)` (109) feeds the objetivo/depositado/saldo
   numbers the deposit-review panel (touched today in B4.3) shows, indexed by `deal_id`.
4. **Audit notes** — `crm_forzar_verificacion`, `crm_corregir_operacion`,
   `crm_corregir_entrada_calculadora`, `cerebro_cruzar_deposito` etc. still write human-readable
   text into `deals.notes`, duplicating what `remittance_admin_audit` already captures structured.
5. **Admin locks** (096) still reference `deals.stage_id`.
6. **Generic CRM (non-remittance)**: `src/components/contacts/contact-detail-view.tsx`'s "Deals" tab
   (`.from('deals').select('*, stage:pipeline_stages(*)')`), `src/lib/automations/engine.ts`'s
   `create_deal` step type (needs `pipeline_id`+`stage_id`).

## Tasks

### Phase 1 — Readers first, then writers stop creating via `deals` (DB + n8n)
Reordered 2026-09-30 (user-approved): the staging Cerebro keeps bot state in `deals.notes` and two
nodes read it every turn, so switching writers first would silently drop history, duplicate-receipt
detection, deposit way and recarga-in-progress for new operations. Map: Engram
`discovery/eliminate-deals-n8n-map`.
- [ ] 1.0a — Field-by-field map of every `deals`-derived output of `Contexto conversacion` and
  `Historial contacto` to a structured source (`remittance_operations`, `remittance_beneficiaries`,
  deposits, audit), or "no structured source" (then a structured column/table must come first).
- [ ] 1.0b — Rewrite `Contexto conversacion` to read structured sources only. Parity check on
  staging: old vs new query output on the same conversations must match. Byte-exact draft diff
  before publish.
- [ ] 1.0c — Same for `Historial contacto`.
- [ ] 1.1 — New RPC that creates a `remittance_operations` row directly (whatever
  `trg_sync_operacion_al_crear_deal` currently derives: account/contact/currency/status), with NO
  `deals` row involved, writing structured beneficiary / USD-destination data up front (Phase 2
  folds in here).
- [ ] 1.2 — Rewire the 7 writers to the new RPC(s), one at a time, each verified individually
  (byte-exact draft verification before publish): `Registrar beneficiario auto`,
  `Registrar zelle auto`, `gestionar_beneficiario`, `registrar_beneficiario_zelle`,
  `registrar_reparto_multiple`, `marcar_destino_usd`, and `Registrar deposito auto`
  (`cerebro_registrar_deposito`, which also INSERTs `deals`; missed by the first exploration).

### Phase 2 — Beneficiaries stop being parsed from `deals.notes`
- [ ] 2.1 — The Phase 1 RPC(s) write `remittance_beneficiaries` rows directly and structured
  (mirroring exactly what `cerebro_parsear_beneficiarios` derives today), so `trg_sync_z_benef_desde_
  deal` is never needed for a NEW operation created after this phase ships.
- [ ] 2.2 — Confirm (read-only) no other path still depends on the notes-parse trigger before
  touching it further.

### Phase 3 — Deposit balance reindexed by operation, not deal
- [ ] 3.1 — New `cerebro_saldo_envio_operacion(p_operation)` (or an overload), reading
  `remittance_operations`/`remittance_beneficiaries`/`depositos_mmg` by `operation_id`.
- [ ] 3.2 — Repoint every caller (099's deposit-review RPC, the panel) to the new function.

### Phase 4 — Stop writing to `deals` from remittance functions
- [ ] 4.1 — Remove the `UPDATE deals SET notes = ...` lines from `crm_forzar_verificacion`,
  `crm_verificar_deposito`, `crm_corregir_operacion`, `crm_corregir_entrada_calculadora`,
  `cerebro_cruzar_deposito` (and any other remittance function still found writing `deals`) — this
  info already lives in `remittance_admin_audit`, confirmed nothing in the UI reads `deals.notes`.
- [ ] 4.2 — Remove 096's admin locks on `deals.stage_id` for the remittance path.

### Phase 5 — Verify zero remittance-path dependency on `deals`
- [ ] 5.1 — Grep the full remittance SQL + n8n surface for any remaining `deals`/`deal_id`
  reference; confirm none remain for the remittance flow. `remittance_operations.deal_id` can be
  dropped or left nullable-and-unused for a safety window.

### Phase 6 — Remove `deals` from the generic CRM, then drop the tables
- [ ] 6.1 — Remove the "Deals" tab from `contact-detail-view.tsx` (and its `fetchDeals`/`Deal` type).
- [ ] 6.2 — Remove the `create_deal` step type from `automations/engine.ts` and any automation-step
  config UI that offers it.
- [ ] 6.3 — Confirm (grep) nothing anywhere in the repo references `deals`/`pipelines`/
  `pipeline_stages` any more.
- [ ] 6.4 — **STOP and get one more explicit go-ahead from the user before this step.** Drop
  `deals`, `pipelines`, `pipeline_stages` and their triggers/functions. Irreversible.

## Progress
- 2026-09-29: document created. Scoping fork's exploration (see task doc
  production-feedback-2026-09-29.md, "seventh/eighth touch-point") found items 1-6 above. A second
  pass by me (not delegated) found the two non-remittance dependencies (item 6) the fork missed,
  corrected the scope with the user before starting any implementation.

- 2026-09-30: read-only map by Hermes (DB) + OpenCode (n8n), verified by me: 9 nodes touch
  `deals` (7 writers, 2 readers). Phase 1 reordered to readers-first with the user's approval.

## Next step
1.0a — map every `deals`-derived output of the two reader nodes to a structured source.
