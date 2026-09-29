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
- [ ] B1.5 — Chat notifications: (a) a sound per incoming chat message, like WhatsApp; (b) "marcar
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
- [ ] B3.3 — Some remesas verified and delivered from the right panel still show "Awaiting Deposit".
  Find and fix the status update.

### B4. Calculator and panel
- [ ] B4.1 — Completing or deleting ("Borrar") a remesa updates or clears the calculator
  automatically.
- [ ] B4.2 — The calculator updates in real time when a remesa completes, with no page refresh.
- [ ] B4.3 — The admin can complete a remesa without a prior deposit verification (force or skip),
  e.g. when the bot was paused.
- [ ] B4.4 — Delete operations or records from the calculator module.

## Open decisions (filled in as tasks reach them)

## Progress
- 2026-09-29: document created from the user's list and the live test.
  - The live test of per-beneficiary proofs PASSED: 2 proofs stored for op 17e82489, both images
    and captions arrived in the chat.
  - After the test, restored: the test op was cancelled (its ledger line voided); Carolina's
    deposit 20397391101636 went back to its original deal/dates; comprobantes_hashes row
    restored; unfed view 0.

## Next step
Triage and order (the user chooses how to run it: loop or supervised).
