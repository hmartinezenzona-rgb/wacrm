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

- A1 (asked 2026-09-29, second session): what must a duplicate receipt surface? Evidence: the
  staging `Decisor` already words the reply by the REAL stage of the original deal (`dup_etapa`:
  Entregada / Lista para transferir / Incidencia / otherwise "still verifying"), and every
  `comprobantes_hashes` row since 2026-09-28 in prod has its deal (19 of 19), so a duplicate is a
  true resend of a registered receipt, not a lost one. What is missing is only an admin-visible
  trace. But a customer resending a receipt while anxious is common, so alerting on every duplicate
  may be noise. Options for you: (a) a quiet marker on the original deal/chat, no alert; (b) an
  alert only when the original is not yet verified; (c) an incident on every duplicate. Not
  implemented until you choose.- A3 — no expiry rule is decided yet for `cerebro_objetivo_envio`. Root cause is fully diagnosed
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

  - Committed as `6437b40`.

## Next step
Second session: n8n restored, A2 not reproducible (see above). Next loop tick: A1 (duplicate receipt
surfaces an incident), then A4/A5, each behind a vitest harness for the extracted Code node.
Earlier state: B3.1, B3.3, B4.1, B4.2 done. Remaining unchecked tasks all either need a user decision (A3, B3.2,
B4.3, B4.4, and the B4.1 reversal question — all above) or are blocked by the n8n MCP disconnect (A1,
A2, A4, A5, A6, B1.1-B1.4, B2.1-B2.2). No further decision-free, non-n8n work is available in this
document until the user answers one of the open decisions or n8n access is restored.
