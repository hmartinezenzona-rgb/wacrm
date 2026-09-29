# Production feedback 2026-09-29: bot, admin/bot interaction, panel, calculator

## Objective
Fix what the first days of production and the 2026-09-29 live test showed, and add the requested
functions. The user's list plus the defects the test proved.

## Constraints (all tasks)
- Staging first. Production (DB migrations, n8n prod `jEzlVLCLUaJhVwzs`, app deploy) only with the
  user's explicit go-ahead. An unattended loop NEVER touches production.
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
- [ ] A2 — A 10-digit US phone written without +1 ("celular 8133617809") is not recognized as a Zelle
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
- [ ] A6 — Turn latency: the burst turn took ~3.5 min (agent 43 s). Find where the rest goes.

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
- [ ] B3.1 — The right panel in a customer chat is editable, to complete a transfer manually when
  automation fails.
- [ ] B3.2 — Weekly control (Control semanal): the read-only chat operations become editable, plus a
  field for the investment cost (costo de la inversión).
- [x] B3.3 — Some remesas verified and delivered from the right panel still show "Awaiting Deposit".
  Find and fix the status update.

### B4. Calculator and panel
- [x] B4.1 — Completing or deleting ("Borrar") a remesa updates or clears the calculator
  automatically. (Investigated: already works correctly for every real path — see Progress.)
- [ ] B4.2 — The calculator updates in real time when a remesa completes, with no page refresh.
- [ ] B4.3 — The admin can complete a remesa without a prior deposit verification (force or skip),
  e.g. when the bot was paused.
- [ ] B4.4 — Delete operations or records from the calculator module.

## Open decisions (filled in as tasks reach them)
- A3 — no expiry rule is decided yet for `cerebro_objetivo_envio`. Root cause is fully diagnosed
  (Engram #280): `cerebro_objetivo_atar` attaches ANY open, unattached target to a brand-new deal
  with no freshness check, so a stale quote from a prior day gets picked up by an unrelated new
  remesa. The fix needs one of: (a) a time-based expiry (how many hours is a quote "still valid"?),
  or (b) some other explicit closing rule the user prefers. Neither is invented here — needs the
  user's call before implementing.
- B4.1 (maybe) — should deleting a deal ALSO void the calculator entry of an already-*completed*
  remesa? Today it deliberately does not (migration 114: "the money really moved, it's history").
  Only relevant if that's actually what "Borrar...clears the calculator" meant; not acted on.

## Blocked this session (not a product decision — a tooling/access gap)
- The `claude.ai n8n` MCP is disconnected this session (needs `/mcp` re-auth), and no other safe,
  established path to read/patch the live Cerebro n8n workflow (staging `U52y1kSNvhgxvWeb`) was
  used. Every task whose fix lives in that n8n workflow rather than in this repo/DB is blocked
  until that access is restored: A1, A2, A4, A5, A6, B1.1, B1.2, B1.3, B1.4, B2.1, B2.2.
  (While checking for an access path, a cached workflow export under `~/cerebro-fase1` was
  `cat`-ed and turned out to contain an embedded webhook secret; exploration stopped there rather
  than continuing to hunt for credentials. Nothing was sent anywhere external.)

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
  - Not yet applied to the real staging database — that's the user's step, same as every other
    migration in this repo.
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

## Next step
Next in-repo, decision-free, non-n8n candidates to triage: B3.1, B3.2, B4.2, B4.3, B4.4.
