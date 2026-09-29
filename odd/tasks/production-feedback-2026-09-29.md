# Production feedback 2026-09-29: bot, admin/bot interaction, panel, calculator

## Objective
Fix what the first days of production and the 2026-09-29 live test showed, and add the requested
functions. The user's list plus the defects the test proved.

## Constraints (all tasks)
- Staging first. Production (DB migrations, n8n prod `jEzlVLCLUaJhVwzs`, app deploy) only with the
  user's explicit go-ahead. An unattended loop NEVER touches production.
- Authorizations given by the user (2026-09-29): (a) migrations on STAGING Supabase
  `kolppplawzdsjfydwejr` only, no approval needed per migration; (b) READ-ONLY queries (SELECT) on
  the production database to read the live-test messages. No production writes, no production
  migrations, no production n8n changes.
- DeepSeek evals: UPDATED 2026-09-29 (third session). The user separated the credentials — verified
  directly against both live workflows: production's `DeepSeek sin pensamiento` node now uses
  `Osmany CRM` (`ol8nMUZZQYBILen2`); staging's uses `DeepSeek account` (`f0K27ImOFO3QdL34`), which no
  longer touches production. Evals may now use `DeepSeek account` for staging work. (Superseded
  constraint, kept for history: it used to be the shared production credential.)
- Money-path changes (calculator, ledger, delivery) need SQL assertions and vitest, strict TDD.
- A task that needs a product decision stops at the decision and lists it under "Open decisions";
  nothing is invented.
- Replies to the user in Spanish; artifacts in English.

## Tasks

### A. Defects proven by the 2026-09-29 live test
- [x] A1 — A duplicate receipt (same image hash) is dropped silently. No deposit, no op, no incident,
  and the bot still says "lo estamos verificando". It must surface: an incident / admin alert, and
  honest bot wording. (Dedup comprobantes → comprobantes_hashes.)
- [x] A2 — A 10-digit US phone written without +1 ("celular 8133617809") is not recognized as a Zelle
  account by `Snapshot final`.
- [x] A3 — A quote's shipment target (`cerebro_objetivo_envio`) never expires. Yesterday's
  "100 USD → 26,000" became today's target and raised a false "DEPOSITO DE MAS". It must expire or
  close when a new remesa starts. The user: "no me parece que deba seguir". (DECIDED and FIXED —
  see Progress.)
- [ ] A4 — Two Zelle accounts pasted in one block ("Name email NAME2, celular N"; forwarded lines
  prefixed "onlinebussines:") are not separated. The bot merged them into one beneficiary.
- [ ] A5 — A second Zelle beneficiary that arrives after the first is never added: 135 only fills an
  op with NO beneficiary, and the reparto detector needs both accounts plus amounts at once.
  Amounts sent in a later message ("100 a la primera, 53 a la segunda") are not applied (the op
  kept 153 USD on one account).
- [x] A6 — Turn latency: the burst turn took ~3.5 min (agent 43 s). Find where the rest goes.

### B1. Bot logic and dynamic replies
- [ ] B1.1 — When confirming beneficiary data, say how much the recipient receives (per service and
  current rate). Example: "…le hacemos la transferencia de *20,100 CUP*."
- [ ] B1.2 — If the deposit is ALREADY verified, the confirmation must not say "apenas se confirme su
  depósito"; use "Datos registrados. Una vez realizada su remesa le notificaremos por este medio."
- [ ] B1.3 — Receipts sent in chat sometimes not detected or registered. Investigate the real cases
  (beyond A1) and fix.
- [ ] B1.4 — Cash delivery: the bot asks the sender for the recipient's exact address, phone and a
  photo of the ID card (the facts are already in the efectivo_usd service row, 139/140).
- [x] B1.5 — Chat notifications: (a) a sound per incoming chat message, like WhatsApp; (b) "marcar
  todas como leídas" stops the sound and it does not ring again.

### B2. Admin and bot interaction
- [x] B2.1 — While the bot is paused by a human, keep extracting data (cards, phones, names) in the
  background and update the panel silently. It must not reply. (Investigated: already satisfied by
  the existing graph — see Progress.)
- [x] B2.2 — The bot pauses ONLY when an admin writes in the chat. Panel actions (sending a proof,
  completing a remesa) must not pause it. (Both halves confirmed — see Progress: "sending a proof"
  fixed by 147; "completing a remesa" traced and found already safe by construction, no fix needed.)

### B3. Panel and data editing
- [x] B3.1 — The right panel in a customer chat is editable, to complete a transfer manually when
  automation fails. (Investigated: already satisfied — `OperationCorrectionForm` +
  `BeneficiaryEditFields` + `BeneficiaryReassignControl` + `CompleteTransferContainer`, all backed
  by the 098 RPCs, are already wired live into `remittance-operation-card.tsx`.)
