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
         Investigated as WU4d and closed without a change — see below.
    - [x] WU4c reparto + destino adapters: `registrar_reparto_multiple` (11 args) and
      `marcar_destino_usd` (3). Delivered `15e956d`, rebased and ff-merged as **`10bbd38`**.
      Files: `163_reparto_destino_node_adapters.sql`, its ROLLBACK, and
      `assertions/reparto-destino-node-adapters.sql`.
      `marcar_destino_usd` had to be migrated even though `Registrar destino auto` superseded it on
      the deterministic rail: it survives as an `ai_tool` on `Agente Remesas`, so leaving it meant a
      live path still INSERTing `deals` and Phase 6 could never drop the table.
      Functions: `cerebro_registrar_reparto_multiple(uuid, 10×text)` and
      `cerebro_marcar_destino_usd(uuid, text, text)`, both `TABLE(id uuid, accion text)`, params in
      the node's exact `$1..$n` order. `marcar` is written procedurally, not as a chain of CTEs: in
      a `WITH` every sub-statement shares one snapshot, so the `UPDATE` cannot see the row
      `cerebro_crear_operacion()` just inserted. The harness caught that as `ins_clasica`
      (old `{clasica}` / new `{<NULL>}`) — a good example of the harness earning its cost.
      Parent verification, independent of the writer's run: harness re-run **22 PASS / 0 FAIL**
      plus the one intentional FAIL from the negative control; `md5(live) == md5(file)` for both
      functions (`cerebro_marcar_destino_usd 9f779e60d4…`,
      `cerebro_registrar_reparto_multiple f6ba198eec…`).
      **A failure mode worth recording, because it nearly produced a false pass:** my first md5 run
      passed the HOST path (`/tmp/…`) to psql running inside the container, where that path is not
      mounted, and I had redirected stderr to `/dev/null`. Both sides came back empty and `diff`
      dutifully printed "IDÉNTICO". An empty diff is not proof — assert the evidence is non-empty
      before comparing it. Same shape as the vacuous-harness problem the negative control exists to
      prevent, one level up.
      Harness honesty check (I read the comparison function, not just its output): it has exactly
      two carve-outs, each used by exactly one case — `p_allow_block_diff` on `upd_no_tiene` and
      `p_allow_accion_diff` on `divergencia_ya_tipado` — and each still requires the NULL pattern,
      the operation counts, the beneficiary rows and `delivery_method` to match exactly. The
      `p_stub` negative control proves the comparison is not vacuous. So 22 PASS is a real 22.
      **OPEN USER DECISION — the only user-visible divergence in the feature.**
      `marcar / divergencia_ya_tipado`: when the rail was already typed by 157 with no notes marker,
      the old node replies `destino marcado: entrega en USD por Clasica` and the new function
      replies `sin cambios: ese destino ya estaba marcado`. Database state is identical; the text
      the customer sees is not. The new text is arguably the more truthful of the two. Reverting it
      is a one-line change in 163. This must be settled before the **production** rewire (WU5b), not
      before WU5a — staging is where we find out whether it matters.
      Reuse decisions: `cerebro_aplicar_reparto` (127/129/130) NOT reused — its contract is stricter
      (exact sum, mobile regex, row type, beneficiary lock, jsonb). `cerebro_registrar_destino`
      (157) NOT reused — the node has its own rail rules, no lock check of its own, and creates a
      new remesa where 157 applies nothing. `cerebro_crear_operacion` (161) and
      `cerebro_registrar_derivacion` were reused. The 157-vs-node contradiction was resolved by
      reproducing the NODE (WU5 depends on the node's observable output), and the 096 admin guard
      was measured with a real human-written lock: it suppresses the old trigger's write, the new
      function's write and 157's write identically.
      "this turn" resolves to one n8n execution (`$execution.id`) through
      `tool_execution_log.idempotency_key` UNIQUE (044:15); the key the function builds is identical
      to the node's, so the dedupe scope does not change. The notes never participated in it.
      Writer self-corrected mid-unit: a draft asserted Efectivo was "no rail", but `151:65/77` maps
      `ENTREGA EN USD: Efectivo` to the literal `'efectivo_usd'`, not `'efectivo'`. Now covered by
      `ins_efectivo`, `upd_efectivo` and `sin_cambio_efectivo`.
      Writer's honest "not verified": no real n8n execution (node SQL copied from the frozen
      contract), no PostgREST HTTP call, no concurrency test, no human-actor path through the
      function, no statuses outside the 4-filter except `awaiting_deposit`, no re-run of the earlier
      units' assertions, and no real rewire. WU5a owns the first and the last of those.
    - [x] WU4d `remittance_operations.delivery_method` — INVESTIGATED 2026-10-01 AND CLOSED WITH NO
      CODE CHANGE. It does not need a deal-free home. The gap opened by WU4b is real as a
      *difference* (old `{cuban_card|zelle}`, new `{NULL}` in 23 cases) but it is not a defect: the
      column is already stale-or-NULL on live deal-based operations today, and two earlier
      migrations were written specifically to route around that.
      Evidence, each claim verified by the parent against the file, not taken from a report:
      - `141:94-110` — `calculator_resolve_operation_service(p_operation_id, p_delivery_method)`
        reads the beneficiaries FIRST and consults the column only when there are ZERO `vigente`
        beneficiaries; one shared `beneficiary_type` maps through it, mixed types resolve to NULL.
        Its own `COMMENT` at `141:113-120` states the intent outright: "so the stale
        delivery_method column can never override a real current beneficiary." The calculator is
        already independent of the column.
      - `remittance-operation-card.tsx:196-206` — the front-end comment says the column "is set
        only by the legacy notes trigger with an arbitrary `LIMIT 1` and is never touched by the
        reparto/add-beneficiary RPCs, so it can be stale or null even for a live Zelle operation".
        That is the panel already treating it as unreliable ON THE DEAL PATH, before we touched
        anything. `isZelleOperation` (`:207-212`) branches on `beneficiaries.length > 0` and falls
        back to the column only for the legacy shape with no beneficiaries yet. Tests pin both
        shapes (`:813-857`, legacy shape at `:604-611`).
      - `120:53` → `aged-operations-queue.tsx:52-55` falls back to `destination_currency`; `153:110`
        degrades to a coarser quote rather than a wrong one.
      - The only hard SQL reads are `150:191` and `151:148`, which filter
        `delivery_method = 'efectivo_usd'` — PREEXISTING and unrelated to this feature: no deal-free
        writer produces that value (`162` writes only `cuban_card`/`zelle`), so deal-free cash
        delivery was already unhandled before WU4b. Not WU4d's to fix and not caused by it.
      - `157:208-212` still writes the column and survives the deals removal (it is keyed by
        conversation, not by deal), so the destino flow keeps populating it.
      - Question F, answered: the column's only non-derivable information was the rail during the
        notes window (`clasica`/`tropical` while the beneficiary still read `cuban_card`), and
        `157:202-206` already moves that into `beneficiary_type`.
      CORRECTION OF AN EARLIER CLAIM IN THIS DOCUMENT: I first recorded this as "not cosmetic:
      `097:175` reads `o.delivery_method`, so the panel and the bot would see a different value".
      That was wrong. `097:175` does read the column and does carry it to the client, but the
      client does not trust it — the card branches on beneficiaries first and only consults it for
      the legacy no-beneficiary shape. Reading the column is not depending on it; I conflated the
      two. Residual exposure is therefore limited to an operation with NO beneficiaries yet whose
      rail was set by deal-path notes — a transient shape that 157 still covers for the rail it
      owns.
      Consequence for the plan: WU5 carries no delivery_method obligation, and no unit between here
      and Phase 6 does either. Recorded so nobody re-opens it from the WU4b report alone.
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
  - [x] WU5a rewire the n8n nodes on the **STAGING twin** — DONE `9a9d23e`. **SIX nodes, not seven**
    (correction from the unit itself): only `Registrar beneficiario auto`, `Registrar zelle auto`,
    `gestionar_beneficiario`, `registrar_beneficiario_zelle`, `registrar_reparto_multiple` and
    `marcar_destino_usd` still wrote `deals`. `Registrar deposito auto` never did — it was already
    deal-free and was not touched. Also corrected: `cerebro_registrar_deposito` returns
    `TABLE(deal_id, accion, es_revendedor, sumado)`, NOT `TABLE(id, accion)` like the other six.
    Target: `[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1` (`U52y1kSNvhgxvWeb`), `versionId`
    `cbbd5642-…` → `06d3e4bf-…`. Production `jEzlVLCLUaJhVwzs` never received a single request.
    Parent verification, run directly against the live n8n API, not taken from the report:
    - A canonical per-node diff (before/after, `jq -S` so keys are order-independent) shows
      **exactly 6 nodes** changed, all six expected ones, and nothing else.
    - `connections`, `settings`, and the node name/order/type/position list are all byte-identical.
      `active` stayed `true`.
    - Production's `updatedAt` is still `2026-09-30T21:58:52` (yesterday) while staging's moved to
      today — independent confirmation that the forbidden workflow was untouched.
    - **The load-bearing safety fact:** no expression anywhere in the workflow reads the output of
      any of the six (`$('Nodo')` inventory returns NONE of them). That is what makes it safe that
      the returned `id` changes meaning from `deals.id` to `remittance_operations.id`. Contrast
      `Cruzar deposito con MMG`, which does read `$('Registrar deposito auto')…id` — an untouched
      node.
    - `deals` count in staging: 35 before and after. Exercised end-to-end through the real webhook
      (executions 294201 and 294209) for the two rail nodes; the other four are pure `ai_tool`s with
      no inbound `main` edge and were exercised only by direct node execution, correctly labelled as
      such.
    - A method note, mine again: my first blast-radius diff reported 119 changed nodes. That was an
      artifact — `tojson` does not honour `-S`, so I was comparing key order, not content. The
      canonical diff gives 6. Same family as the empty-md5-diff trap above: check that the
      comparison method is sound before believing its number, in either direction.
    One operational hiccup, correctly handled: the first PUT via `python-urllib` was rejected by
    Cloudflare (403 `error 1010 browser_signature_banned`) **before** reaching n8n — the workflow
    was still on the old SQL, so nothing partial landed. The identical body was re-sent with
    `curl`. No blind retries, no second target.
  - [ ] WU5b rewire the **production** workflow `jEzlVLCLUaJhVwzs`. **USER-GATED — do not start
    without an explicit go-ahead.** Requires deploying 160/161/162/163 to the production database
    first; rewiring before that makes seven live paths call functions that do not exist there. Two
    open decisions ride with it: the production go-ahead itself, and the `divergencia_ya_tipado`
    reply text recorded under WU4c above.
  - [ ] WU6 the **live staging catalog** was audited on 2026-10-01 and the real remaining scope is
    **3 views + 13 functions**, not the earlier guess of "090, 114 notify_*, 136 avisos, 052, 096".
    Reconciled against `pg_depend` / `pg_proc.prosrc` / `pg_get_viewdef`, not against migration text:
    - **Views (hard DDL blockers — Postgres refuses `DROP TABLE deals` while they exist):**
      `cerebro_historial_operaciones`, `cerebro_volumen_diario` (both `LEFT JOIN deals d ON d.id =
      o.deal_id`) and `cerebro_conciliacion_operaciones`, which is worse — it has `deals` as its
      **primary `FROM`**, not merely a join. All three are defined in `114`.
    - **Functions (live body references `deals`; authoritative = highest migration that defines it):**
      `cerebro_avisar_envios_incompletos`, `cerebro_avisar_envios_sin_beneficiario`,
      `cerebro_avisar_remesas_abiertas_viejas` (`136`); `cerebro_sync_beneficiarios` (`098`);
      `merge_duplicate_contacts` (`022`); `crm_comprobantes_de_operacion` (`159`);
      `crm_verificar_deposito`, `crm_forzar_verificacion`, `notify_operation_incidencia` (`114`);
      `crm_entregar_operacion` (`143`); `cerebro_aplicar_nombre_confirmado` (`135`);
      `cerebro_saldo_envio` (`158`, and it is `LANGUAGE sql`, so unlike the plpgsql ones it **does**
      create a parse-time dependency and blocks the DROP by itself).
    - **`sync_tags_cliente(uuid)` has NO defining migration** — the identifier appears in exactly one
      file, `065_revoke_rpc_wacrm_tanda_c.sql`, and only inside a `REVOKE` list. Its live body exists
      in the database with no migration behind it, so it cannot be "edited in place": its body has to
      be captured from the catalog first. Unaccounted-for objects like this are exactly why the
      scope is now taken from the catalog rather than from the repo.
    - **`notify_deal_incidencia` exists live but no trigger references it** (`pg_trigger` returns
      zero rows for it) — the 090 question resolves to a dead function; only an optional
      `DROP FUNCTION` remains, and it is a casualty of the table drop, not work.
    - **Method note (a trap already sprung twice this feature):** a first pass at this same query
      returned *empty* for both "views referencing deals" and "functions referencing deals", because
      a regex (`~* '\mdeals\M'`) did not survive nested heredoc quoting. Taken at face value that
      empty result would have said "WU6 is already clean" — the opposite of the truth. The query was
      re-run from a file with `LIKE` and every result set asserted non-empty before being believed.
      An empty diff is not proof.
    - **Per-object disposition** (read-only mapper, repository evidence; live-shape claims
      re-verified by the orchestrator against the catalog where they were load-bearing):
      - `cerebro_historial_operaciones` / `cerebro_volumen_diario` — used only for
        `coalesce(o.quoted_source_amount, d.value, 0)`. Drop the LEFT JOIN; the partial UNIQUE index
        `remittance_operations_deal_uk` (`040:78-79`) makes it at most 1:1, so rows and columns are
        unchanged. Only NULL-`quoted_source_amount` rows lose a legacy fallback.
      - `cerebro_conciliacion_operaciones` — **no clean deal-free equivalent**: `deals` is the
        driving `FROM` of branch 1 and every row of all three branches touches it. It is an internal
        drift-audit over the deal↔operation bridge; that bridge ceases to exist. **Product decision.**
        Nothing in `src/` or any DB object consumes it **by DDL**; the only DDL-dependent object of
        the three views is `cerebro_resumen_volumen` reading `cerebro_volumen_diario` (verified in
        the catalog). Other readers are plpgsql RPCs, invisible to `pg_depend` — hence the grep.
      - `crm_comprobantes_de_operacion` (`159`) — `v_stage_id` is assigned and **never read again**;
        pure deletion. The `cerebro_saldo_envio`/`depositos_mmg.deal_id` swaps go to
        `cerebro_saldo_operacion`/`.operation_id` (verified: **identical return shape**
        `TABLE(objetivo, depositado, saldo, moneda)`, exactly one row, on the live catalog).
      - `crm_entregar_operacion` (`143`) — the deal lock is already `IF v_deal_id IS NOT NULL`; delete
        the block. No observable change.
      - `merge_duplicate_contacts` (`022`) — delete the `UPDATE deals` line. Flagged separately,
        **pre-existing and not caused by this feature**: the function re-points many tables to the
        surviving contact but never `remittance_operations.contact_id`, and it `DELETE`s the absorbed
        contacts (`022:100`).
      - `cerebro_avisar_remesas_abiertas_viejas` (`136`) — already operation-driven; drop both LEFT
        JOINs. Only the stage label and the legacy amount fallback in the message text disappear.
      - `cerebro_avisar_envios_incompletos` / `cerebro_avisar_envios_sin_beneficiario` (`136`) —
        re-key onto `remittance_operations`. **These change behaviour**: the `cerebro_alertas.clave`
        dedup key is `'envio_incompleto:'||d.id` / `'sin_beneficiario:'||d.id` and must be re-keyed to
        the operation id, or alert dedup breaks. `sin_beneficiario` already INNER JOINs
        `remittance_operations ON o.deal_id = d.id`, so its row set is essentially preserved.
      - `cerebro_saldo_envio` (`158`) — `LANGUAGE sql`, hence a hard DDL blocker by itself. Its
        deal-free twin `cerebro_saldo_operacion` already exists in the same migration.
      - `cerebro_aplicar_nombre_confirmado` (`135`) — the `deals.notes` append is the *transport* the
        sync trigger parsed; it must repoint to the 162 structured writers. `accion` strings must stay
        byte-identical.
      - `cerebro_sync_beneficiarios` (`098`) — signature is `(p_deal_id uuid)`: the whole input key
        disappears. It cannot be "made deal-free", only **retired** once its two callers
        (`trg_sync_z_benef_desde_deal` `043:89`, `trg_sync_operacion_al_crear_deal` `125:61`) are gone.
      - `notify_operation_incidencia` (`114`) — **named gap.** `remittance_operations` has no
        free-text reason column; the read supplies the MOTIVO line and otherwise falls back to a
        generic string. The alert already fires deal-free. **Product decision.**
      - `sync_tags_cliente` — **cannot be analysed from the repository**: no migration defines it, so
        its body exists only in the database. **CORRECTION OF AN EARLIER CLAIM IN THIS DOCUMENT:** an
        earlier draft here said its `deals` mention was probably a comment false-positive, like the
        ones that put the 163 functions on the sweep list. That was wrong, and the catalog disproves
        it directly — its live body contains the real statement line
        `from deals d` (verified by extracting its non-comment lines). It genuinely queries `deals`,
        and it has two active n8n callers (`Reconciliar etiquetas` in both the production and staging
        `Remesas - Cierre automatico de solicitudes zombis`). So it is neither dead nor a false
        positive; it is real work whose body must be captured from the catalog first.
        *Method note:* the catalog, not the grep count, is what settled this — and it settled it in
        the opposite direction from the guess. Distrust the guess in both directions, not just the
        flattering one.
    - **The strongest functional finding, and it is latent rather than reproducing:** both
      `crm_verificar_deposito` (`114:1153-1155`) and `crm_forzar_verificacion` (`114:1308-1310`) do
      `IF v_deal_id IS NULL THEN RAISE EXCEPTION 'operation has no linked deal' USING ERRCODE =
      '22023'` — verified verbatim in the file. So a deal-free operation **cannot be deposit-verified
      or force-verified from the panel**. It does not reproduce today because staging currently holds
      **0** operations with `deal_id IS NULL` (all 34 are legacy, deal-linked) — every WU4 assertion
      ran inside a rolled-back transaction. It will fire the first time a deal-free operation
      persists, which is exactly what the cutover produces. Report it as reachable-and-pending, not as
      an observed failure.
    - **n8n sweep — all 151 workflows fetched individually and grepped (0 failures, GET-only).**
      Twelve of the seventeen identifiers had **zero hits** across every workflow, node parameter,
      node name, note, `pinData`, `staticData`, `connections`, workflow name and description —
      including partial-name probes (`verificar_deposito`, `volumen_diario`, …). The three views are
      in that zero set, so **no live workflow reads them**: redefining them cannot break a node, and
      the only DDL-side consumer to respect is the one view found above (`cerebro_resumen_volumen`).
    - **But n8n does call six of the functions, from ACTIVE workflows — so they are behaviourally
      live, not dead code:**
      - `cerebro_avisar_envios_incompletos()` ← `Vigilante - envios incompletos` (`O1TqpAJXgRfKCiW6`)
      - `cerebro_avisar_envios_sin_beneficiario()` ← `Vigilante - envios sin beneficiario`
        (`I2qKK76f8Tp9eo16`)
      - `cerebro_avisar_remesas_abiertas_viejas()` ← `Vigilante - remesas abiertas viejas`
        (`4ptJpwWnjkyiAjvc`)
      - `cerebro_cruzar_depositos(...)` ← `Cruzar deposito con MMG` in **both** `jEzlVLCLUaJhVwzs`
        (production) and `U52y1kSNvhgxvWeb` (staging)
      - `sync_tags_cliente(c.id)` ← `Reconciliar etiquetas` in `Remesas - Cierre automatico de
        solicitudes zombis`, **both** `K6EpIX4lSJLGMJN7` (production) and `2CECGodU0oj85hMJ`
        (staging). **This is the caller that was missing:** `sync_tags_cliente` is not dead, it is
        called by two active workflows, so its body must be captured from the catalog before it can be
        touched. `cerebro_sync_beneficiarios` and `notify_operation_incidencia`, by contrast, have
        **zero call-form hits** — n8n only names them in comments.
    - **New scope this sweep surfaced — active n8n workflows that still run `deals` SQL, beyond the
      six nodes WU5a rewired.** These are Phase 6 blockers and were not on any earlier list:
      - `bTwsEJsmoAzsuOxm` `Vigilante - depositos sin cruzar` — `FROM deals d JOIN conversations …`
      - `K6EpIX4lSJLGMJN7` (prod) + `2CECGodU0oj85hMJ` (staging) `Remesas - Cierre automatico de
        solicitudes zombis` — `UPDATE deals SET status = 'lost', notes = …`
      - `wGud0KGR6eMqqfMQ` (prod) + `OCdJoHTkV6S0aAdk` (staging) `WaCRM - Notificar cliente por etapa
        del deal` — `Leer secreto` reads `(SELECT d.notes … JOIN deals d ON d.id = o.deal_id)`, and
        its code node branches on `b.table === 'deals'`. The workflow is literally named for the deal
        stage it notifies on.
      - Confirms WU5a landed as intended: `U52y1kSNvhgxvWeb` now has **zero** real `deals` SQL — the
        only hits are a CTE alias named `deals_cli` (×3) and one comment. `deals_cli` is the
        false-positive that would make a naive count look wrong in both directions.
    - **Counts worth distrusting:** the sweep found 151 workflows, not the ~143 an earlier listing
      suggested, and it classified `deals` hits by form (`FROM`/`UPDATE`/`INSERT` vs CTE alias vs
      prose) rather than by raw count — the same discipline the md5 and 119-node errors taught.
    - **USER DECISION 2026-10-01: `cerebro_conciliacion_operaciones` is DROPPED, not rewritten.** It
      audited drift across a bridge the feature is deliberately removing; keeping it would mean
      auditing something that should no longer exist, and nothing consumes it. Recorded as a decision,
      and it is reversible only by writing new work — there is no port to fall back to.
  - [ ] **WU6 is 16 objects, so it is split. Slice plan, in dependency order:**
    - [x] **WU6a DONE `31cc878`** (staging; parent-verified against the live catalog, not taken on the
      writer's word). The views and the no-observable-change edits: `cerebro_historial_operaciones` and
      `cerebro_volumen_diario` (drop the LEFT JOIN → `coalesce(o.quoted_source_amount, 0)`),
      `cerebro_conciliacion_operaciones` (DROP, per the decision above), `merge_duplicate_contacts`
      (delete the `UPDATE deals` line), `crm_entregar_operacion` (delete the guarded lock),
      `cerebro_avisar_remesas_abiertas_viejas` (drop both LEFT JOINs), `cerebro_saldo_envio` (DDL
      replace — `LANGUAGE sql`, so it must become a **wrapper** over `cerebro_saldo_operacion`, not
      be deleted: its other caller in `136` does not move until WU6c). Property that makes this slice
      safe: **every object in it either changes nothing observable or is dropped with no consumer.**
      Must be verified, not assumed — especially that `cerebro_resumen_volumen` still compiles and
      returns the same columns, and that the `cerebro_saldo_envio` wrapper returns the same values as
      the body it replaces for every deal-linked operation.
      - **Verification evidence (re-run by the parent, not quoted from the report):** the unit's own
        assertion harness, executed by the orchestrator inside `BEGIN; … ROLLBACK;`, prints
        `ALL PASS` — 21 PASS / 2 NOTE / 0 FAIL. Independently re-derived by the orchestrator from the
        catalog: **0** views still reference `deals`; **12** functions have a live (non-comment) line
        touching `deals`, of which **3** are the deal-trigger functions that die with the table, so
        exactly **9** real ones remain — matching the writer's claim and the harness's own
        `exactly nine functions still reference deals`. `cerebro_resumen_volumen` compiles and
        returns 5 rows. `cerebro_saldo_envio` is still `LANGUAGE sql`, no longer mentions `deals`, and
        delegates to `cerebro_saldo_operacion`. Commit carries no AI attribution.
      - **One declared deviation, and it was the right call:** the writer did **not** apply the
        brief's `REVOKE … FROM authenticated` template to `crm_entregar_operacion`, because the live
        ACL grants EXECUTE to `authenticated` (the panel calls it) — templating it verbatim would have
        been a real permission regression. The parent verified the live ACL is preserved
        (`postgres`, `service_role`, `authenticated`). The brief was wrong to template it; the unit
        caught it, which is exactly the behaviour §5 asked for.
      - **One user-visible text change, expected and shown:** the `Vigilante - remesas abiertas
        viejas` alert message loses its `(etapa)` label — observed before `…abierta hace 0 dias (Por
        verificar)`, after `…abierta hace 0 dias`. Rows, `cerebro_alertas.clave` and `avisos_creados`
        are unchanged. Unlike `divergencia_ya_tipado` this is an internal admin alert, not
        customer-facing, but it is the second visible-text change in the feature and is recorded here
        rather than left in the report.
      - **Honest gaps, carried forward rather than buried:** (a) `crm_entregar_operacion`'s
        `FOR UPDATE` on the deal now only runs for deal-linked rows — the lock existed to order
        against legacy n8n writes to `deals.notes`/`deals.value`. Removing it is safe **only if
        nothing concurrent writes the same deal row**, and that assumption was *not* verified: n8n was
        out of scope for this unit, and the earlier sweep shows active workflows **do** still write
        `deals`. The safety is argued, not measured. (b) No real duplicate-contact merge was executed
        (unreachable: 0 duplicate groups + the partial UNIQUE index). (c) The alert was re-run on a
        fixture, not the full live population, and the consumer that renders the alert text was not
        checked for tolerance of the missing label.
    - **WU6b — enable deal-free operations.** `crm_comprobantes_de_operacion` (delete the dead
      `v_stage_id` read, then repoint `cerebro_saldo_envio`→`cerebro_saldo_operacion` and
      `depositos_mmg.deal_id`→`.operation_id` — its `IF v_deal_id IS NOT NULL` guard currently makes a
      deal-free operation return NULLs, so this slice **does** change observable output, for the
      better), plus `crm_verificar_deposito` and `crm_forzar_verificacion` (remove the
      `operation has no linked deal` guard). This is the highest-value slice — it is the fix for the
      latent blocker above — and its acceptance test is the first genuine exercise of a deal-free
      operation end-to-end. `crm_comprobantes_de_operacion` is here rather than in WU6a precisely
      because it does not satisfy WU6a's no-observable-change property.
      - **Scope correction before the first write (orchestrator error, third of the feature).** The
        first WU6b brief carried a self-contradiction: §3 orders every `UPDATE deals SET notes …`
        write kept (live n8n workflows read `deals.notes`), while the exit criterion demanded the
        deals-referencing set shrink 9 → 6 — which requires those very writes to be gone. The writer
        stopped before writing anything and measured it. Confirmed independently on the live catalog:
        `crm_verificar_deposito` holds 3 live deals lines (one being the notes write) and
        `crm_forzar_verificacion` 2, so under §3 both **cannot** leave the set.
      - **Resolution — §3 wins; exit criterion corrected to 9 → 8.** Only
        `crm_comprobantes_de_operacion` leaves the set. `crm_verificar_deposito` and
        `crm_forzar_verificacion` keep their deal-linked writes untouched and *remain* deals-referencing
        for now; that is the correct outcome, not a shortfall. They become fully deal-free only after
        the live n8n readers of `deals.notes` are retired (`Leer secreto` in `WaCRM - Notificar cliente
        por etapa del deal`; `Historial contacto` and `Contexto conversacion` in production `Cerebro
        v2`) — a **carried dependency**, deliberately sequenced later, not a gap in this slice.
      - **DONE and parent-verified** — commit `1039546` (3 files, +1319), branch
        `feat/port-chat-operations-calculator`. The latent blocker is closed: a genuinely deal-free
        operation (built by the `161` path, `deal_id IS NULL`) now verifies from the panel end to end —
        `crm_verificar_deposito` returns `verificado`/`ready_to_transfer`, `crm_forzar_verificacion`
        returns `{"new_status":"ready_to_transfer"}`, both write their `remittance_admin_audit` row,
        and the panel read gives `can_verify:true` with one consumed deposit. RED was captured first
        (both RPCs raised `22023 operation has no linked deal`). Deal-linked equality held across all
        12 captured values with **zero diff**, including the `deals.notes` text. No `deals` row created
        by any path (35 → 35).
      - **Verification of record.** Native `assess` over the writer's diff: `risk: medium`
        (`executable_change`). RDD is off, the writer ran on sonnet (not a mini profile), so writer
        self-verification suffices and no separate verifier was required; the parent spot check ran
        anyway. The parent re-ran the assertion harness wrapped in `BEGIN; … ROLLBACK;` → **ALL PASS,
        15 assertions**. The catalog exit criterion was then re-derived **independently** of the
        writer's query: exactly 8 functions still reference `deals`, `crm_comprobantes_de_operacion`
        absent, `crm_verificar_deposito` and `crm_forzar_verificacion` present, 0 views — `9 → 8`
        confirmed.
      - **A parent error, recorded rather than hidden.** The first spot-check run omitted the
        `BEGIN; … ROLLBACK;` wrapper the assertion file explicitly requires. Its `SAVEPOINT` failed in
        autocommit, so the fixture **committed** to staging: 5 fixture operations (3 of them deal-free),
        2 `deals`, plus receipts/audit/`depositos_mmg` rows. Detected by comparing staging against the
        known baseline, then removed precisely by the fixture's fixed `bbbbbbbb-…` UUIDs in a single
        transaction. Staging is back to its baseline: **34 operations, 0 deal-free, 35 `deals`** — the
        exact condition the slice started from. The wrapped re-run then passed and left nothing behind.
      - **Second self-inflicted trap in the same check.** The first independent catalog count returned
        **0** functions, which looked like a finding; it was a bad regex — in PostgreSQL ARE `\b` is
        not a word boundary (it is `\m`/`\M`/`\y`). Re-run with `\M`, the count was 8. Same lesson as
        the earlier empty-catalog incident: an empty result is not evidence until the query is proven
        able to produce a non-empty one.
      - **Not verified, carried:** the `UPDATE deals SET updated_at` ELSIF branch was not exercised
        behaviourally (needs an objective plus an overpaid deposit the fixture does not build) —
        source-level check only; the deal `FOR UPDATE` lock leaves no artefact, so its conditionality
        is asserted at source level and not observed; the `cerebro_saldo_envio` `viejo` branch (deal
        with no operation) is unreachable here. No n8n work; the `deals.notes` readers were not touched.
    - **WU6c — re-key the avisos.** `cerebro_avisar_envios_incompletos`,
      `cerebro_avisar_envios_sin_beneficiario`. Changes row sets and the `cerebro_alertas.clave`
      dedup keys; needs its own alert-dedup proof.
    - **WU6d — retire the notes transport.** `cerebro_aplicar_nombre_confirmado` (repoint to the 162
      structured writers) and `cerebro_sync_beneficiarios` (retire). **Sequenced last**: it is only
      correct once the deal-keyed triggers `trg_sync_z_benef_desde_deal` and
      `trg_sync_operacion_al_crear_deal` are gone, which is Phase 2/4 work.
    - **Not yet sliced, blocked on a capture or a decision:**
      `notify_operation_incidencia` (the reason-text gap — **second user decision, to be asked when
      this slice is briefed**), and `sync_tags_cliente` (**capture its live body from the catalog
      first** — it cannot be planned from the repository, and it has two active n8n callers).
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
1. WU4 — DONE. WU4a `bcc6cd7` (161), WU4b `af07d9d` (162), WU4d closed as unnecessary with no code
   change (`8edac6f`). WU4c (163, reparto + destino) queued to land next.
   **Correction (2026-10-01): the n8n-access caveat previously recorded here was stale.** n8n IS
   reachable from this session through its REST API (credentials at
   `/home/onlinefreedom/.config/wacrm/n8n-api.env`); the MCP connector is simply not the channel we
   use. WU5 and WU6 are therefore NOT blocked on access — see the real blocker below.
2. WU5 — rewire the n8n nodes one by one (byte-exact draft diff, live test each).
   **WU5a DONE on the staging twin (`9a9d23e`) — SIX nodes, not seven**: `Registrar beneficiario
   auto`, `Registrar zelle auto`, `gestionar_beneficiario`, `registrar_beneficiario_zelle` (← 162);
   `registrar_reparto_multiple` and `marcar_destino_usd` (← 163). `Registrar deposito auto` was
   already deal-free and needed no rewire — that is the seventh node this plan carried, now retired.
   **WU5b (production) is USER-GATED and not started.**
   **BLOCKER — ANSWERED 2026-10-01, and the answer changes the plan.** There is no workflow named
   `Webhook WaCRM`: that is the *node*. The real flows, established by read-only API recon and
   then re-verified by me directly against the API:
   - PRODUCTION: `Cerebro v2 — LEGACY OPTIMIZED V1`, id `jEzlVLCLUaJhVwzs`, webhook
     `wacrm-cerebro-green-v1`, **`active: true`**. All 44 of its Postgres nodes share ONE credential,
     `Supabase Account` (`S2CallLPSjzbVXN4`, type `postgres`).
   - STAGING TWIN: `[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1`, id `U52y1kSNvhgxvWeb`,
     **also `active: true`**, using `Supabase STAGING` (`np3egGrAcrWkOWd4`).
   - The split is clean across the whole instance: 30 unprefixed workflows → `Supabase Account`;
     the 10 `[STAGING]` ones → `Supabase STAGING`. Nothing crosses.
   Consequence: **the live production workflow is active and does NOT point at the database where
   our functions exist.** Rewiring it directly is the failure mode this check existed to prevent.
   So WU5 proceeds against the `[STAGING]` twin `U52y1kSNvhgxvWeb` end-to-end first, and the
   production rewire becomes a separate, explicitly user-gated step that also requires deploying
   160/161/162/163 to production first. Nothing in WU5 may touch `jEzlVLCLUaJhVwzs` without the
   user's explicit go-ahead for production.
   Honest limit on the evidence: the n8n public API returns credential metadata only
   (`id`/`name`/`type`), never the connection string, so the *host* behind `Supabase Account` is
   confirmed by naming and by its isolation from the staging credential — not by reading a host.
   Reading the actual host needs the n8n UI or `n8n export:credentials --decrypted`, which is out
   of scope and was not attempted. The conclusion is not weakened by this: whether that credential
   is production or merely unpinned, treating an active workflow on an unlabelled credential as
   production is the only safe reading, and the staging twin gives us a path that needs no such
   assumption.
   LATERAL FINDING, reported, not acted on: `PRUEBA OpenAI - copia del Cerebro (NO es produccion)`
   (`lpl76uti9nup5ekm`) points at the SAME `Supabase Account` as production, despite a name that
   says otherwise. Anyone treating that workflow as a safe sandbox would be writing to production.
   Its `active` is `false`.
   Wiring map: `agent-shared/reports/wu5-n8n-wiring-map.md`.
   Also note the rail asymmetry: only `Registrar beneficiario auto` and `Registrar zelle auto` sit
   on the deterministic rail; the other five have no inbound `main` edge and fire only as `ai_tool`s
   (see the WU4 constraints block above). A rewire that is safe for a rail node is not automatically
   safe for an `ai_tool` one.
3. WU6 — **scope re-settled 2026-10-01 from the live staging catalog** (see the WU6 block in Phase 1
   for the full object list and the raw evidence). The earlier grep-based scoping — superseded:
   - `090_notificacion_incidencia_nombre_y_formato.sql` — SETTLED. It contains zero `deals`
     references, and the object it created, `notify_deal_incidencia`, **exists live but has no
     trigger** (`pg_trigger` returns zero rows for its `tgfoid`). Dead function; the only residue
     is an optional `DROP FUNCTION`, and it is a casualty of the table drop rather than work.
   - `114_cutover_retire_sync_pipeline.sql` — **was mis-assessed as "mostly header commentary".**
     It is the single biggest WU6 item: it defines all three blocking views (one of which has
     `deals` as its primary `FROM`) and three of the thirteen functions.
   - `136_business_hours.sql` — three live `cerebro_avisar_*` bodies, still real.
   - `052_cerrar_deal_entregado.sql` / `096_admin_locks_audit_sync.sql` — these own
     `trg_cerrar_deal_entregado` and `deals_admin_completion_guard()`, both trigger functions **on**
     `deals`. They are casualties that must be dropped before the table, not porting work. They are
     **not** in the thirteen.
   - The lesson worth keeping: scoping from migration text produced both a false positive (090, a
     dead function) and a false negative (114's real weight). Only the catalog is authoritative.
