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
- DeepSeek evals only with a staging credential that is NOT "DeepSeek account" (f0K27ImOFO3QdL34 =
  production balance). Until the user's staging key is visible in n8n, no model evals.
- Money-path changes (calculator, ledger, delivery) need SQL assertions and vitest, strict TDD.
- A task that needs a product decision stops at the decision and lists it under "Open decisions";
  nothing is invented.
- Replies to the user in Spanish; artifacts in English.

## Tasks

### A. Defects proven by the 2026-09-29 live test
- [ ] A1 — A duplicate receipt (same image hash) is dropped silently. No deposit, no op, no incident,
  and the bot still says "lo estamos verificando". It must surface: an incident / admin alert, and
  honest bot wording. (Dedup comprobantes → comprobantes_hashes.)
- [x] A2 — A 10-digit US phone written without +1 ("celular 8133617809") is not recognized as a Zelle
  account by `Snapshot final`.
- [ ] A3 — A quote's shipment target (`cerebro_objetivo_envio`) never expires. Yesterday's
  "100 USD → 26,000" became today's target and raised a false "DEPOSITO DE MAS". It must expire or
  close when a new remesa starts. The user: "no me parece que deba seguir".
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
- [ ] B2.1 — While the bot is paused by a human, keep extracting data (cards, phones, names) in the
  background and update the panel silently. It must not reply.
- [ ] B2.2 — The bot pauses ONLY when an admin writes in the chat. Panel actions (sending a proof,
  completing a remesa) must not pause it.

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
- [ ] B4.4 — Delete operations or records from the calculator module. — **partially satisfied,
  partially needs a decision, see below.**

## Open decisions (filled in as tasks reach them)

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
  original deal or chat where an admin can see it, without notifying anyone.- A3 — no expiry rule is decided yet for `cerebro_objetivo_envio`. Root cause is fully diagnosed
  (Engram #280): `cerebro_objetivo_atar` attaches ANY open, unattached target to a brand-new deal
  with no freshness check, so a stale quote from a prior day gets picked up by an unrelated new
  remesa. The fix needs one of: (a) a time-based expiry (how many hours is a quote "still valid"?),
  or (b) some other explicit closing rule the user prefers. Neither is invented here — needs the
  user's call before implementing.
- B4.1 (maybe) — should deleting a deal ALSO void the calculator entry of an already-*completed*
  remesa? Today it deliberately does not (migration 114: "the money really moved, it's history").
  Only relevant if that's actually what "Borrar...clears the calculator" meant; not acted on.
- B3.2 — "Control semanal" IS the `/calculadora` page. Its "Operaciones del chat" table is genuinely
  read-only today, and "investment cost" is not a new concept — `invertido_gyd` already exists
  (095/104, auto-computed from the buy/sell rate spread) and is already shown as "Inv. (GYD)". Open
  questions, none invented: which columns become editable (facturado/invertido/retorno? customer/
  amount too?), who may edit (admin-only, like rates?), should edits be audited like
  `crm_corregir_operacion` already does elsewhere, and does `retorno_gyd` stay derived from the
  others or become independently editable.
- B4.3 — the DB gap is real and narrow (`crm_forzar_verificacion` only accepts
  `status IN ('deposit_verification','incident')`, so the actual "bot was paused" scenario — status
  stuck at `collecting_information`/`awaiting_deposit`/`deposit_received` — has no admin override at
  all today), but making it usable is not just a backend guard widen: `DepositReviewContainer` hides
  the whole force-UI when there are zero receipts, and `DepositReviewSection` itself returns nothing
  unless `canVerify` is true — both tied to the same status set. Enabling this for earlier statuses
  means designing what the panel looks like with zero receipts and no deposit to review — a real UI
  decision, not just widening a guard. Not invented.
- B4.4 — the manual weekly log (free-text, "Limpiar Todo") already supports deleting a line by
  editing the text — that half is satisfied, no decision needed. The auto-fed ledger
  (`remittance_calculator_entries`, `source='completed_operation'`) has no delete/void path today,
  and adding one bypasses migration 114's deliberate "money moved, it's history" design — same open
  question as B4.1 above (hard delete vs. reversible void, audit trail, who's allowed). Only
  relevant if "the calculator module" in B4.4 means the auto-fed ledger rather than the manual log.

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

## Next step
Second session: A2 and A6 checked; A1 and the A6 fix wait on Open decisions; A4/A5 wait on the user
enabling "Available in MCP" for `Yu0uskQhydWgNFEy`. Next loop tick: B1.1 (deterministic wording in
the staging `Decisor`, testable with the extracted-Code-node harness, no model evals), then B1.2,
B2.x. Earlier state: B3.1, B3.3, B4.1, B4.2 done.