- [ ] B3.2 — Weekly control (Control semanal): the read-only chat operations become editable, plus a
  field for the investment cost (costo de la inversión). — **needs a decision, see below.**
- [x] B3.3 — Some remesas verified and delivered from the right panel still show "Awaiting Deposit".
  Find and fix the status update.

### B4. Calculator and panel
- [x] B4.1 — Completing or deleting ("Borrar") a remesa updates or clears the calculator
  automatically. (Investigated: already works correctly for every real path — see Progress.)
- [x] B4.2 — The calculator updates in real time when a remesa completes, with no page refresh.
- [ ] B4.3 — The admin can complete a remesa without a prior deposit verification (force or skip),
  e.g. when the bot was paused. — **needs a decision, see below.**
- [x] B4.4 — Delete operations or records from the calculator module. (DECIDED by the user,
  2026-09-29: a completed remesa's entry must NOT be deletable from the calculator. The manual
  weekly log already supports deleting a line by editing the text — nothing else to build.)

## Open decisions (filled in as tasks reach them)

- B1.3 (investigated a SECOND time, 2026-09-29 third session, read-only prod, structure only; still
  no defect visible): checked all 22 receipts `cerebro_lecturas_vision` classified as `comprobante`
  in the last 3 days. 21 of 22 have a matching `comprobantes_hashes` row; the 1 without it is the
  already-explained A1 resend. Of the 21 hashed ones, 2 looked suspicious at first (no deal touched
  within ±10 min of the vision read) but both turned out fine on a closer look: one completed
  normally with the deal update landing 27 min later (outside my first, too-narrow window); the
  other was correctly registered (has a `DEPOSITO` note) and is sitting in `incident` status, which
  is normal manual-review behavior, not a silently dropped receipt. So across two separate
  investigations (this one and the second session's, covering different windows) the automated
  pipeline has registered every classified receipt it saw. Still need a concrete case from the user
  (chat/phone/approximate time) — until then B1.3 stays unchecked.
- B1.1, B1.2, B1.4 (asked 2026-09-29, second session): the wording these tasks change is NOT
  deterministic code. The replies come from the LLM agent's 41 KB system prompt (`Agente Remesas`,
  few-shot examples such as "Apenas haga su depósito envíenos la captura por favor." and "Apenas lo
  verifiquemos le hacemos la transferencia."); the staging `Decisor` only adds instruction notes.
  A prompt edit can only be verified by running the model, which this loop may not do (no DeepSeek
  evals). Choose: (a) allow model evals against a staging-only DeepSeek credential (not `DeepSeek
  account`), so I can edit the prompt with before/after cases; (b) apply the prompt edit on staging
  without evals and you judge it on real staging chats; (c) skip. B1.1 also needs the recipient
  amount (CUP/USD at the current rate) passed into the agent context, which `Contexto conversacion`
  does not carry today.
- B2.2 (analysis, blocked on DB access rather than a product decision): the bot goes silent for 5
  min after ANY non-AI agent message (`humano_reciente` in `Contexto conversacion`: `sender_type =
  'agent' AND ai_generated = false AND created_at > now() - 5 min`), and `/api/whatsapp/send` also
  calls `pauseAiOnAgentSend` after every send. A panel action that sends through that route (a
  delivery proof) is indistinguishable from an admin typing in the chat. Fix needs a marker that
  says "this message came from a panel action": a nullable `messages` column set by the send route
  (migration on staging) plus the route skipping `pauseAiOnAgentSend` for it plus `humano_reciente`
  ignoring it (n8n). Same blocker as A1: I cannot apply migrations to staging without DB access.
  B2.1 (keep extracting while paused) changes the `Decisor` routing and depends on the same
  n8n/DB access; not started.
- A6 (RESOLVED by the user's information, 2026-09-29): the runaway completion tokens started
  between 2026-09-27 (avg 51 tokens, max 182, none over 2k) and 2026-09-28 (avg 1,415, max 31,621,
  7 turns over 2k; 09-29: avg 3,715, max 43,165). The user confirms that on ~09-28 they swapped the
  agent's model node from the COMMUNITY node (which turns deep thinking off) to the OFFICIAL n8n
  DeepSeek node "to test it again". In the staging workflow the agent is connected to the official
  node (`options` only has temperature; no thinking switch) and the community node is present but
  disconnected. Thinking tokens count as completion tokens, so this explains the 200 s turns. My
  earlier "cap max tokens" idea is dropped: reconnecting the community node (or an official-node
  thinking-off option, if one exists) is the fix. APPLIED on STAGING at the user's request (2026-09-29): in `U52y1kSNvhgxvWeb` the agent is reconnected to the community node, the official node is disconnected, published as version `c96f131f` (previous active `8dc8df01`, restorable). The community node uses credential `osmany_chat`; the official one used `DeepSeek account` (production balance). Check on real staging traffic that completion tokens fall back to ~50-300.
- A1 (DECIDED by the user, 2026-09-29): a duplicate receipt gets a SILENT marker, no alert and no
  incident. Evidence: the `Decisor` already words the reply by the original deal's real stage
  (`dup_etapa`) and 19 of 19 prod `comprobantes_hashes` rows since 2026-09-28 have their deal, so
  duplicates are true resends. Implementation (next tick, strict TDD): record the duplicate on the
  original deal or chat where an admin can see it, without notifying anyone.
- ~~A3~~ **DECIDED (user, 2026-09-29): a bare quote must not create a target at all.** If the
  customer doesn't follow up with beneficiary data or a receipt, nothing should be persisted — see
  Progress for the fix. Closed.
- ~~B4.1 (maybe)~~ **DECIDED (user, 2026-09-29): no.** Deleting a deal must NOT void the calculator
  entry of an already-completed remesa — current behavior (migration 114) stays as-is. Closed.
- B3.2 — **DECIDED (user, 2026-09-29):** admins can edit the values of ALREADY-COMPLETED remesas as
  they appear in the calculator ("Operaciones del chat"), because exchange rates sometimes change
  after the fact and the stored numbers need correcting. Still to design (not a new open decision,
  just implementation choices): which exact columns (`facturado_gyd`/`invertido_gyd`/`retorno_gyd`?)
  and whether `retorno_gyd` stays derived or becomes independently editable — will follow the
  existing `crm_corregir_operacion` pattern (admin-only, audited) unless told otherwise.
- B4.3 — **DECIDED (user, 2026-09-29): left to the implementer's judgment** on the panel design for
  force-completing a remesa with zero receipts to review.
- ~~B4.4~~ **DECIDED (user, 2026-09-29): no new deletion capability.** Same answer as the B4.1
  reversal above — a completed remesa's entry must not be deletable. The manual weekly log's
  existing delete-by-editing-text is the only deletion this app needs. Closed.

## n8n access restored (2026-09-29, second session)
- The `claude.ai n8n` MCP is connected again and the user explicitly authorized reading and patching
  the STAGING workflow `U52y1kSNvhgxvWeb` (never production `jEzlVLCLUaJhVwzs`). The earlier
  "blocked" note is obsolete. The staging workflow has 117 nodes; there is no repo test harness for
  its Code nodes yet, so strict TDD needs one: extract the node's `jsCode` and run it under vitest
  with a stubbed `$()` (a probe of this shape already ran the extracted `Snapshot final`).
- A2 CLOSED, no defect (read-only prod query, message rows of 2026-09-29 04:00-04:05 UTC in the
  "wacrm" project `hqztotshnlzaiziwjyzh`): the customer wrote "celular <10 digits>" and both the
  extracted `Snapshot final` (staging code, exact live text) and the live bot recognized the phone
  (the bot echoed it as "Celular"). The real failure in that burst is A4/A5: the second account
  reused the first's phone-only data and the split amounts were not applied. Customer text is PII:
  tests must use synthetic data, never these rows.

- A4/A5 root cause traced (read-only prod, structure only, no customer data recorded): in the live
  burst both beneficiaries existed at the end, but the first had `amount=null`, the second had
  `amount=53, source=admin_addition` (an admin added it), so the split "100 / 53" was never applied
  by the bot. In the staging workflow `Zelle completo?` requires `unaSola` (<=1 email and <=1 phone)
  and `!multi_beneficiario`, so a multi-account Zelle block always falls to the LLM agent, and the
  only reparto tool, `registrar_reparto_multiple`, is Cuban-only (card/phone/CUP amounts). There is
  no deterministic path inside the Cerebro workflow. CORRECTION (same session): the write side
  already exists. `cerebro_aplicar_reparto(op, jsonb)` (127/129/130) stores N beneficiaries, Cuban
  cards and Zelle, each with its amount, requires the exact deposit sum, and is idempotent. The
  pairing of amounts to accounts is done by the scheduled workflow `[STAGING] Cerebro - Repartos
  automaticos` (`Yu0uskQhydWgNFEy`, every 2 min, prod copy `5YseDUEC5IAaiofF`), which is NOT
  exposed to the MCP ("Workflow is not available in MCP"). So A4/A5 need NO new SQL function; the
  defect is in that detector's pairing/timing (needs both accounts plus amounts at once). Blocked
  until the user enables "Available in MCP" on `Yu0uskQhydWgNFEy` (workflow card or settings;
  staging copy only). A1 does not depend on it and goes next.

## Progress
- 2026-09-29: document created from the user's list and the live test.
  - The live test of per-beneficiary proofs PASSED: 2 proofs stored for op 17e82489, both images
    and captions arrived in the chat.
  - After the test, restored: the test op was cancelled (its ledger line voided); Carolina's
    deposit 20397391101636 went back to its original deal/dates; comprobantes_hashes row
    restored; unfed view 0.
- 2026-09-30 (loop): triaged the full list. A3 needs a product decision (above). A1/A2/A4/A5/A6 and
  B1.1-B1.4/B2.1-B2.2 are blocked this session by the n8n MCP disconnect (above) — they all require
  editing the live Cerebro workflow, which is outside this repo.
- 2026-09-30 (loop): **B1.5 DONE.** New `src/lib/inbox/chat-sound-gate.ts` (pure gate: rings only for
  inbound customer messages, never for the conversation open right now, never for anything at/before
  the last "mark all as read" watermark) + `src/hooks/use-chat-message-sound.ts` (thin `<audio>`
  wrapper, gesture-unlock pattern copied from `use-notification-alerts.ts`, reuses
  `public/sounds/incidencia-v2.mp3` — no chat-specific asset exists yet). Wired into
  `src/app/(dashboard)/inbox/page.tsx`'s realtime INSERT handler and a new "Marcar todas como
  leídas" button in `ConversationList` (there was no such control before this task). TDD: RED
  confirmed (`Cannot find module`, missing button assertions) before writing code, GREEN after (27
  new/updated tests). Full suite `npx vitest run`: 1610/1612 pass; the 2 failures are
  `src/lib/dashboard/date-utils.test.ts` (`mondayIndex`) — confirmed pre-existing and unrelated by
  re-running that file alone on a clean stash of this diff (fails identically with none of this
  task's changes applied). Typecheck and lint clean (lint: 3 pre-existing warnings only, none in the
  touched files). Committed as `59a99f1`.
  - Two low-stakes defaults made by the worker, flagged rather than silently chosen: (1) reused the
    existing `incidencia-v2.mp3` chime, so chat messages and incident alerts now sound identical —
    swap the constant in `use-chat-message-sound.ts` if a distinct sound is wanted later; (2) the
    "marcar todas como leídas" button was placed in `ConversationList`'s filter toolbar (there was no
    prior UI for it anywhere) — confirm that's the right spot if it matters.

- 2026-09-30 (loop): **B3.3 DONE.** Root cause: `cerebro_cruzar_deposito` (114) still gates its
  staleness check ("has this deal moved since I looked at it?") on `deals.stage_id`, a column 114
  itself stopped writing from every operation-status-advancing write path (same class of oversight
  125 already fixed once, for a write path). For an operation whose deal existed BEFORE its deposit
  ("movido"/"sumado" branches, ~13% of deals per 125's own measurement), the deal is frozen at its
  birth stage while `remittance_operations.status` correctly advances to `deposit_verification` —
  so when the panel's `crm_verificar_deposito` (itself already correctly deriving its expected stage
  from `status`, per 114) calls into `cerebro_cruzar_deposito`, that inner function's own
  stage_id-based check disagrees and silently returns `resultado: 'no_aplica'` (a normal 200, not an
  error). Verification never advances the status past `deposit_verification` — this IS the stuck
  "Awaiting Deposit". The same shared function backs n8n's automatic MMG cross-reference, so the
  automatic path is equally defeated; only the admin-only `crm_forzar_verificacion` escape hatch
  (which never reads `deals.stage_id`) still works for these operations.
  - New `supabase/migrations/144_verify_deposit_status_drift.sql` (+ROLLBACK-144): `v_aplica` now
    compares against `remittance_operations.status` (via `cerebro_estado_desde_etapa`) instead of
    `deals.stage_id`; every other line of the 114 function is untouched. `cerebro_cruzar_depositos`
    needed no change — both its paths delegate to this same function.
  - New `supabase/staging/assertions/verify-deposit-status-drift.sql`: case 1 reproduces the drift
    (deal born before its deposit) and proves the fix; case 2 is a control (deal born already at "Por
    verificar" — the common single-shot case) proving no regression there.
  - TDD: RED and GREEN both independently reproduced by me (not just reported by the worker) against
    a local non-production rehearsal Postgres (`wacrm-ensayo`, not staging/prod), inside
    `BEGIN...ROLLBACK` — nothing committed. RED: case 1 fails with `resultado=no_aplica,
    status=deposit_verification`. GREEN (144 applied in the same rolled-back transaction): both cases
    pass, `verify-deposit-status-drift: ALL PASS`. Full vitest suite re-run: 1610/1612 pass (same 2
    pre-existing `date-utils.test.ts`/`mondayIndex` failures, unrelated). `tsc --noEmit` clean.
  - Applied to the real staging database (`kolppplawzdsjfydwejr`) on the user's explicit
    instruction ("Aplica las migraciones 144 y 145 a staging"). Pre/post state confirmed by reading
    `cerebro_cruzar_deposito`'s source before and after; the assertion re-run (in a rolled-back
    transaction, no leftover rows) passed `ALL PASS` against the real database too.
  - No money/ledger totals touched; this is a status-gate read fix only.
  - Committed as `8576bd9`.

- 2026-09-30 (loop): **B4.1 investigated — no defect found.** Traced every real "complete" path
  (deliver-with-proof → `crm_entregar_operacion`; force-verify → `crm_forzar_verificacion`, which only
  reaches `ready_to_transfer`, never `completed`; `crm_corregir_operacion`, which refuses on a
  terminal status) and the one real "delete" path (an external system removes the mirrored `deals`
  row → `trg_cancel_operacion_on_deal_delete`, cancelling the linked operation unless it's already
  `completed`). There is no "Borrar"/"Eliminar"/delete UI or API route for a remesa/operation
  anywhere in this app's `src/` — every completion write is a plain `status` UPDATE, which already
  correctly fires `zzz_remittance_operations_calculator_feed` (104) to feed or void the calculator
  entry. No client-side calculator cache exists to go stale either. Verified empirically (not just
  by reading code) against `wacrm-ensayo`, `BEGIN...ROLLBACK`, nothing committed: completing an
  operation feeds the ledger correctly; deleting the deal of an already-completed operation leaves
  both the operation and its ledger entry untouched (by migration 114's own deliberate design —
  "the money really moved, it's history"); deleting the deal of a not-yet-completed operation
  cancels it correctly with zero ledger entries (none was ever fed). No files changed, nothing to
  commit for this task.
  - **Possible product question, not acted on**: if what B4.1 actually meant was "deleting a deal
    should ALSO void an already-*completed* remesa's calculator entry" — the opposite of 114's
    documented decision — that would be a deliberate policy reversal, not a bug fix. Not invented;
    added below as an open decision in case that's what's wanted.

- 2026-09-30 (loop): triaged B3.1, B3.2, B4.2, B4.3, B4.4. B3.1 already satisfied (above). B3.2 and
  B4.3 need decisions (above). B4.4 half satisfied, half needs a decision (above). **B4.2 DONE** —
  the only clean, unambiguous candidate: the calculadora page fetched "Operaciones del chat" once on
  mount with no realtime subscription, and `remittance_calculator_entries` was never added to the
  `supabase_realtime` publication (`104_calculator_ledger_feed.sql` introduced the feed trigger but
  never touched the publication).
  - New `supabase/migrations/145_calculator_entries_realtime.sql` (+ROLLBACK-145): adds the table to
    `supabase_realtime`, same idempotent shape every other realtime table in this repo already uses.
    No RLS change — the existing `remittance_calculator_entries_select` policy (106) already scopes
    who sees which rows, same as the initial `GET /api/calculadora` read.
  - New `src/lib/calculator/realtime-entry.ts` (pure raw-row → UI-shape mapping + event-fold logic,
    mirrors the GET route's own `source='completed_operation' AND status<>'void'` filter so the live
    feed and the initial load can never disagree) + `src/hooks/use-calculator-entries-realtime.ts`
    (subscription hook, same pattern as `use-realtime.ts`), wired into
    `src/app/(dashboard)/calculadora/page.tsx`.
  - TDD: RED and GREEN both independently reproduced by me against `wacrm-ensayo`
    (`BEGIN...ROLLBACK`, nothing committed): RED — publication-membership check fails; GREEN (145
    applied in the same rolled-back transaction) — both the publication check and a 106-regression
    check pass. Confirmed the table is NOT left in the real publication afterward. Full vitest suite
    re-run: 1623/1625 pass (same 2 pre-existing `date-utils.test.ts`/`mondayIndex` failures,
    unrelated). `tsc --noEmit` clean.
  - No money/ledger amounts or write paths touched — pure read-side wire-up (publication membership +
    client subscription); RLS and every write path (feed trigger, `crm_resolve_pending_entry`)
    unchanged.
  - Applied to the real staging database (`kolppplawzdsjfydwejr`) alongside 144, on the user's
    explicit instruction. Publication membership confirmed before (absent) and after (present); the
    self-reverting assertion re-run against the real database passed `ALL PASS` with no leftover
    rows.
  - Committed as `6437b40`.

- 2026-09-29 (second session): n8n access restored, A2 closed (no defect), A4/A5 traced, A6 cause
  found and fixed on staging, A1 decided (silent marker).
  - A1 silent marker, DB part DONE locally, not yet applied to staging:
    - `146_duplicate_receipt_marker.sql` (+ `ROLLBACK-146-...`): counters on `comprobantes_hashes`
      (`reenvios`, `ultimo_reenvio_at`, `ultimo_reenvio_wamid`) and
      `cerebro_marcar_reenvio_comprobante(hash, wamid)`; silent (no deal, message or audit row).
    - Strict TDD on the local rehearsal Postgres `wacrm-ensayo` (role `supabase_admin`, inside a
      transaction that rolls back): RED = "function cerebro_marcar_reenvio_comprobante(text,
      unknown) does not exist" (`supabase/staging/assertions/duplicate-receipt-marker.sql`);
      GREEN = 7/7 PASS; the rollback file was verified (function gone after it). Commit `4be9942`.
    - NOT applied to real staging: `CRM_STAGING_DATABASE_URL` is empty in this session's shell and
      the Supabase MCP only lists the production project (`hqztotshnlzaiziwjyzh`), which must not
      receive it. Nothing was sent to either. The n8n part (make `Dedup comprobantes` call the
      marker) waits for the migration, because the node would otherwise call a function that does
      not exist there.
    - Needs from the user, one of: (a) export `CRM_STAGING_DATABASE_URL` for staging
      `kolppplawzdsjfydwejr` in the environment Claude Code starts from, (b) add that project to
      the Supabase MCP account, or (c) apply 146 to staging yourself.
  - Process note: an earlier edit of this document by the loop accidentally removed this whole
    Progress section; it was restored verbatim from commit `8335805`.

