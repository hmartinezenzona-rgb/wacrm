# Feature: capture data silently while an admin attends, and pair phones to cards by arrival order

## Objective
1. While a human of the team attends a chat the bot stays silent (as today) but still stores the data the customer sends, so the
   operations panel is already filled when the admin finishes and nobody asks the customer for data he already gave.
2. In a split between several cards, a phone that arrives next to its card is paired with it and is not asked for again.

## Problem / why (day review of 2026-11-14, production)
- Conversation 5a4c0ab8, exec 736897: an admin was chatting; the customer sent the Zelle holder and a US phone plus the receipt.
  The Decisor routed `silencio` ("un humano del equipo acaba de escribir"). The deposit was auto-registered (operation fb66ab87
  created), `Merge beneficiario` kept the account (`zelle_cuenta_final`), but nothing wrote it to the operation: the node
  `Registrar zelle auto` has been DISABLED since 2026-10-27 (odd/tasks/zelle-multi-recipiente.md: the single-block reader overwrote
  what the agent registered for several recipients), so a Zelle account is stored only by the agent tool, and the agent does not run on
  the silence route. The admin forced the verification and the stage notice asked for "el nombre y la cuenta Zelle" three minutes after
  the customer had sent them. The admin then added the recipient, redid the calculator line and closed by hand.
  Also seen: `Snapshot final.zelle_celulares` carried the same number twice, so "one single account" was false for one account.
- Conversation 566b3200, exec 739599: the batch was card (text), phone, card (photo), phone. The Decisor note said the phones had no
  owner ("el celular que corresponde a cada tarjeta") and told the agent to ask; the agent called `registrar_reparto_multiple` with empty
  phones and asked for each phone again (two extra customer messages).
- Owner, 2026-11-15: when an admin attends the bot must not answer but must collect the data and build the operations panel, so the data
  is there when the admin finishes and redundant questions are avoided; fix the split case at root.

## Owner decisions
- 2026-11-15: both fixes authorized. Production writes still need a go-ahead per step.

## Scope
In: production Decisor copy (`pruebas/decisor/produccion/`), SQL migration(s) with ROLLBACK and staging assertions, one n8n node on the
silence branch (staging first), the stage notice when a human is attending (explore first).
Out: the other session's files (`pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`, `pruebas/decisor/decisor-notas.test.ts`,
`odd/tasks/bot-brevedad.md`); the agent prompt; re-enabling `Registrar zelle auto` on the agent route (the reason it was disabled stands).

## Constraints
- Strict TDD (source: user CLAUDE.md). Runners: `npx vitest run pruebas/decisor/produccion`; SQL assertions in rolled-back transactions
  through `infra/db/staging-migracion.sh`. RDD off. No AI attribution in commits.
- Never execute the Cerebro or notifier workflows. Staging first; production only with an explicit go-ahead per step.
- Silent capture must never send anything to the customer and must not overwrite recipients the agent or an admin registered.
- Customer data stays out of commits and Engram (ids and counts only).

## Tasks
- [x] T1 Decisor: pairs by arrival order in the "ENVIO A VARIOS BENEFICIARIOS" note (tests, replay on exec 739599)
- [x] T2 Silent Zelle capture: SQL function (guards: human-attending silence, exactly one distinct account in THIS batch, no multi
      recipients, never overwrite) + assertions; map which other data types are agent-only on the silence route
- [x] T3a n8n staging: node "Captura en silencio" between "Silencio admin" and "Cerrar lote"
- [ ] T3b n8n production: same node (needs go-ahead; migration 374 first)
- [ ] T4 Stage notice while a human attends: find where "nos falta el nombre y la cuenta" is produced and decide with the owner
- [ ] T5 Publish the Decisor (staging does not use this copy; production with go-ahead) and watch the first real split

## Acceptance criteria
- Exec 739599 replayed through the new Decisor: the note lists card 1 with phone 1 and card 2 with phone 2 and forbids asking for them.
- An order that does not tell the owner of each phone, a different count, or a workflow without the batch nodes keeps the old note.
- Exec 736897 shape on staging: silence route + one Zelle account in the batch + open operation -> the account is stored on the
  operation with no message to the customer; two accounts or an existing agent/admin recipient -> nothing is written.

## Progress / evidence
- T1 (2026-11-15): RED 2 of 5 new tests (the two pairing cases; the three "keeps asking" guards green), GREEN 136/136
  (`npx vitest run pruebas/decisor/produccion`). Decisor md5 8b1fbe6e (was 3219bc40). Replay of the saved production execution 739599
  with the new code: route `agente`, note "1) tarjeta ****5761 con celular …; 2) tarjeta ****1089 con celular …" and the prohibition.
  Shapes accepted: card-phone repeated, or all cards then all phones (2-3 cards, same count). The harness stub now serves the optional
  nodes `Armar snapshot` and `Parsear vision`.

- T2 (2026-11-15, migration 374 `cerebro_capturar_en_silencio`, commit 09f4363f): staging-migracion aplicar = dry-run/apply/assertion/
  rollback OK. Assertion `silent-capture.sql` (9 case groups): RED on the base (function absent), GREEN after. Related
  (pattern guardar_zelle|zelle_auto|silent, --ya-aplicada): TOTAL 40, SAME 39, DIFF 1 (silent-capture RED->GREEN). The write is the
  unchanged `cerebro_guardar_zelle_auto`.
- T3a (2026-11-15): staging Cerebro U52y1kSNvhgxvWeb 59b29594 -> dd7dc9ce (= active), 132 -> 133 nodes, backup
  `staging-U52y1kSNvhgxvWeb-59b29594-…-antes-captura-silencio.json`. Node cloned from staging's `Registrar zelle auto` (credential
  Supabase STAGING), `onError: continueRegularOutput` so a failure never keeps the batch open. Not executed (rule). The parameter
  expression evaluated offline against the saved production exec 736897 gives: reason "un humano del equipo acaba de escribir", empty
  holder, the same account twice, multi false.
- Found while exploring T4: the 14:43 message to the customer came from the stage notifier (workflow wGud0KGR6eMqqfMQ, node "Filtrar
  cambio de etapa", `ready_to_transfer` with a missing recipient), not from the agent (exec 736911 answered SKIP). With the account
  stored it would still have asked for the holder's name, which the customer had written in free text and the snapshot did not extract.
- Still agent-only on the silence route (not captured while a human attends): recarga numbers, cash-delivery data, Mexico recipient,
  combo recipient, a split between several cards.

## Next step
Owner go-ahead for production: migration 374, the node (T3b), Decisor 8b1fbe6e (T5). Then T4: decide with the owner whether the stage
notice drops its question while a human attends.
