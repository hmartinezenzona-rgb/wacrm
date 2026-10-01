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
- [x] 1.0a' — Structured receipts: migration 156 adds `remittance_operation_receipts` + parser
  `cerebro_parsear_comprobantes`, backfills receipts from `deals.notes`, and makes all three write
  branches of `cerebro_registrar_deposito` dual-write the receipt against its operation. Commit
  41ab02d (written by OpenCode; currency capture-group bug fixed by me). Evidence on staging: RED
  (parser missing) → GREEN 5/5 in a rolled-back transaction; rollback proven (function md5 back to
  a0251d99…, table and parser gone); `registrar-deposito-creado` still ALL PASS; applied to staging
  2026-09-30 (backfill 24 rows, 1 with COMP id). Before production: measure the parser on
  production notes read-only (lesson: fresh data hides old formats).
  Other notes readers still to repoint later: `crm_comprobantes_de_operacion` (099, deposit panel),
  `cerebro_registrar_deposito`'s own idempotency/branch checks on notes.
- [x] 1.0b — Rewrite `Contexto conversacion` to read structured sources only. Parity check on
  staging: old vs new query output on the same conversations must match. Byte-exact draft diff
  before publish.
- [x] 1.0c — Same for `Historial contacto`.
- Work units for 1.1/1.2 (2026-09-30, from my own inventory: 31 latest SQL functions still
  reference deals/stage/notes — workers' design/inventory reports were too shallow to rely on).
  Each unit small, staging-first, old (deal) and new (no deal) operations must both keep working:
  - [ ] WU1 operation-keyed money helpers: cerebro_saldo_envio / cerebro_objetivo_atar /
    cerebro_objetivo_cerrar get operation-id variants; deal-id versions delegate to them (absorbs
    Phase 3).
  - [ ] WU2 receipt readers off notes: cerebro_cruzar_deposito(s), crm_verificar_deposito,
    crm_forzar_verificacion, crm_comprobantes_de_operacion read remittance_operation_receipts
    (+ add block_index to receipts first).
  - [ ] WU3 cerebro_registrar_deposito without deals (movido/sumado/creado on operations,
    idempotency by receipts.comp_id); `id` returned = what 'Cruzar deposito con MMG' consumes,
    rewired together.
  - [ ] WU4 beneficiary writer RPCs (card auto/tool, zelle auto/tool, reparto, marcar_destino_usd)
    on operations + beneficiaries, same inputs/outputs as today's node SQL.
  - [ ] WU5 rewire the 7 n8n nodes one by one (byte-exact draft diff, live test each).
  - [ ] WU6 stage-based notifiers/alerts (090, 114 notify_*, 136 avisos, 052, 096 guard) → status.
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

- 2026-09-30: 1.0a mapping done (Hermes: Contexto, OpenCode: Historial, verified by me). Gap: the
  receipt→operation link lived only in `deals.notes` → 156. `corregido` (Historial) has no writer
  in SQL (only 042's parser skips it); decide during 1.0c.

- 2026-09-30: 1.0b query written by OpenCode (ordering fixed by me: by operation created_at,
  because backfilled receipts carry the migration time). Staging parity old vs new over all 9
  (conversation, comp_id) pairs: 1 diff, dup_etapa 'Por verificar' → 'Lista para transferir' for an
  operation that is ready_to_transfer while its deal stage is stale since 114 (new is right).
  Draft diff: only Contexto conversacion.parameters.query changed. Published on staging:
  88dbbcb1 (previous eb85f86b for restore). Query copy: odd/backups/n8n-staging-contexto-conversacion-1.0b.sql.
  Behavior change accepted as a fix: recarga_en_curso's 24 h window now moves on real deliveries.
- 2026-09-30: 1.0b live WhatsApp test on staging (executions 287507-287513, all success): the
  receipt was dual-written by the bot (receipts row source='bot', COMP-47202fc9…, Agente MMG);
  Contexto output dup_etapa='Por verificar', dup_valor=40000, via_deposito_ya_usada='Agente MMG',
  recarga_en_curso=false. The user did not resend the same screenshot (step 3), so the Decisor's
  duplicate branch was not exercised live; its inputs were.

- 2026-09-30: 1.0c query by OpenCode (session wacrm-worker). Staging parity over 8 conversations:
  every diff explained and judged correct or harmless — stale deal stages ('Lista para transferir'
  on cancelled ops, 'Solicitada' on a deposit_verification op), envios_abiertos 9→8 (deal open,
  op closed), amounts '40000.00'→'40000' (text only), and beneficiarios now include reparto cards
  (old regex only read the last notes block): accepted behavior change. corregido =
  admin_audit human_correction OR a 'reemplazado' beneficiary. Draft diff: only Historial
  contacto.query. Published on staging e8ef4342 (previous 88dbbcb1). Copy:
  odd/backups/n8n-staging-historial-contacto-1.0c.sql. Pending: live test.
  Follow-up: add block_index to remittance_operation_receipts (backfilled multi-receipt ops lost
  their order; created_at = migration time).
- 2026-09-30: new bug found in the live test: the LLM skipped marcar_destino_usd, Clasica shown as
  CUP (Engram bug/clasica-shown-as-cup; 3 likely cases in production in 60 days). User: fix it
  right after 1.0c, as a deterministic step that writes operations directly (first 1.2 writer).

- 2026-09-30: 1.0c live test on staging (exec 287783): second request after a delivered remesa →
  Historial envios_previos=1, ultimo_estado='Entregada' (the old query would have shown the stale
  deal stage), beneficiarios=[the card used], envios_abiertos=0. The tester then resent the SAME
  receipt for the second remesa; the bot answered "Ese envio ya fue entregado": correct, that
  COMP id belongs to the delivered first remesa (dup_etapa now reads the real status).
  Two-remesa tests need two different receipts.

- 2026-09-30: Clasica fix. Two defects confirmed (LLM-only mark; calculator quoted CUP for any
  card type; production: 6 clasica ops quoted in CUP). Migration 157 (commit 8d9ba3e, OpenCode;
  fixture fixed by me: tasas is a view): cerebro_destino_pendiente + cerebro_detectar_destino +
  cerebro_registrar_destino + BEFORE INSERT re-type trigger + USD branch for clasica/tropical in
  crm_calcular_monto_destino + pending cleared on close. Staging: RED→GREEN 5/5, rollback restores
  live md5s, related assertions unchanged with/without. Applied to staging. n8n: new node
  "Registrar destino auto" (dead-end branch from Snapshot final, top position so it runs first,
  onError continue). Published cbbd5642 (previous e8ef4342). Pending: live test.
  Not covered: backfill of the 6 production clasica ops quoted in CUP (decide before prod).

- 2026-09-30: Clasica live test on staging PASSED (exec 287988): "Seria en clasica" →
  Registrar destino auto returned 'clasica'; the LLM did NOT call marcar_destino_usd, yet the
  operation ended delivery_method=clasica, 153 USD, beneficiary clasica 153 USD, closing message
  "153 Clasica", pending row cleared on completion.

- 2026-09-30: Clasica fix DEPLOYED TO PRODUCTION with the user's explicit go-ahead. Pre-checks:
  production md5s of crm_calcular_monto_destino (29efa6e6…) and
  cerebro_reset_beneficiario_parcial_al_cerrar (564a943c…) equal staging's pre-157 ones; rb_type_chk
  already allows clasica/tropical. Applied 157 via apply_migration; all 5 function md5s equal
  staging's (verified independently). Production Cerebro jEzlVLCLUaJhVwzs: node "Registrar destino
  auto" added (credential Supabase Account), draft diff PASS (Hermes, spot-checked), published
  ada843d2 (previous 3b40ee12 for restore). The 6 older CUP-quoted clasica ops: corrected (see below).

- 2026-09-30: the 6 production clasica ops quoted in CUP were corrected with the user's go-ahead
  ("calculalos clasica"). All completed (2026-08-10..09-19), no calculator entries, deposits exact
  multiples of 260 GYD/USD (no USD rate existed in the system before 09-27): 80, 50, 110, 100, 40,
  90 USD. Operations: quoted_destination_amount/destination_currency USD; vigente beneficiaries
  re-typed cuban_card → clasica with the USD amount. Done inside one DO block with
  set_config('wacrm.origin','admin',true) (without it the 096 guard suppresses writes to locked
  fields); dry-run first via RAISE. Backup = the before-row JSON in remittance_admin_audit
  (action human_correction, reason mentions pre-157, 12 rows). Production now has 0 clasica ops in CUP.

## Next step
1.1 — design the direct operation/beneficiary write path (no deals) together with
cerebro_registrar_deposito, since the deposit function finds open deals by notes; then — rewrite `Contexto conversacion` (dup_etapa/dup_valor via receipts.comp_id → operation
status/amount; via_deposito_ya_usada via receipts.via; recarga_en_curso via operations timestamps),
staging parity check, byte-exact draft diff before publish.