- 2026-09-29 (third session, after reboot): **A1 DONE end to end.**
  - `CRM_STAGING_DATABASE_URL` became readable this session (the user granted a scoped exception to
    the global `Read(.env.*)` deny in `~/.claude/settings.json`, see the earlier config note). 146
    applied for real to staging `kolppplawzdsjfydwejr` (no `psql` binary locally — used
    `docker run --rm -i postgres:17-alpine psql "$CRM_STAGING_DATABASE_URL"`). Verified before
    (columns/function absent) and after (present); its assertion re-run against the real database in
    a rolled-back transaction: 7/7 PASS, zero leftover rows.
  - n8n side: patched `Dedup comprobantes` (Postgres node) in the STAGING workflow `U52y1kSNvhgxvWeb`
    — added a `mark` CTE that calls `cerebro_marcar_reenvio_comprobante($1, wamid)` gated on the
    existing `dup` CTE's result; every other line of the query is byte-identical. `Snapshot final`
    (the deterministic twin downstream of this node) only ever read `.duplicado` off this node's
    output, confirmed by reading its 20 KB `jsCode`, so the new `marcado` field is inert there — no
    other node needed touching.
  - TDD proof (SQL-level, since this is a Postgres node, not a Code node): against the local
    rehearsal Postgres `wacrm-ensayo` (146 applied there too, for testing only), `PREPARE`d both the
    exact OLD and NEW query text and ran the same resend scenario through each, inside
    `BEGIN...ROLLBACK`. RED (old query, live text): a real resend (same hash, new wamid) correctly
    detects `duplicado=true` but `comprobantes_hashes.reenvios` stays 0 — the bug. GREEN (new query):
    same resend gives `duplicado=true, marcado=true, reenvios=1`; a replay of the SAME wamid gives
    `marcado=false` and `reenvios` stays 1 (no double count); a THIRD new wamid gives `marcado=true,
    reenvios=2`; a genuinely new (non-duplicate) hash gives `duplicado=false, marcado=NULL`, row
    untouched.
  - Published as workflow version `fcf35a3d-6986-4272-947d-f51ae5fe0bc8` (previous active
    `c96f131f...`, the A6 community-node fix — restorable via `publish_workflow` with that version
    id). Workflow stayed `active: true` throughout; only a draft-then-publish step, no downtime.
  - Never touched production (`jEzlVLCLUaJhVwzs`) or any DeepSeek eval.

