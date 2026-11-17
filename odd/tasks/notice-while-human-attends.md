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
- [x] T1 Migration 375 `cerebro_humano_atendiendo(conv)`: assertion RED then GREEN on staging; related assertions
- [x] T2 Notifier: `leer-secreto.sql` adds `humano_atendiendo`; `filtrar.jscode` drops the question when it is true; vitest RED then GREEN
- [x] T3 Staging: publish both nodes to the staging notifier `OCdJoHTkV6S0aAdk` (not executed)
- [x] T4 Production: migration 375, then both nodes on `wGud0KGR6eMqqfMQ`

## Acceptance criteria
- A human message 2 minutes ago, or a live pause, or a live assignment -> true; the same facts expired, a bot/notifier message, a panel
  action, or a message from before the last hand-back to the bot -> false; unknown conversation -> false.
- Notice for a deposit verified by hand with data missing: with a person attending -> only "Su deposito de X ya fue verificado."; without
  -> the question as today. Notice with data complete, completed notice and incident alert -> unchanged in both cases.

## Progress / evidence
- T1 (2026-11-15, commit de3669c3): assertion `human-attending.sql` RED on the base (function absent), GREEN after migration 375 on
  staging (`staging-migracion.sh aplicar`: dry-run/apply/assertion/rollback OK, md5 equal; function ACL postgres + service_role). 20
  expectations. The first run failed one case (6b) because of the fixture, not the function: the BEFORE trigger
  `cerebro_marcar_asignacion` sets `assigned_at = now()` whenever `assigned_agent_id` changes, so the fixture sets the date in a second
  UPDATE. The assertion also proves the function is read-only (an expired pause and an expired assignment are NOT released).
- T2 (commit 6ca6375e): `npx vitest run pruebas/notificador` RED 4 of 30 (the three behaviours and the SQL), GREEN 30/30. Notifier
  code md5 8922953f -> 724f1f26; "Leer secreto" query adds `humano_atendiendo`. The new query ran against a real staging operation
  (read-only transaction): returns `humano_atendiendo=false` with the other fields intact. `node_modules` of this worktree was missing:
  symlinked to the main checkout's (vitest 4.1.9), git-ignored.
- T3 (2026-11-15): staging notifier OCdJoHTkV6S0aAdk 2de5ce1c -> 0b488e1f (= active), 5 nodes, md5 of both nodes equal to the repo
  copies, backup `notificador-staging-OCdJoHTkV6S0aAdk-2de5ce1c-…-antes-humano-atendiendo.json`. Not executed.
- Production dry run (nothing written): `produccion-migracion.sh previa` and the publish script in simulation, live notifier
  wGud0KGR6eMqqfMQ d631f1a4, Filtrar 8922953f, as expected. Order for production: migration 375 FIRST (a node that calls a missing
  function breaks the whole "Leer secreto" read), then the two nodes. Rollback: restore the node backup, then ROLLBACK-375.
- Known limit: in conversation 5a4c0ab8 the Decisor recorded `humano_reciente = false` at 14:42:36 although a person wrote at 14:40:59,
  so the admin may have handed the chat back before the notice; this rule may not have covered that exact moment. What removes that
  case is capture mode (production since 2026-11-15), which stores the account and holder when the customer sends them.

- T4 production (2026-11-17, owner "si"): `OK 375_human_attending_fact 20261117164627`, verificar 1/1 EQUAL (e432ea28). Notifier
  wGud0KGR6eMqqfMQ d631f1a4 -> abeed618 (= active), 5 nodes, Filtrar 724f1f26 and Leer secreto c7466e35 equal to the repo copies, backup
  `notificador-produccion-wGud0KGR6eMqqfMQ-d631f1a4-…-antes-humano-atendiendo.json`. Rollback: restore that backup, then ROLLBACK-375.
- Seen while checking (not mine): the production Cerebro has an UNPUBLISHED draft (saved 2026-11-17 06:16 UTC, 126 nodes) that removes
  "Claude Haiku (OpenRouter)", "DeepSeek sin pensamiento (comunidad)", "OpenAI Chat Model" and "Silencio"; the active version is still
  451889bd with Decisor 45374132, the capture node and the lock. A publish of that draft keeps them (they are not among the removed).

## Next step
Watch the first manual verification with a person attending (notice must be the verified sentence only) and the first capture turn.
