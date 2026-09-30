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
- [x] A4 — Two Zelle accounts pasted in one block ("Name email NAME2, celular N"; forwarded lines
  prefixed "onlinebussines:") are not separated. The bot merged them into one beneficiary.
  FIXED and PUBLISHED to staging n8n (see Progress).
- [x] A5 — A second Zelle beneficiary that arrives after the first is never added: 135 only fills an
  op with NO beneficiary, and the reparto detector needs both accounts plus amounts at once.
  Amounts sent in a later message ("100 a la primera, 53 a la segunda") are not applied (the op
  kept 153 USD on one account). FIXED and PUBLISHED to staging n8n (see Progress).
- [x] A6 — Turn latency: the burst turn took ~3.5 min (agent 43 s). Find where the rest goes.

### B1. Bot logic and dynamic replies
- [x] B1.1 — CLOSED by user decision 2026-09-30 (amount said once, in the quote; see "B1.1
  decision"). Original notes: Built and PUBLISHED TO STAGING — not yet evaluated with real
  conversations, not yet ported to production. When confirming beneficiary data, say how much the
  recipient receives (per service and current rate). Example: "…le hacemos la transferencia de
  *20,100 CUP*."
- [ ] B1.2 — PASSED on staging with a real conversation (2026-09-30 13:47-13:51: deposit forced
  verified before the card and phone; the bot closed with the exact required wording, no amount
  repeated, no lost message). Not yet ported to production. If the deposit is ALREADY verified, the confirmation
  must not say "apenas se confirme su depósito"; use "Datos registrados. Una vez realizada su remesa
  le notificaremos por este medio."
- [x] B1.3 — Receipts sent in chat sometimes not detected or registered. Investigate the real cases
  (beyond A1) and fix. FOUND AND FIXED IN PRODUCTION — see Progress (case: Javier Cruz).
- [x] B1.4 — DONE and LIVE IN PRODUCTION (DB 150+151, n8n), see Progress.
  Cash delivery: the bot
  asks the sender for the recipient's exact address, phone and a
  photo of the ID card. CORRECTED PREMISE (see Progress): this data is not stored anywhere in the
  schema today (139/140 only added catalog TEXT describing what's needed, not per-operation columns)
  — this is a new feature, not a wording fix. User confirmed 2026-09-29: build it.
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
- [x] B3.2 — DONE (see Progress, migration 149) — deployed to staging AND production. Weekly control
  (Control semanal): the read-only chat operations become editable, plus a field for the investment
  cost (costo de la inversión).
- [x] B3.3 — Some remesas verified and delivered from the right panel still show "Awaiting Deposit".
  Find and fix the status update.

### B4. Calculator and panel
- [x] B4.1 — Completing or deleting ("Borrar") a remesa updates or clears the calculator
  automatically. (Investigated: already works correctly for every real path — see Progress.)
- [x] B4.2 — The calculator updates in real time when a remesa completes, with no page refresh.
- [x] B4.3 — The admin can complete a remesa without a prior deposit verification (force or skip),
  e.g. when the bot was paused. FIXED (see Progress) — the backend (`crm_forzar_verificacion`, 099)
  and its route/command already existed; the bug was the panel hiding the Force button whenever
  there were zero receipts to review.
- [x] B4.4 — Delete operations or records from the calculator module. (DECIDED by the user,
  2026-09-29: a completed remesa's entry must NOT be deletable from the calculator. The manual
  weekly log already supports deleting a line by editing the text — nothing else to build.)

## Open decisions (filled in as tasks reach them)

- B1.3 (investigated a THIRD time, 2026-09-29 fifth touch-point, at the user's explicit request —
  "revisa produccion, ahora tendras material de sobra" — widened to 10 days, read-only prod,
  structure only; still no defect found):
  - Widened the receipt check from 3 to 10 days: 26 images classified `comprobante` (vs 22 before),
    still exactly 1 without a matching `comprobantes_hashes` row — and it is the SAME
    already-explained case (`2026-09-29 03:59:40 UTC`, inside the previously documented A1 burst),
    not a new one. Every other classified receipt in the wider window is registered.
  - New angle this pass: checked whether vision is silently skipped on real receipt photos rather
    than mis-registering ones it did classify. Of 197 customer images in 10 days, 159 have no
    `cerebro_lecturas_vision` row at all (only 38 do). Checked all 159 for a plausible reason: 0 of
    159 had ANY open (non-completed/non-cancelled) remittance operation in the 6 hours before they
    were sent — meaning none of them were sent in a context where a receipt would even be expected.
    This matches the pipeline only running vision analysis inside an active deal, not on every photo
    a customer sends (profile pictures, unrelated images, etc.) — expected behavior, not a gap.
  - Across three separate investigations now (three different, increasingly wide windows), the
    automated pipeline has registered every classified receipt it saw, and never appears to skip
    vision on an image sent during an open operation. Still need a concrete case from the user
    (chat/phone/approximate time) to find anything beyond this — until then B1.3 stays unchecked.
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
- ~~B4.3~~ **DECIDED (user, 2026-09-29): left to the implementer's judgment.** DONE — see Progress.
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

- 2026-09-29 (fifth touch-point): **A4/A5 DONE**, applied and published to staging n8n.
  - Root cause, A4 (two accounts pasted together): the amount-pairing step picked the message right
    after/before the account by *message index*, one candidate per account. Two accounts pasted in
    the SAME message share one message index, so that window collapsed to nothing for the second
    account — not an "extraction separation" problem as first hypothesized, but an amount-pairing
    window bug. Fix: accounts sharing a message index are grouped into one cluster; the amounts
    nearest the cluster are handed out to its accounts in encounter order. A cluster of size 1 (every
    case that isn't this bug) computes the exact same window and pick as before — no behavior change
    for the common case.
  - Root cause, A5 (amount by ordinal position, "100 a la primera, 53 a la segunda"): no code path
    read an ordinal-position phrase for amounts at all (only for a card's phone). Fix: a new
    `ordinalMontos` pass mirrors the existing card-phone ordinal reading (shared `ORD` map) and is
    consulted before the positional pairing, only when the customer used an explicit ordinal phrase;
    absent that phrase, positional pairing is untouched.
  - Delegated to a worker under strict TDD (`node --test`, 16 cases covering both bugs plus every
    existing behavior as regression controls, all GREEN). Independently re-verified the worker's
    diagnosis and diff line-by-line before accepting it — not taken on trust.
  - Worker also claimed the pre-existing `norm()` line's Unicode ranges threw a `SyntaxError` in
    Node and replaced it with a guessed explicit-enumeration version, flagging they could not verify
    byte-fidelity against the live node's source. Independently extracted the TRUE live source
    byte-for-byte from this session's own JSONL transcript (never by re-typing) and proved via
    `node --check` there was never a syntax error — a transcription artifact, not a real bug.
    Restored the authentic `norm()` line into the worker's otherwise-correct algorithmic fix.
  - Applying that restored fix to the n8n node then hit the same class of problem from the other
    side, twice: submitting the exact original Unicode-range `norm()` line (once as literal
    characters, once as `\uXXXX` JSON escapes) both times resulted in 3 specific invisible-whitespace
    codepoints (U+00A0, U+2000, U+202F) silently missing from what n8n stored, confirmed by
    re-extracting the stored source from the JSONL transcript and diffing codepoint-by-codepoint
    against the intended string — a systematic loss in the update pipeline, not a one-off typo.
    Sidestepped it: rewrote `norm()`'s character class as an explicit enumeration of every individual
    codepoint (no hyphen-ranges at all), verified functionally IDENTICAL to the original ranged regex
    via a direct Node behavioral comparison, re-ran `node --check` and the full 16-test suite
    (16/16 GREEN), then submitted that range-free version.
  - Final verification: extracted the draft's stored `jsCode` from this session's own JSONL
    transcript and diffed it byte-for-byte (Python, codepoint comparison) against the locally
    verified fix file — exact match (18988 chars, `EQUAL: True`). Published that draft
    (`ea331342-2781-42de-aa46-0a97ea9c5a61`) as the active version of workflow `Yu0uskQhydWgNFEy`
    ("[STAGING] Cerebro - Repartos automaticos", node "Detectar repartos"). Confirmed
    `activeVersionId` now equals the published version.
  - Pure n8n-side change: no repo file touched for the fix itself, only this task document.

- 2026-09-29 (sixth touch-point): **B4.3 DONE.**
  - Root cause, found by reading the deposit-review code rather than guessing: the backend already
    had everything needed — `crm_forzar_verificacion` (099, admin-only, moves an operation stuck in
    `deposit_verification`/`incident` straight to `ready_to_transfer` with no evidence check) plus
    its route (`/api/remittance-operations/[operationId]/force-verify`) and command
    (`forceVerifyDeposit`) were already wired end to end. `data.canVerify`
    (`crm_comprobantes_de_operacion`'s `v_can_verify`, 099) is purely status-based — true whenever
    the operation is `deposit_verification`/`incident` with a linked deal at the right stage,
    independent of how many receipts exist.
  - The actual bug: `DepositReviewSection` rendered the entire "Force verification…" control (button,
    reason field, confirm) INSIDE the `{current && draft && (...)}` block, where `current` is the
    first unmatched receipt. With zero receipts (`unmatched.length === 0`), `current` is `null`, so
    the Force control never rendered at all — an admin with force-verify permission had no way to
    see or click it for exactly the case B4.3 describes ("e.g. when the bot was paused" and never
    logged a receipt).
  - Fix: moved the Force button/confirm block out of the `current && draft` guard into its own
    `canVerify && canForce` block (same two gates it always used, just no longer coupled to a receipt
    existing). The amount/TransID inputs and the Verify button correctly stay inside the receipt
    block (they only make sense against an actual declared receipt).
  - `src/components/inbox/operations/deposit-review-section.tsx` (fix) and
    `deposit-review-section.test.tsx` (2 new tests: force still offered with `receipts: []`, and
    still hidden with `receipts: []` when `canForce` is false). TDD: RED confirmed the missing button
    (`expected undefined not to be undefined`) before the fix; GREEN after (22/22 passing, no
    regressions in `deposit-review-container.test.tsx` / `remittance-operation-card.test.tsx` /
    `operations-panel-container.test.tsx`, 120/120). `npx tsc --noEmit` clean.
  - No DB migration needed — pure front-end fix, the RPC/route/command layer was already correct.

- 2026-09-29 (seventh touch-point): user chose option (a) for B1.1/B1.2/B1.4 (staging-only DeepSeek
  evals, `DeepSeek account` credential) and gave a concrete B1.3 case: **Javier Cruz, phone
  5926460583, operation `2f65becb-058e-438f-a06b-d0654727f8d5` (deal `badc01a5-...`), 13,000 GYD via
  zelle, created 2026-09-28 14:31:39 UTC, stuck in `deposit_verification`.** Investigated (read-only
  prod) and found a real, evidenced defect. **B1.3 DONE, migration 144 applied to PRODUCTION with the
  user's explicit go-ahead.**
  - Confirmed exact chain (read from staging `U52y1kSNvhgxvWeb`, mirrors production): `Snapshot final`
    → `Comprobante nuevo?` → `Registrar deposito auto` (`cerebro_registrar_deposito`) → `Cruzar
    deposito con MMG` (`cerebro_cruzar_depositos` → `cerebro_cruzar_deposito`) — this IS reactive, it
    runs in the SAME turn vision classifies a new comprobante, using the extracted referencia/monto
    directly. It is not "never reacted" — it reacted and was blocked.
  - Root cause: this is the EXACT bug migration 144 (B3.3, applied to staging only, earlier today)
    already fixes, just never applied to production. Javier's deal was born at stage "Solicitada" and
    never moved (114 stopped writing `deals.stage_id`), but his operation correctly advanced to
    `deposit_verification`. The pre-144 `cerebro_cruzar_deposito` compared `v_aplica` against the
    stale `deals.stage_id` instead of `remittance_operations.status`, got `false`, and returned
    `'no_aplica'` WITHOUT even checking his referencia/monto — even though his deposit (MMG trans_id
    `10401770551050`, 13,000 GYD, in the book since 14:26:19) exactly matched and vision confirmed it
    at 14:32:10 (`arbitro: "la referencia del giro 0 SI esta en el libro"`).
  - Consequence: the deposit sat unconsumed for 11 minutes, until a DIFFERENT customer's unrelated
    operation for the exact same amount (13,000 GYD) was created at 14:43:55 and its OWN crossing
    attempt grabbed it via the approximate-match fallback (unique candidate by amount+time+ref
    shape), consuming it within half a second — Javier's specific deposit is no longer
    code-recoverable; it now belongs to another real operation.
  - Verified production's `cerebro_cruzar_deposito` was still byte-for-byte the pre-144 (114)
    version before touching anything (`pg_get_functiondef`), confirmed `cerebro_estado_desde_etapa`
    exists in production, then applied 144's `CREATE OR REPLACE FUNCTION` to production via
    `apply_migration` (pure function-definition swap, no data touched), and confirmed the new
    `remittance_operations`-based check landed. This is a DDL-only, additive change (fail-closed
    behavior is a strict superset of before) already proven via RED/GREEN against a rehearsal DB and
    real staging earlier today — not re-proven with a fresh fixture run against production itself, to
    avoid writing synthetic fixtures into the live database.
  - **CORRECTION (same touch-point, caught before writing any code):** first reported that
    `crm_forzar_verificacion` (099) had the same `deals.stage_id` staleness bug as `cerebro_cruzar_
    deposito`. That was WRONG — a background investigation read 099's ORIGINAL (pre-114) body, not
    its LATEST one. Migration 114 (already live, item 6 of its own header) already rewrote
    `crm_forzar_verificacion` to drop the `deals.stage_id` gate entirely and write
    `remittance_operations.status` directly. Verified against production's live `pg_get_functiondef`
    before touching anything: it matches 114's fixed version exactly, no staleness bug, nothing to
    build here. The "Force verification" button (B4.3) already works correctly today for Javier's
    operation (`status = 'deposit_verification'` satisfies its gate) — an admin can force it from the
    panel right now if desired.
  - Javier's own deposit is still already consumed by someone else's real operation — that is a money
    reconciliation problem, not fixable by code. Needs a human/admin decision on how to make Javier
    whole (find him a different deposit, treat his remesa as outstanding, etc.), independent of
    whether his operation gets force-verified.
  - Committed: migration application (task doc only — no local file change, this was a prod-only DDL
    application of an already-committed migration).

- 2026-09-29 (same touch-point): user also raised a broader point — the whole point of building the
  panel/RPCs was to STOP depending on `deals`, and asked why the system still leans on it, wanting
  `deals` eliminated entirely. Logged as a new, NOT-yet-scoped architectural item below (Open
  decisions) — this is a large blast-radius change (pipeline/kanban UI, `deal_id` foreign keys across
  `remittance_operations`/`depositos_mmg`/audit rows, etc.) that needs its own exploration/proposal
  before any implementation, not a same-session code change.

- 2026-09-29 (eighth touch-point): asked the user whether B1.4's data should persist across FUTURE
  remesas to the same recipient, or only within the same operation. **DECIDED: per-operation only**
  — a brand-new remesa to the same person asks again; this is not a cross-operation recipient
  profile. Also found, by direct production query, that ZERO real operations with
  `delivery_method = 'efectivo_usd'` have ever existed — this service is catalog-only today
  (137/139/140), so B1.4 is built ahead of first use, following the exact same
  `service_type='remesa'` + `delivery_method` shape `zelle`/`cuban_card`/etc. already use (no new
  `service_type` value).
  - **B1.4 DB layer DONE** (n8n wiring still pending, separate follow-up): migration 150 adds
    `'efectivo_usd'` to `remittance_beneficiaries.beneficiary_type`, plus nullable `address` and
    `id_photo_wamid` (a message-id reference, same graceful pattern as `comprobantes_hashes.
    whatsapp_message_id` — never duplicates the image). New bot-facing RPC
    `crm_registrar_datos_entrega_efectivo(p_conv, p_phone, p_address, p_id_photo_wamid)` —
    every field but the conversation is optional; `NULL` means "no new value this call", so the bot
    (or a deterministic step) can call it once per turn with only the field just given, and a
    `COALESCE`-based merge against the current `vigente` row means an earlier turn's field is never
    lost. Append-only (old `vigente` → `reemplazado`, fresh `vigente` inserted), no-op when nothing
    actually changed, `22023` when there's no open `efectivo_usd` operation to record against
    (this RPC never creates one). `service_role`-only grant, same trust boundary as
    `cerebro_aplicar_reparto`/`cerebro_aplicar_nombre_confirmado` — verified against those functions'
    own grants before accepting the claim.
  - TDD: RED (function missing, 42883) then GREEN (9/9 expectations) reproduced independently by me
    against `wacrm-ensayo`, matching the delegated worker's own reported run; also run by the worker
    against real staging (RED then GREEN, 9/9), zero leftover fixture rows on both. Applied to
    staging only — production needs its own go-ahead, not assumed.
  - Committed as `0e359b0`.
  - **Remaining for B1.4**: the n8n side — extend `Contexto conversacion` with a "what's still
    missing" flag (phone/address/photo) so the agent asks only for what it doesn't have yet, a
    deterministic step to auto-capture an ID-card photo's wamid when one arrives during an open
    `efectivo_usd` operation (not relying on the LLM agent to reliably call a tool with the right
    wamid — same "agent tool calls are unreliable, prefer deterministic pre-processing" lesson this
    doc already recorded for A3/B1.1), and a prompt instruction for the agent to call
    `crm_registrar_datos_entrega_efectivo` with phone/address when the customer states them in text.
    Not started.

## Open decisions (new items from the seventh touch-point)
- **Javier Cruz's specific stolen deposit** — needs a human/admin reconciliation decision, not code.
- **Eliminate `deals` entirely** — user wants the system to stop depending on `deals` (that was the
  original point of building the operations panel/RPCs). Confirmed 2026-09-29: full product-wide
  removal, including the Contacts page "Deals" tab and the automations engine's `create_deal` step,
  not just the remittance flow (an earlier scoping pass wrongly said deals had no other use — see
  `odd/tasks/eliminate-deals.md`, the dedicated plan for this, phased and not started beyond planning).
- ~~B2.2's app-code deploy needs `pauseAiOnAgentSend`~~ **RESOLVED and SHIPPED.** Read
  `pause-ai-on-agent-send.ts`'s implementation: it writes `ai_autoreply_disabled`/`ai_handoff_reason`/
  `ai_handoff_at` — confirmed all three columns already exist in production, and
  `ai_autoreply_disabled` is the SAME column the existing manual "tomar el control" panel button
  already uses (per the Decisor's own comment). `pauseAiOnAgentSend` doesn't duplicate anything; it
  just triggers that same existing mechanism automatically on any agent/admin send instead of
  requiring a manual click. Cherry-picked its prerequisite (`cd50134`, self-contained, also adds an
  unrelated-but-harmless ownership-icon feature not wired into anything else) plus B2.2 (`0651520`)
  onto `privado/master` and pushed (`ab03310..2f3deb6`). `tsc --noEmit` clean, 1432/1434 tests (same
  pre-existing unrelated flake). B2.2 is now fully live: DB (147), n8n (SQL patch, prior entry), and
  app code, all in production.

## Production deploy (2026-09-29, eighth touch-point)
- **DB migrations 145-149 applied to production** (`hqztotshnlzaiziwjyzh`), each verified before/after
  against the live function/column state, not assumed from the migration file alone.
- **App code**: cherry-picked `d781e94` (B4.2), `6499fa4` (B3.2), `ab03310` (B4.3) from
  `feat/port-chat-operations-calculator` onto `privado/master` (production's separate deploy repo,
  `wacrm-produccion`) and pushed — `89d9d47..ab03310`, should auto-deploy. `npx tsc --noEmit` clean,
  `npx vitest run`: 1407/1409 (the 2 failures are the same pre-existing timezone-sensitive
  `date-utils.test.ts` flake seen earlier this session, unrelated to any of these changes, present on
  `privado/master`'s own baseline already). **B2.2's app code deliberately NOT included** (see Open
  decisions above) — B2.2's migration (147) is live, but its dashboard-route/send-message.ts half is
  not, so the panel-action marker exists in the schema but nothing sets it yet in production.
  - Caught and self-corrected a real mistake during this process: an automated regex-based
    conflict-resolution script introduced a genuine syntax error (deleted a chunk of an interface
    declaration between two nearby conflicts) — caught by running `tsc --noEmit` before pushing,
    not left for later; redid the affected conflict resolutions by hand instead of trusting the
    script, then re-verified clean.
- **n8n production — DONE, all three ported and verified byte-exact before publishing**:
  - **A1** ("Dedup comprobantes", workflow `jEzlVLCLUaJhVwzs`): staging-vs-production diff was clean
    (only the expected fix). Published, `activeVersionId` `09122bba-28af-4bd6-a8a7-f4297a413c27`
    (previous `f4eb304a-fa11-40b1-8d47-17657e9bd62e`, restorable).
  - **A4/A5** ("Detectar repartos", workflow `5YseDUEC5IAaiofF`, the production repartos automation):
    staging-vs-production diff was clean. First submission attempt failed its own byte-exact check
    (caught a ` ` vs ` ` transcription slip plus a stray `﻿` before publishing anything
    — exactly the discipline this is for); corrected and re-verified exact on the second attempt.
    Published, `activeVersionId` `e0603c06-784e-4f20-afba-8aaf8deb0251` (previous
    `66656e77-c7a0-4155-8f46-c3b17e756c1b`, restorable).
  - **B2.2** ("Contexto conversacion", `jEzlVLCLUaJhVwzs`) — **not a straight copy from staging**:
    staging's active version also carries an unrelated, deliberately staging-only addition
    (`catalogo_servicios`, migration 138 — "staging only" per its own commit message) that production
    must NOT get yet. Copying the whole node would have shipped an unfinished feature by accident.
    Instead, applied a surgical one-line patch directly to production's own current query: inserted
    exactly `AND COALESCE(m.is_panel_action,false) = false` into the `humano_reciente` EXISTS clause
    (confirmed exactly one occurrence of the target text before patching), verified byte-exact, then
    published. `activeVersionId` `49136979-7a6f-4dd4-a9a5-52d62c0597f1` (previous
    `09122bba-28af-4bd6-a8a7-f4297a413c27`). Currently a no-op in production (nothing sets
    `is_panel_action` yet, since B2.2's app-code half is held back — see above) until that ships.

## Next step
A1, A3, A4, A5, B1.3, B1.5, B2.1, B2.2, B3.1, B3.2, B3.3, B4.1(reversal), B4.2, B4.3 and B4.4 are all
closed. Remaining:
- **B1.1/B1.2 — built and published to STAGING**, not yet evaluated with real conversations or ported
  to production. `Contexto conversacion` gained `deposito_ya_verificado` (mirrors
  `deposit-review-section.tsx`'s `VERIFIED_STATUSES`) and `monto_recibe_valor`/`monto_recibe_moneda`
  (reused `crm_calcular_monto_destino`, 100, rather than re-deriving rounding rules — same floor-USD/
  round-CUP logic the panel already uses). `Decisor` gained `esteTurnoVerificado`/the
  `deposito_ya_verificado` branch (B1.2) with the exact required wording. `Agente Remesas` gained one
  line telling the agent to state the destination amount from context, never computed itself (B1.1).
  Published to `U52y1kSNvhgxvWeb`, `activeVersionId` `84491bf8-a14d-4d91-8ee0-09e9fac92ff7`
  (previous `a6680af7-c25a-4b88-bd5f-712aa6d4af16`, restorable). Independently re-verified byte-exact
  after publishing (not just trusting the delegated worker's report — this same task's earlier two
  attempts both had real problems: an unrelated "enseño"→"enseno" and "guardados"→"guardadas"
  corruption caught before the first publish attempt, then a rate-limit failure that left the draft
  unfixed despite a false "byte-for-byte match" report). Needs real-traffic or synthetic-eval
  observation before being considered proven, same as A6 — not yet run.
  - Checked the safe automated eval path (`test_workflow`) before recommending it: its own tool
    description confirms it pins any node WITH CREDENTIALS, which includes the DeepSeek chat-model
    sub-node behind `Agente Remesas` — so a `test_workflow` run would return simulated/pinned output
    for the LLM itself, never a real generation, making a before/after comparison meaningless. The
    real alternative, `execute_workflow`, does a genuine live run with real side effects (could send
    an actual WhatsApp message) — not something to fire without explicit authorization. Recommended
    the same low-risk path as A6 instead: send a couple of real test messages to the staging WhatsApp
    number (one beneficiary-confirmation scenario, one already-verified-deposit scenario) and observe
    the bot's actual replies.
- **B1.4 — n8n wiring DONE, built and PUBLISHED to STAGING.** `Contexto conversacion` gained
  `entrega_efectivo_en_curso` (bool) and `entrega_efectivo_falta` (text[] of `'telefono'/'direccion'/
  'carnet'` still missing), same join/filter shape as the RPC (150) itself so they can never disagree.
  `Snapshot final` gained `foto_otro_wamid`: the first image left classified `'otro'` after the
  existing card-reclassification pass (never a `comprobante`/`tarjeta_cubana`/`cuenta_zelle`). New
  deterministic node `Registrar carnet efectivo` (parallel fan-out from `Snapshot final`, dead-end)
  calls `crm_registrar_datos_entrega_efectivo` with just that wamid when there's an open efectivo_usd
  operation with no photo saved yet — same "don't delegate critical capture to the LLM" lesson as A3/
  B1.1. New agent tool `registrar_datos_entrega_efectivo` (same wiring pattern as
  `registrar_beneficiario_zelle`) lets the agent save phone/address when the customer states them in
  text. `Agente Remesas` gained two lines: documenting the new tool, and telling the agent to ask only
  for what `entrega_efectivo_falta` lists.
  - Independently re-verified every touched node myself (not just trusting the delegated worker):
    `Contexto conversacion`'s addition is a clean pure append; the two new nodes are wired and
    positioned correctly; `Agente Remesas`'s two added lines are clean with no surrounding corruption.
    `Snapshot final`'s diff had two additional, unrelated hunks where n8n's own save re-encoded two
    pre-existing `\uXXXX`-escaped regex character classes into their literal-character equivalents —
    verified BOTH are functionally identical to the originals by direct regex-behavior testing in
    Python (same match results across every relevant test string), not just eyeballing the bytes.
  - **Found and left alone, documented for later cleanup**: `Agente Remesas` carries a stray,
    orphaned flat parameter key literally named `"options.systemMessage"` (a sibling of the real,
    correct nested `options: { systemMessage: ... } }`), already present in the currently-published
    active version before this task touched anything — almost certainly the byproduct of an earlier
    `setNodeParameter` call using dot-notation (`/options.systemMessage`) instead of the correct JSON
    Pointer slash-notation (`/options/systemMessage`), which creates a literal flat key instead of
    navigating into the nested object. Confirmed this key is NOT part of the AI Agent node's actual
    parameter schema (n8n's own node definitions use the nested path; this flat key matches no defined
    property) and its content was byte-identical to the real one at the time of B1.1/B1.2's publish,
    so it caused no behavior difference. It's now stale (still holds the pre-B1.4 prompt) since only
    the real nested key was updated this time — left it untouched rather than risk a fresh corruption
    while removing ~42KB of inert cruft under time pressure. Should be cleaned up in a future pass.
  - Published, `activeVersionId` `a905531e-a187-404b-be26-c920e54c905c` (previous
    `84491bf8-a14d-4d91-8ee0-09e9fac92ff7`, restorable).
  - **B1.4 was still INERT after that — found and fixed (migration 151).** Asked what "B1.4" means to
    the user and, while answering, checked the one assumption left: nothing in the system ever set
    `delivery_method = 'efectivo_usd'`. `marcar_destino_usd` only accepted clasica/tropical, and the
    deals-notes parser only read `ENTREGA EN USD: (Clasica|Tropical)`. So the RPC, context flags and
    photo capture waited on an operation that could never exist. Should have been caught when 150
    was built.
  - **User decisions (2026-09-29):** the bot collects the three data first, then the admin is
    NOTIFIED — the chat is NOT handed over and the bot keeps attending ("no es que deje de funcionar
    el bot en ese chat, más bien que le avise al admin en notificación").
  - **Migration 151:** the notes parser also accepts `Efectivo` → `'efectivo_usd'`; new
    notification type `entrega_efectivo_lista`; the RPC inserts one in-app notification per
    owner/admin only on the incomplete→complete transition. No `derivar_humano`, no assignment, no
    pause. Built on the LIVE parser body, not 042's: production and staging both run an unversioned
    edit (prosrc md5 `ac2d34c4…`) where the LAST `ENTREGA EN USD` mark wins; basing 151 on 042 would
    have silently dropped that. The rollback restores that live body byte for byte (hash verified).
    Assertion `cash-delivery-activation.sql` (8 cases, incl. last-mark-wins both ways and "chat not
    assigned/paused"): RED from the live baseline, GREEN on `wacrm-ensayo` and real staging; 150's own
    assertion still 9/9. Commit `0191532`.
  - **n8n staging:** `marcar_destino_usd` accepts `efectivo`; prompt: the tool line no longer says
    "clasica o tropical" only, and "SI ES EFECTIVO" now says to call `marcar_destino_usd('efectivo')`,
    ask only what's missing, and when complete tell the customer the team will coordinate zone and
    time — without calling `derivar_humano`. Verified byte-exact (only those 2 nodes changed),
    published `1610ae47-14d8-438f-ba21-1576b794514b`.
  - **Production DB:** 150 (schema part; its RPC body is superseded by 151's) and 151 applied.
    Verified by fingerprint: md5 of both function bodies and all three CHECK constraints are
    identical on production, staging and the rehearsal DB. RPC granted to `service_role` only. 5
    owner/admin profiles in production will receive the notification.
  - Known pre-existing edge, not changed: `marcar_destino_usd` skips appending a mark that already
    appears anywhere in the notes, so Efectivo → Clasica → Efectivo stays Clasica (same for
    Clasica/Tropical today).
  - **n8n production — DONE, B1.4 is live.** Patched production's OWN node contents (not copied
    from staging, which also carries B1.1/B1.2 and the staging-only service catalog): the
    efectivo block appended to `Contexto conversacion`, the three `foto_otro_wamid` hunks in
    `Snapshot final`, the efectivo changes to `marcar_destino_usd`, the three prompt lines in
    `Agente Remesas`, plus the two new nodes (`Registrar carnet efectivo`,
    `registrar_datos_entrega_efectivo`) with production's `Supabase Account` credential and their
    two connections. Every insertion anchor was confirmed to occur exactly once in production first;
    production's `Snapshot final` was byte-identical to staging's pre-B1.4 version.
    Independently verified the draft before publishing: all edited values exact, no stray
    `options.systemMessage` flat key, new nodes/credentials/connections exact, every other node and
    connection identical to the active version. The only non-exact value was `Snapshot final`: n8n
    again turned the two `\uXXXX` regex escapes into literal characters. It's identical after
    decoding, both regexes behave the same on every test string, and it's the same form staging has
    run since `a905531e`. Published `226791a1-2f7f-4189-8928-3096c87b1cda` (previous
    `49136979-7a6f-4dd4-a9a5-52d62c0597f1`, restorable). Read-only check against a production
    conversation: the new context columns evaluate correctly. n8n execution history returns nothing
    for this workflow (same as staging), so post-publish errors can't be monitored from here.
- **Eliminate `deals`** — new architectural request, needs scoping before anything else.
- **A6** — attempted to verify this myself before asking the user: staging's `ai_usage_log` table
  (columns `prompt_tokens`/`completion_tokens`/`total_tokens`) is exactly the right shape to check,
  but it has ZERO rows (confirmed `count(*) = 0`), and the "[STAGING] Cerebro - Recolector de tokens"
  n8n workflow (`j1SrhNxDe2SZhVbE`) has zero logged executions — that collection pipeline isn't
  actually feeding data yet. Still needs the user to confirm from wherever they originally observed
  the token spike (likely the model provider's own dashboard, not this DB) that completion tokens
  fell back to ~50-300 after the community-node reconnect.

## Staging test feedback (2026-09-30, ninth touch-point)

The user tested on the staging WhatsApp and reported two problems. Diagnosis and fixes:

- **The bot assumed CUP before being told.** The "COTIZACION SIN MONEDA DE DESTINO" rule was
  contradicted by the prompt's own examples ("quiero enviar 5 mil" answered in CUP), and the model
  copied the example. User decision: never assume — if the customer has not said the delivery way,
  the bot asks. The rule now lists every way (including efectivo) and says "PROHIBIDO asumir CUP";
  the contradicting examples were rewritten ("a Cuba" is not a destination currency).
- **After card + phone the bot did not say how much the recipient gets (B1.1).** Root cause: the
  operation is created with amount 0 when the beneficiary arrives and only gets a real amount at the
  deposit, so B1.1 could only fire after the deposit. Only `calcular_usd` left any trace;
  `calcular_envio` kept nothing. Fix = migration **153** (`cerebro_ultima_cotizacion`, one row per
  conversation and destination currency; `cerebro_registrar_cotizacion`; `cerebro_monto_recibe`,
  which prefers the open operation's own amount, else the quote in the currency of its delivery
  method, <24h and newer than the last closed remesa). The four quote tools now register the quote
  in the same query, and `Contexto conversacion` reads `monto_recibe_*` from `cerebro_monto_recibe`.
  Assertion `ultima-cotizacion.sql` 12/12. Commits `1aec2aa`, `e69949b`. Staging DB only.
- **A stale "100 USD" target in the test conversation** came from a 148 leak for returning
  customers (148 counted completed operations and old receipts). Fixed by migration **152** (only a
  vigente beneficiary on an OPEN operation, or a receipt newer than the last closed remesa, counts
  as commitment). Assertion 4/4. Commit `a9aea20`. Staging DB only.
- **Orphan shipment targets deleted** (user authorized): 14 rows in production
  `cerebro_objetivo_envio` (backup `odd/backups/2026-09-30-orphan-shipment-targets-production.sql`)
  and 1 staging test row.
- The n8n changes (4 quote tools + their parameters, `Contexto conversacion`, prompt) were
  syntax-checked against the staging DB (all four tool queries executed in a rolled-back
  transaction and registered the expected rows; the context query PREPAREs cleanly).
- **Published to staging n8n:** `57b65d4e-6d2b-4445-820a-f5d43f9d3fa1` (previous
  `1610ae47-14d8-438f-ba21-1576b794514b`, restorable). Independently verified before publishing:
  the 9 edited values equal the prepared files exactly, only those 6 nodes differ from the active
  version (and only in those parameters), node set and connections identical.

Pending: user re-test on staging with a NEW conversation (the old one has open operation
`eabf911d`); then, with explicit go-ahead, port 152, 153 and B1.1/B1.2 + the prompt change to
production (production has none of B1.1/B1.2 yet — surgical patches on production's own nodes).

## Quote message too heavy (2026-09-30, tenth touch-point)

User feedback on the re-test: the first quote reply (two amounts, four ways, efectivo, deposit
question) was correct but too loaded. User decision: when the destination currency is unknown, the
first reply asks ONLY the currency (CUP or USD) and, if still unknown, the deposit way (app or agent),
with no amounts; the amount goes in the next reply (CUP: only that amount + deposit data + card and
phone; USD: the USD amount for Zelle/Clásica/Tropical, noting efectivo has its own rate, and which
way). Prompt v2 built from the published staging prompt (only the rule lines 112-114, rule 5 and the
quote examples change; two follow-up examples added). The upload worker died on a rate limit, but it
had already landed the value: verified the draft equals the prepared file exactly and that
`systemMessage` is the only field changed in the whole workflow vs `57b65d4e`. Published to staging
`b5729202-ce9e-4b5d-8eef-7b495c2ec11a` (previous `57b65d4e`, restorable). Test number reset.

New convention (user): every staging test starts from zero. `supabase/staging/reset-test-contact.sql`
wipes the test number (commit `cc0704f`); run it before each test.

## Correction — 154 was a wrong diagnosis, reverted (2026-09-30, twelfth touch-point)

The eleventh touch-point claimed `Contexto conversacion` ran before the beneficiary was registered.
False: the n8n execution data shows it runs AFTER `Registrar beneficiario auto`, and in the CUP
test (execution `283700`) the context already had `monto_recibe_valor = 30000 CUP`; in the USD
re-test (`284279`) it had `38 USD`. Migration 154 was reverted (`git revert 9474a7a`; staging
function restored to 153's body, md5 7154b4a8…; assertion back to 12/12).

Real cause of the missing amount (both tests): the prompt. Line 96 and rule 6 ordered the fixed
closing "Apenas haga su depósito envíenos la captura por favor." "y NADA mas", and every example
closes that way; the separate B1.1 line asking to append the amount lost. Fix (prompt v3): the
closing sentence itself is an n8n expression that includes "y le hacemos la transferencia de
*30,000 CUP*." when the context has the amount (formatted with thousands separators), and the plain
sentence otherwise; same for the deposit-registered closing; the B1.1 line now says to copy the
closing as is. Expression checked in node against 30000 CUP / 38 USD / null / 20100.5.

USD re-test after the delivery-retry deploy: no lost message (card and phone 4 s apart both
reached the bot), beneficiary registered in the panel, operation `clasica`.
Prompt v3 published to staging `5441c97a-004f-4a22-aad3-e066edfb7933` (previous `b5729202`,
restorable). Verified before publishing: only `Agente Remesas` `options/systemMessage` changed,
equal to the prepared file; connections identical. Test number reset for the re-test.

## B1.1 decision (2026-09-30, user)
Stating the amount again at the beneficiary confirmation is repetitive: the amount is said once, in
the quote reply after the customer picks the currency. Prompt v3 reverted: staging restored to the
v2 content (`restore_workflow_version` of `b5729202` → `0ec90e4b-260c-4d4b-9c49-b7ced80f3a0b`,
verified node-by-node identical to `b5729202`, published). B1.1 is closed by this decision.
Consequence for the production port: the quote record (migration 153 + the four tools registering
their quote + `monto_recibe_*` from `cerebro_monto_recibe`) only fed the confirmation amount; the
B1.1 prompt line that uses it is effectively ignored. Before porting, decide whether to drop 153
and that line instead of carrying them to production.
Restoring v2 also restored the original B1.1 line, and the bot applied it once the deposit was
registered ("...le hacemos la transferencia de *120000 CUP*.", 13:41). Prompt v4 = v2 minus that
single line: published to staging `9b3cd809-3aa7-45b5-8649-5a529614be4e` (previous `0ec90e4b`);
verified only `Agente Remesas` `options/systemMessage` changed, equal to the prepared file. The
B1.2 test at 13:35-13:43 did not exercise B1.2 (beneficiary data sent before the forced
verification); repeat it with the verification BEFORE the card and phone. Test number reset.

## Production port (2026-09-30, user go-ahead: "pasa los cambios a produccion, verifica antes que no se rompa nada")
Scope: prompt (ask currency + deposit way, no B1.1 line), B1.2 (Contexto `deposito_ya_verificado`
+ Decisor branch, closing "Una vez realizada su remesa le notificaremos por acá."), migration 152,
WaCRM delivery retries. NOT ported: 153 and the quote-registration tool changes (unused after the
B1.1 decision), `monto_recibe_*`.
- B1.2 defect found BEFORE porting and fixed in staging and in the production patch: the flag
  counted a COMPLETED operation as "deposit already verified" and the Decisor note fired on every
  turn. On production data 121 conversations would have been flagged, 115 of them only because of
  a finished remesa (returning customers). Now: only an in-progress operation (not completed or
  cancelled) in ready_to_transfer/transferring, and the phrase only on the turn that brings the
  beneficiary's data (this batch has a card or phone, both known, not multi-beneficiary). With the
  fix, 6 production conversations flag. Both context queries PREPARE cleanly; Decisor syntax OK.
- 152 applied to production: live body was 148's (md5 b7a58018…) before; after, md5
  585f5579… = staging; still SECURITY DEFINER, not executable by anon.
- App: `516ebda` cherry-picked onto `privado/master` (2f3deb6) in worktree `prod-port-retry`
  (only the doc conflicted — the odd file is not shipped). Webhook tests 29/29, tsc clean, full
  suite 1435 pass / 2 fail; the 2 failures (`date-utils.test.ts` mondayIndex) also fail on
  2f3deb6 without the change (pre-existing, timezone-dependent).
- Production n8n published 2026-09-30 14:15 UTC: `3b40ee12-5bb2-4c4f-b006-c0d0c3f71d03` (previous
  `226791a1`, restorable). Verified before publishing: node set, connections and settings identical;
  only `Agente Remesas` systemMessage, `Contexto conversacion` query and `Decisor` jsCode changed,
  each equal to its prepared file; production's original Decisor with `\uXXXX` escapes decoded
  differs from the new one ONLY by the B1.2 hunks. Staging carries the same B1.2 fix
  (`eb85f86b-7a95-467b-b84f-e458cd4b5b98`). No production executions yet since the publish.
- App: `6468a98` pushed to `privado/master`. FINDING: pushing does NOT deploy. Both repos'
  `deploy.yml` are `workflow_dispatch` only; `wacrm-produccion` has never run Actions, and the last
  deploy run in `wacrm` was 2026-08-21. Production is deployed by
  `infra/deployment/desplegar-wacrm-produccion.sh <sha>` over SSH to `oracle`. So the earlier
  "pushed, should auto-deploy" entries (B2.2, B3.2, B4.3 app parts) are UNVERIFIED — production may
  not serve them. Needs the user's authorization for SSH to `oracle` to check and deploy.
- App deploy (user authorized SSH to `oracle`, 2026-09-30): production was serving `581aba3`
  (feature branch, deployed 09-29 03:28), NOT `privado/master`. `privado/master` is a different
  line: deploying `6468a98` would have removed ~18k lines of what production runs. NOT deployed.
  None of B2.2/B3.2/B4.3/145/sound/retry were live. Deployed the feature branch `1b93cd0` instead:
  DB prerequisites checked on production first (145 realtime, 147 column, 149 fn, 150 column+fn).
  Full suite 1655 pass / 2 fail (the same `date-utils` mondayIndex tests fail on `581aba3`), tsc
  clean; artifact built in a `node:20` container with the official `build-wacrm.sh` (money-path
  tests 114/114), manifest `production` + ref `hqztotshnlzaiziwjyzh`, bundle has no staging ref.
  Deployed with `desplegar-wacrm-produccion.sh`: current → `1b93cd0…`, anterior → `581aba3…`
  (rollback: `rollback-wacrm-produccion.sh`); served BUILD_ID `dbt-zylYTmLPLWZTqQuUR` confirmed on
  the live domain, pm2 online, no restart loop, `/login` 200.
- Production bot errors since 14:44 UTC: the image node `Vision clasificar y extraer` fails with
  OpenAI 429 "You have no credits remaining" (credential "CRM audio vision"). Not caused by the
  port; receipts/cards in images cannot be read until credits are added. All 19 errors classified:
  15 in `Vision clasificar y extraer` (gpt-4o image analyze) and 4 in `Transcribir audio`
  (gpt-4o-transcribe), every one OpenAI 429 `insufficient_quota`/`credit_balance_exhausted`, same
  credential `CRM audio vision` (`BHpcqLjEuUJbQ0eB`); 10 of them are automatic `cerebro.reintento`
  retries hitting the same wall. No other error. Fix = add credits (user); no workflow change.
- Follow-up (user): the B3.2 edit button was too big. `eae37b0` makes it a 32 px pencil icon
  button (aria-label/title "Editar"); TDD RED→GREEN, calculator tests 22/22, tsc + eslint clean.
  Deployed to production with the same procedure: current → `eae37b0…`, anterior → `1b93cd0…`,
  BUILD_ID `Aw94vYjb3SFP8mTzYWX5b` served; the served bundle contains `legacyIconButton`.
- Follow-up (user): the Acciones column stayed wide around the small icon. `1fede6c` gives that
  column `width: 1%; white-space: nowrap` (fits its content; `width: auto` in the phone layout).
  TDD RED→GREEN, calculator tests 23/23. Deployed: current → `1fede6c…`, anterior → `eae37b0…`,
  BUILD_ID `MSsIdjiDZUYLavv7ma2Nd` served.