- 2026-09-29 (third session): **B2.2 partially DONE — the "sending a proof" half.** Root cause: a
  human typing in the inbox and the panel delivering a proof image go through the exact same route
  (`/api/whatsapp/send`) and the exact same shared send core (`sendMessageToConversation`), which
  always inserts `sender_type='agent'`. The route then unconditionally called `pauseAiOnAgentSend`,
  and the Cerebro workflow's `Contexto conversacion` node computed `humano_reciente` from
  `sender_type='agent' AND ai_generated=false AND created_at > now() - 5 min` — a delivery-proof
  send was indistinguishable from an admin typing, on both sides.
  - New `supabase/migrations/147_panel_action_marker.sql` (+ROLLBACK-147): `messages.is_panel_action
    boolean NOT NULL DEFAULT false`.
  - App side: `SendMessageParams.isPanelAction` (`send-message.ts`) sets the column;
    `/api/whatsapp/send/route.ts` reads a new `panel_action` request field, forwards it, and skips
    `pauseAiOnAgentSend` when it's true; `sendProofImage` (used by both the single-proof and
    per-beneficiary delivery pipelines — `deliver-with-proof.ts` / `send-beneficiary-proofs.ts`
    inject it as `sendProof`) now sends `panel_action: true`. Deliberately did NOT touch the
    separate `flow_runs` pause a few lines below in the same function — that is the unrelated Flows
    feature, out of scope here.
  - TDD: RED confirmed first (5 new/updated tests failing — `is_panel_action` missing from every
    insert, `pauseAiOnAgentSend` always called), GREEN after. Full suite re-run: 1627/1629 (same 2
    pre-existing `date-utils.test.ts`/`mondayIndex` failures). `tsc --noEmit` and `eslint` on every
    changed file: clean.
  - Applied 147 to the real staging database (`kolppplawzdsjfydwejr`), verified before/after.
  - n8n side: patched `Contexto conversacion` (Postgres node, staging workflow `U52y1kSNvhgxvWeb`) —
    added `AND COALESCE(m.is_panel_action,false) = false` to the `humano_reciente` EXISTS clause;
    every other byte of this ~15.8 KB query is unchanged (verified with a Python diff before
    applying). Did NOT touch the separate `caducar` CTE (manual-assignment expiry) a few lines above
    — same reasoning, a different feature the task didn't name.
  - Proof, since this query is far too large and side-effecting (UPDATEs, derivation-registering
    function calls) to safely `EXECUTE` end to end even on the rehearsal DB: (a) isolated the exact
    `humano_reciente` EXISTS clause against synthetic fixtures — RED: a panel-action message
    incorrectly counted as `humano_reciente=true` (the bug); GREEN: the same message now gives
    `false`, while a genuine human agent message still gives `true` (no regression); (b) `PREPARE`d
    (never `EXECUTE`d) the FULL modified query against real staging inside
    `BEGIN...ROLLBACK` — zero errors, proving the whole 263-line query is still valid Postgres with
    every function it calls actually present there.
  - Published as workflow version `44672ff8-952e-4736-9fd8-9bc54a6ddd69` (previous active
    `fcf35a3d...`, the A1 fix — restorable). Never touched production or any DeepSeek eval.
  - **"Completing a remesa" half TRACED — already safe, no fix needed.** `deals_stage_notify` fires
    the n8n webhook `staging-wacrm-notify-etapa`, handled by
    `[STAGING] WaCRM - Notificar cliente por etapa del deal` (`OCdJoHTkV6S0aAdk`), whose final node
    ("Enviar por WaCRM") sends the `remesa_completada` notification through `POST
    https://crm.onlinefreedom.site/api/v1/messages` — the PUBLIC bot API, not `/api/whatsapp/send`.
    `src/app/api/v1/messages/route.ts` unconditionally passes `aiGenerated: true` to
    `sendMessageToConversation` (confirmed by reading the route — not conditional on anything) and
    never calls `pauseAiOnAgentSend` (already covered by the existing structural test in
    `pause-ai-on-agent-send.test.ts`). So this notification's `messages` row always has
    `ai_generated=true`, which already fails `humano_reciente`'s own `ai_generated=false`
    requirement — it never counted as a human taking the conversation, and never could pause the
    bot, before or after this session's fix. B2.2 is now fully closed.
  - **B2.1 investigated — already satisfied, no code change made.** First read of `Decisor`'s
    top only (`if (ctx.bot_pausado) { return [{ ruta: 'silencio' }] }`, before any routing) wrongly
    suggested pause short-circuits everything, including extraction — asked the user before touching
    live bot routing, was told to continue, then traced the actual node graph and found the
    assumption wrong. `Decisor` only ever returns THREE ruta values (`agente`, `comando`,
    `silencio`) — it has no deterministic "register this card/Zelle/deposit" route at all. The
    automatic capture pipeline (`Dedup comprobantes` → `Comprobante nuevo?` → `Registrar deposito
    auto` / `Merge beneficiario` → `Beneficiario completo?` → `Registrar beneficiario auto` /
    `Registrar zelle auto` → `Zelle completo?`) runs entirely BEFORE `Contexto conversacion` and
    `Decisor` in the graph, gated only on content (`tarjeta_final`/`celular_final`/Zelle fields being
    present, not ambiguous), never on `bot_pausado` or anything from `Decisor`. So a card, phone, or
    Zelle account the customer sends while the bot is paused is already extracted and persisted to
    `remittance_beneficiaries`/`remittance_operations` today, updating the panel, with zero reply —
    exactly B2.1's requirement. The only extraction gated behind `Decisor` reaching `ruta: 'agente'`
    is the set of AGENT TOOLS (`gestionar_beneficiario`, `registrar_beneficiario_zelle`,
    `registrar_reparto_multiple`, …) — but reaching those requires the LLM agent to run a
    conversational turn, which is itself "replying"; B2.1 explicitly says the bot "must not reply"
    while paused, so there is no way to capture more without violating that same requirement. No
    fix needed; no code or workflow touched for this task.
  - **Correction, said plainly**: my first message asking to proceed was based on reading one
    `if` statement out of an 819-line function, not the actual node graph — the alarm about a large,
    risky Decisor rewrite was wrong. Verified before building anything, not after.

