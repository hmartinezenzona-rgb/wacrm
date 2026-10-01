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
  - [x] WU1 operation-keyed money helpers: cerebro_saldo_envio / cerebro_objetivo_atar /
    cerebro_objetivo_cerrar get operation-id variants; deal-id versions delegate to them (absorbs
    Phase 3).
  - [x] WU2 receipt readers off notes: cerebro_cruzar_deposito(s), crm_verificar_deposito,
    crm_forzar_verificacion, crm_comprobantes_de_operacion read remittance_operation_receipts
    (+ add block_index to receipts first).
  - [x] WU3 cerebro_registrar_deposito without deals (movido/sumado/creado on operations,
    idempotency by receipts.comp_id); `id` returned = what 'Cruzar deposito con MMG' consumes,
    rewired together.
    - correction pass 1 done 2026-10-01: 160 fixed (D1 `v_ex` + the NULL-saldo hole, D2 `v_suma`,
      D3 `deal_id` mirror, and the `v_ya` prefix regression), applied to staging, committed
      `4039674` on `agent/hermes-work`. Evidence: `.briefs/WU3-hermes-fix1-report.md`.
  - [ ] WU4 beneficiary writer RPCs (card auto/tool, zelle auto/tool, reparto, marcar_destino_usd)
    on operations + beneficiaries, same inputs/outputs as today's node SQL.
    Recon 2026-10-01 (two read-only maps, both verified against live): the structured writers
    ALREADY EXIST and are already operation-keyed — `crm_agregar_beneficiario(p_operation_id,
    p_datos jsonb)` (123), `cerebro_aplicar_reparto(p_operation_id, p_reparto jsonb)`
    (127, redefined 129/130), `cerebro_aplicar_nombre_confirmado` (135),
    `cerebro_registrar_destino(p_conv, p_texto)` (157, with `cerebro_destino_pendiente` plus a
    BEFORE INSERT trigger that re-types the card rail), `cerebro_objetivo_atar_op(p_conv, p_op)`
    (158). So WU4 is NOT six RPCs from scratch: it is a deal-free operation creator plus thin
    node-contract adapters that resolve the operation, replace the notes-based update-vs-create
    decision with a structured one, delegate to those writers, and return the nodes' exact
    `accion` strings. Split:
    - [x] WU4a operation creator, deal-free: `cerebro_crear_operacion(p_conversation_id uuid,
      p_amount numeric DEFAULT 0, p_currency text DEFAULT 'GYD', p_stage_id uuid DEFAULT
      '96cd4fec-…') RETURNS uuid` (migration 161). Verified 2026-10-01: field-by-field parity
      against `INSERT INTO deals` + `trg_sync_operacion_al_crear_deal` (125) on the trigger's own
      columns — a minimal deal differs only in `id` and `deal_id`. Independent checks (not the
      writer's own test): `deals` 35→35 delta 0, new row `deal_id NULL / collecting_information /
      remesa / GYD / 0 / version 1`, account and conversation both matching the source, ACL
      `postgres=X | service_role=X` with no PUBLIC/anon/authenticated; `md5(live) == md5(file)` =
      `58b31f0025e73dbb7e0603cb0472a265`. Commit `bcc6cd7`.
      Honest gaps, measured not hidden: a *second* deal-keyed trigger,
      `trg_sync_z_benef_desde_deal` → `cerebro_sync_benef_trigger` (042/151), parses notes into
      beneficiaries and then `UPDATE remittance_operations SET delivery_method … WHERE deal_id =
      NEW.id`. A deal-free creator cannot reproduce that cascade — `delivery_method` NULL vs
      `cuban_card`, `version` 1 vs 2, `admin_locked_fields` {} vs populated, and 0 vs 1
      beneficiaries. That is exactly WU4b/WU4c's job (write the beneficiary rows structurally),
      and the assertion labels it `KNOWN GAP` rather than asserting it away. Also untested:
      the `completed`/`cancelled` arms, the NULL-contact guard, and concurrency (two creators on
      one conversation both write).
    - [x] WU4b card + zelle adapters (migration 162): `cerebro_registrar_beneficiario_auto`,
      `cerebro_gestionar_beneficiario`, `cerebro_registrar_zelle_auto`,
      `cerebro_registrar_beneficiario_zelle` — node argument order, `TABLE(id uuid, accion text)`.
      Verified 2026-10-01 on staging: 27 branches across the four nodes matched the old node SQL as
      sorted multisets of raw text, with accents, punctuation and trailing spaces significant
      (ins/upd/sin_cambio/ambigua for both card nodes; falta_nombre, falta_cuenta and the
      `+1 (469) 512-1137 → 4695121137` normalization for both zelle nodes). Beneficiary rows matched
      column by column, and every non-NULL id was confirmed to be a real operation of its own
      conversation. Independent parent checks: assertion re-run 27 PASS / 0 FAIL, and
      `md5(live) == md5(file)` for all four functions
      (`cerebro_gestionar_beneficiario ca234e9def…`, `cerebro_registrar_beneficiario_auto
      6d97a2bbe4…`, `cerebro_registrar_beneficiario_zelle 6a0139d6f4…`, `cerebro_registrar_zelle_auto
      379021dc04…`). Commit `af07d9d`. The RED/GREEN harness has a negative control: a stubbed wrong
      `accion` made it fail, so it is not vacuous.
      `crm_agregar_beneficiario` (123) could NOT be reused, verified in its body rather than from
      memory: it requires `amount > 0` plus a currency (else `22023`), enforces an `agent` caller,
      takes the admin lock, writes a `human_beneficiary_added` audit row and inserts
      `source='admin_addition'`. Node writes carry no amount and must stay `source='notes_parse'`, so
      reuse would raise on every call.
      Two divergences, named not hidden:
      1. `block_index` on the four `upd_no_tiene` cases: old `{2}` vs new `{1}`. Old was the block's
         index inside `deals.notes`; the new writers use the codebase's
         `coalesce(max(block_index),0)+1`. The rationale given in the writer's report ("no reader
         groups by it") is WRONG and I am recording the correct one: `042:166-175` and `098:211+` do
         read `block_index`, and `rb_unico_por_bloque(operation_id, block_index, position)` is a
         UNIQUE constraint. It is benign only because those readers belong to the notes-parse
         mechanism, which is deal-keyed and never fires for a deal-free operation, and because no
         `src/` code reads the column (grep: zero hits in `src/`). The rule is preserved, only the
         absolute starting value differs, and every comparison downstream is relative.
      2. `remittance_operations.delivery_method`: old `{cuban_card|zelle}`, new `{NULL}` in 23 cases.
         NOT inert — see WU4d.
    - [ ] WU4c reparto + destino adapters: `registrar_reparto_multiple` (10 args) and
      `marcar_destino_usd` (2). `marcar_destino_usd` must be migrated even though
      `Registrar destino auto` superseded it on the deterministic rail: it survives as an
      `ai_tool` on `Agente Remesas`, so leaving it means a live path still INSERTs `deals` and
      Phase 6 can never drop the table.
    - [ ] WU4d maintenance of `remittance_operations.delivery_method`, found by WU4b and owned
      before WU5. `042:207` sets it inside `cerebro_sync_beneficiarios` —
      `SET delivery_method = coalesce(lower(v_usd), v_tipo, o.delivery_method)` — which is part of
      the deal-keyed notes-parse mechanism, so a deal-free operation never gets it and ends up NULL
      where the old path produced `cuban_card` / `zelle`. That is not cosmetic: `097:175` reads
      `o.delivery_method` for the conversation-operations RPC, so the panel and the bot would see a
      different value for every operation created after WU5 ships. Also written by `098` (admin
      corrections) and by `157` (`cerebro_registrar_destino`). Needs a deal-free home for 042's
      derivation rule — either the writers set it directly, or a trigger on
      `remittance_beneficiaries` maintains it the way 157 already does for the card rail. Decide
      which, and prove parity against the old value on a notes-bearing fixture. Must land before
      WU5, because WU5 is what makes these writers live.
    Constraints found by recon (2026-10-01) — these are load-bearing, not commentary:
    - `cerebro_resolver_operacion(uuid, text[] DEFAULT NULL)` is LIVE-ONLY: absent from the
      working tree and from all reachable git history, with the drift documented at
      `097_operaciones_de_conversacion_rpc.sql:38-53`. The new RPCs must NOT depend on it —
      inline the `status` filter instead, or a repo-built environment breaks. The repo-visible
      1-arg form is `040_remittance_operations.sql:178`;
      `cerebro_resolver_operacion_beneficiario(uuid, text[], text)` is repo-visible at 133:23.
      MEASURED on staging 2026-10-01: the 1-arg form is not merely shadowed, it ERRORS —
      `42725 function public.cerebro_resolver_operacion(uuid) is not unique`, because the live
      2-arg overload carries one default and both are then admissible. The 2-arg and the
      `_beneficiario` forms both resolve fine. Nothing is broken today only because no live node
      calls the 1-arg form (the two rail nodes use `_beneficiario`, the four ai_tool nodes use the
      2-arg). Any new call written from the repo against `040:178` will fail at runtime, so treat
      that function as unusable and inline the filter.
    - `remittance_operations_status_chk` (verbatim): collecting_information, awaiting_deposit,
      deposit_received, deposit_verification, ready_to_transfer, transferring, completed,
      incident, cancelled.
    - `remittance_beneficiaries`: 20 columns; NOT NULL is only operation_id, beneficiary_type,
      position (default 1), status (default 'vigente'), source (default 'notes_parse'),
      created_at. UNIQUE `rb_unico_por_bloque(operation_id, block_index, position)`.
      `rb_type_chk`: cuban_card|zelle|clasica|tropical|multiple_distribution|efectivo_usd.
      `rb_status_chk`: vigente|reemplazado. FK operation_id → remittance_operations ON DELETE
      CASCADE.
    - `ENTREGA EN USD: …` is a delivery-method marker, never a beneficiary row — the 042 parser
      only ever emits cuban_card, zelle and multiple_distribution.
    - `remittance_operations` has NO FK on deal_id, account_id or conversation_id. A wrong id
      therefore does not raise: it writes a row nothing reads. Every adapter needs its own
      "did I actually land on an operation" check; a constraint will not save us.
    - Node wiring (live graph, entry `Webhook WaCRM`): only `Registrar beneficiario auto` and
      `Registrar zelle auto` are on a deterministic rail (`Beneficiario completo?`, `Zelle
      completo?`). `gestionar_beneficiario`, `registrar_beneficiario_zelle`,
      `registrar_reparto_multiple` and `marcar_destino_usd` have no inbound `main` edge at all —
      they fire only when the model calls them as `ai_tool`s on `Agente Remesas`.
      `Registrar destino auto` is the already-migrated template for the target shape:
      `SELECT cerebro_registrar_destino($1::uuid, $2::text) AS destino`.
    - Full per-node contract (verbatim SQL, argument bindings, notes markers, complete `accion`
      value sets) and the DB contract: `agent-shared/reports/wu4-n8n-writers.md` and
      `agent-shared/reports/wu4-db-side.md`.
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

- 2026-09-30: WU1 done on staging: migration 158 (commit a7cf4b8; written by OpenCode, fixtures
  fixed by me). operation_id on depositos_mmg and cerebro_objetivo_envio (trigger on deal_id +
  backfill); cerebro_saldo_operacion / cerebro_objetivo_atar_op / cerebro_objetivo_cerrar_op; deal
  versions delegate. Evidence: RED (column missing) -> GREEN 5/5; rollback restores the 3 live md5s;
  related assertions identical with/without (deposit-review fails both ways, pre-existing); saldo of
  all 24 staging deals identical before/after. Applied to staging. Production: not yet.

- 2026-09-30: WU2 done on staging: migration 159 (commit dd3fc56; written by Hermes, assertion bugs
  fixed by me). Hermes found that only crm_comprobantes_de_operacion READS receipts from notes;
  cerebro_cruzar_deposito(s), crm_verificar_deposito and crm_forzar_verificacion only WRITE notes
  (Phase 4). 159 adds block_index to receipts (backfilled) and makes the panel RPC read
  remittance_operation_receipts, the operation status and depositos_mmg.operation_id. Evidence: RED
  -> GREEN 2/2; rollback restores the live md5 and grants; panel RPC output identical for all 24
  staging operations (per-account auth); deposit-review back to its 2 pre-existing failures after its
  fixture writes the receipt row like the bot. Note: can_verify still requires a deal (verification
  RPCs are deal-bound until WU3/Phase 4). Applied to staging. Production: not yet.

- 2026-09-30: **WU3 started, interface frozen before any code** (my decision; workers implement
  it). `cerebro_registrar_deposito` keeps its signature, its OUT column names
  (`deal_id, accion, es_revendedor, sumado`) and its four `accion` strings byte for byte, but the
  first column now carries the **operation id**; `cerebro_cruzar_deposito(s)` accept **either** an
  operation id or a legacy deal id through a small resolver. Reason: `cerebro_cruzar_deposito`
  takes `p_deal` and looks the operation up by `deal_id`, so changing what
  `cerebro_registrar_deposito` returns without migrating its consumer in the same unit is exactly
  the silent-failure trap this plan warns about (no FK to `deals` anywhere). With the pair
  migrated together the n8n node needs **no edit** in this unit — which matters because this
  session has no n8n MCP connected.
  Blast radius confirmed before delegating: **only n8n calls `cerebro_registrar_deposito`**; there
  is no SQL caller outside the staging assertions.
  Delegation: Hermes (heavy) = migration 160 + assertion + ROLLBACK + the (a)-(g) mapping;
  OpenCode (light) = read-only caller/contract map. Briefs kept outside the repo at
  `/home/onlinefreedom/wacrm-worktrees/.briefs/WU3-{hermes,opencode}.md`; working copies
  `agent-hermes` / `agent-opencode`; I verify, commit and ff-merge.

- 2026-10-01: **WU3 correction pass 1 verified by me** (Hermes died twice on provider quota, so I
  closed it myself). Staging was never mutated — every check ran in `BEGIN; … ROLLBACK;`. Method:
  one fixture set driven against three bodies in the same transaction (live 156, the rejected 160
  from `odd/backups/wu3-staging-160-defectuosa-20260930-214930.sql`, and the corrected 160).
  Verified: D1 (`v_ex` beneficiary guard), D2 (`v_suma` genuinely unreachable in the rejected body —
  `creado` on the exact fixture where the fixed body returns `sumado al envio abierto`), D3
  (`deposit-review` case 4 red on the rejected body, green now), and **two defects the brief did not
  list**: (1) `v_ex`'s `NOT (beneficiary AND saldo>0)` evaluated to NULL when the operation had no
  objetivo, re-creating the phantom second remesa — fixed with `COALESCE(…, 0)`, witnessed by
  `ops_after=2 → 1`; (2) `v_ya` compared the receipt's `comp_id` (`'COMP-'||comp`) against the bare
  `p_comp_id`, so idempotency never matched on the real flow while 156's `notes LIKE` did — fixed by
  keeping the substring arm. Sweep: `deposit-path-without-deals` 6/6, `registrar-deposito-creado`
  3/3, `operation-receipts` 6/6 (was 3 FAIL on 156, 2 on the rejected body),
  `deal-insert-creates-operation` 1–4 all pass, `deposit-review` back to its **2 pre-existing
  failures** (cases 3 and 8d, identical on 156 — they assert a `deals` UPDATE notify payload that a
  deal-free path must not emit; they belong to WU5/WU6, not weakened here). `ROLLBACK-160` re-proven
  byte-exact: restores `1b095ebe…`, `565a6adc…`, `2a30bb22…` and drops `cerebro_resolve_op_id`.
  Hermes' config was also repaired this session (`model.default` was `auto` advertising a 1048576
  window while the router served 262144, plus `compression.enabled: false`).
  **Delivered**: corrected 160 applied to staging in one transaction (`ON_ERROR_STOP`, `-1`), and
  proven byte-for-byte live — LIVE and FILE md5s agree on all four functions
  (`cerebro_registrar_deposito = 314abaa05f78f4c48ad141ee38c772ed`, `cruzar_deposito =
  5c70475480f24b46e1bab0945be21a1d`, `cruzar_depositos = 694875ca67f75b889eb19bce31aa1519`,
  `resolve_op_id = 49ede272ed6708e43352024b9093984a`). Pre-160 staging backed up to
  `odd/backups/wu3-staging-pre-160-20261001-055820.sql`. Regression sweep re-run against live
  staging: `deposit-path-without-deals` 6/6, `registrar-deposito-creado` 3/3, `operation-receipts`
  5/5, `deal-insert-creates-operation` 1–4, `deposit-review` 2 pre-existing failures (cases 3, 8d).
  Committed `4039674` on `agent/hermes-work`. **ff-merge into
  `feat/port-chat-operations-calculator` done — rebased onto 8daf4e0 first so it was a true fast-forward (SHA moved 8eb227a → 4039674).**

## Next step
1. WU4 — beneficiary writer RPCs on operations + beneficiaries.
2. WU5 — rewire the 7 n8n nodes one by one; **blocked in this session**: the n8n MCP connector is
   not available, so reading/publishing workflows has to be re-enabled (or done from the user's
   own session) before this unit can start.
3. WU6 — stage-based notifiers/alerts → status. Same n8n-access caveat.
