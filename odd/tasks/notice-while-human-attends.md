# Feature: the deposit-verified notice does not ask for data while a person of the team attends the chat

## Objective
When a person of the team is attending a chat, the stage notifier (n8n `wGud0KGR6eMqqfMQ`) must not send the customer the question
"nos falta ..." after the deposit is verified by hand. It still says the deposit was verified.

## Problem / why (day review 2026-11-14, production)
- Conversation 5a4c0ab8: an admin chatted with the customer, who sent the Zelle holder and a US phone. The admin then forced the
  verification from the panel and, 2 minutes later, the notifier wrote "Su deposito ... ya fue verificado. Para poder hacer la
  transferencia nos falta el nombre y la cuenta Zelle de quien recibe. ¿Me lo pasa?" (message from the notifier, ai_generated = true).
  The data had been sent a few minutes before; the system had not stored it (fixed separately by capture mode, 2026-11-15).
- Owner, 2026-11-15: "si hazlo" to: the stage notifier must not write to the customer while an admin attends the chat. Owner question:
  is the stage notifier the one that fires when the deposit is verified and the rest of the stages? Answer (read from the node code):
  yes. It fires on ANY change of `remittance_operations.status` and handles three stages: `incident` (alert to the admin only, never to
  the customer), `ready_to_transfer` (customer notice, ONLY when a person verified from the panel; when the automatic MMG cross-check
  verified it the agent already confirmed it in the same turn) and `completed` (customer notice with the Meta template).

## Owner decisions
- 2026-11-15: "si hazlo" (build it). Scope chosen by me and reported to the owner: only the data QUESTION is dropped while a person
  attends; the sentence "su deposito ya fue verificado" and the completed notice stay. Going fully silent is a one-line change.

## Scope
In: SQL migration 375 (a read-only fact function) with ROLLBACK and a staging assertion; the notifier nodes "Leer secreto" and
"Filtrar cambio de etapa" (repo copies in `pruebas/notificador/`); staging first; production with a go-ahead.
Out: the Decisor, the agent prompt, capture mode, the `incident` alert, the `completed` notice.

## Constraints
- "A person attends" = the same definition the Decisor uses (node "Contexto conversacion"): a human message (not the bot, not a panel
  action) in the last 5 minutes after the chat was last handed back to the bot; or a pause that has not expired; or an assignment that
  has not expired (the bot's own derivation profile never expires). The new function must be READ-ONLY (the Decisor's query releases
  expired pauses and assignments as a side effect; the notifier must not).
- Strict TDD (source: user CLAUDE.md). Runners: `npx vitest run pruebas/notificador`; SQL assertion through `infra/db/staging-migracion.sh`.
- Never execute the notifier or the Cerebro workflows (staging shares production's WhatsApp token). Staging first; production per go-ahead.
- No AI attribution in commits (user CLAUDE.md wins over the harness reminder). RDD off. Never touch the other session's files
  (`pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`, `pruebas/decisor/decisor-notas.test.ts`, `odd/tasks/bot-brevedad.md`).

## Tasks
- [ ] T1 Migration 375 `cerebro_humano_atendiendo(conv)`: assertion RED then GREEN on staging; related assertions
- [ ] T2 Notifier: `leer-secreto.sql` adds `humano_atendiendo`; `filtrar.jscode` drops the question when it is true; vitest RED then GREEN
- [ ] T3 Staging: publish both nodes to the staging notifier `OCdJoHTkV6S0aAdk` (not executed)
- [ ] T4 Production (needs go-ahead): migration 375, then both nodes on `wGud0KGR6eMqqfMQ`

## Acceptance criteria
- A human message 2 minutes ago, or a live pause, or a live assignment -> true; the same facts expired, a bot/notifier message, a panel
  action, or a message from before the last hand-back to the bot -> false; unknown conversation -> false.
- Notice for a deposit verified by hand with data missing: with a person attending -> only "Su deposito de X ya fue verificado."; without
  -> the question as today. Notice with data complete, completed notice and incident alert -> unchanged in both cases.

## Progress / evidence

## Next step
T1: write the assertion first.