- 2026-09-29 (fourth touch-point, user answers): the user enabled "Available in MCP" on
  `Yu0uskQhydWgNFEy` (A4/A5 unblocked — confirmed `availableInMCP: true`; fixing its reparto
  detector, a pure-JS algorithm, delegated to a worker under strict TDD, in progress). Also answered
  several open decisions directly:
  - **B4.1 reversal: NO.** Deleting a deal must not void a completed remesa's calculator entry.
    Current (114) behavior is correct as-is. Closed, no change.
  - **B4.4: closed, no new deletion capability.** Same reasoning as above — completed entries stay
    undeletable; the manual log's existing delete-by-editing-text is enough.
  - **B3.2: decided.** Admins can edit an already-completed remesa's values as shown in the
    calculator, because exchange rates sometimes get corrected after the fact. Implementation
    (which exact columns, audit trail) still to design, following existing patterns.
  - **B4.3: left to the implementer's judgment** on the zero-receipts panel design.
  - **A3: still unclear to the user** — re-explained in plain terms (a stale quote from a
    conversation that never became a deposit shouldn't be compared against tomorrow's unrelated
    deposit) and asked again for either a concrete expiry window or a different closing rule.
  - **DeepSeek credential claim, NOT yet accepted**: the user said the "DeepSeek account" credential
    is theirs, not production's, and that they already swapped it in staging manually. Verified
    directly against both workflows: credential id `f0K27ImOFO3QdL34` ("DeepSeek account") is still
    the exact same entry wired into BOTH the production AND staging "DeepSeek sin pensamiento"
    nodes — not two separate credentials. Whatever key is behind that id today is shared between
    both environments; n8n credentials aren't duplicated per-environment by editing a node. Asked
    the user to clarify whether they created a genuinely separate credential entry (different id) or
    edited this same one's key (which would also change what production uses). No eval has been run
    under this claim.

- 2026-09-29 (mid-turn correction from the user): the user fixed it and confirmed. **Re-verified
  directly against both live workflows, credential wiring now genuinely separated**: production's
  `DeepSeek sin pensamiento` node now uses `Osmany CRM` (`ol8nMUZZQYBILen2`); staging's still uses
  `DeepSeek account` (`f0K27ImOFO3QdL34`), no longer shared with production. Constraint updated
  above. B1.1/B1.2/B1.4 evals are now unblocked (not yet run this session).

- 2026-09-29 (same mid-turn message): the user answered **A3**: "if the client doesn't explicitly
  say the amount, nothing should be created; it should only be created once they send [beneficiary]
  data or a receipt." **A3 DONE.**
  - Root cause, confirmed precisely: `calcular_usd` (the agent's ONLY quote tool,
    `n8n-nodes-base.postgresTool`) calls `cerebro_fijar_objetivo` UNCONDITIONALLY every time the
    agent answers "how much do you get for X USD" — by design (072/075's own comment: a separate
    `fijar_objetivo` tool was tried and the model called it 0 of 2 times in real traffic, so it was
    made deterministic and folded into `calcular_usd` itself). A bare curiosity question with no
    beneficiary and no deposit already sets a persistent, un-expiring target.
  - Fix: `supabase/migrations/148_objetivo_requiere_compromiso.sql` (+ROLLBACK-148) adds one guard
    inside `cerebro_fijar_objetivo`, before it persists anything: only proceed if the conversation
    already has a `vigente` beneficiary on one of its operations, OR a `comprobantes_hashes` row for
    the contact's phone (a receipt already sent). Otherwise it returns without writing — the numeric
    quote `calcular_usd` shows the customer is completely unaffected either way. Every other line
    (currency parsing, the fijado/sustituido wording, the upsert) is byte-identical to 075. No n8n
    change needed — the gate lives entirely in the DB function `calcular_usd` already calls.
  - TDD: RED and GREEN both independently reproduced against `wacrm-ensayo` in `BEGIN...ROLLBACK`.
    RED (current 072-147 body): a bare quote (no beneficiary, no receipt) creates the target — the
    bug. GREEN (148 applied): the same bare quote creates nothing; a quote where a vigente
    beneficiary already exists still sets the target; a quote where a receipt was already sent still
    sets the target (both regression controls, no behavior change for the common case). Applied to
    the real staging database (`kolppplawzdsjfydwejr`); its assertion re-run there:
    `objetivo-requiere-compromiso: ALL PASS`, no leftover rows.
  - Does not retroactively expire any target already open before this migration — only new
    `fijar_objetivo` calls are gated from now on.
  - Committed as `19f7abc`.

## Next step
A1, A3, B2.1 and B2.2 are fully closed; B4.1-reversal and B4.4 are decided-closed with no change
needed. B1.1/B1.2/B1.4 evals are unblocked (DeepSeek credential clarified) but not yet run. A4/A5
unblocked and being fixed now (background worker, pure algorithm work — will be applied to the n8n
node and verified once it reports back). B1.3: read-only production investigation done again this
session, still no defect found, still needs a concrete case from the user. B3.2 and B4.3 are
unblocked for implementation (decisions given above) — not yet built.
