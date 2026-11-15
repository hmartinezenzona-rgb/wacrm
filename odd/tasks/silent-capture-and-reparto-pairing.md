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
- [x] T3b n8n production: same node (migration 374 first)
- [ ] T4 Stage notice while a human attends: find where "nos falta el nombre y la cuenta" is produced and decide with the owner
- [x] T5 Publish the Decisor to production (staging does not use this copy); watching the first real split is pending

- [x] T6 Capture mode for every kind of send (owner 2026-11-15: "debe aplicarse a toda operacion no solo zelle"): Decisor routes a
      human-attended batch that carries data to the agent with `captura: true`; tests; replay; model check
- [x] T7 Split data in any order (owner 2026-11-15): pairing by position for block shapes, by adjacency otherwise; what cannot be
      paired is named so the bot asks only about it; tests
- [x] T8a n8n staging: lock on "Respuesta valida?" (an answer of a capture turn is never sent)
- [ ] T8b n8n production: the same lock, then Decisor 45374132 (needs go-ahead; lock FIRST)

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

- Production (2026-11-15, owner "si pasalo a produccion"): previa SEGURO (function NEW); `OK 374_silent_capture 20261115163145`,
  verificar 1/1 EQUAL (ea5bd647). Node: Cerebro jEzlVLCLUaJhVwzs 580ca551 -> bae80cdf, 129 -> 130 nodes, backup
  `produccion-jEzlVLCLUaJhVwzs-580ca551-…-antes-captura-silencio.json`, credential cloned from production's own reader. Decisor:
  bae80cdf -> 1ce8c7d4 (= active), md5 3219bc40 -> 8b1fbe6e, repo match yes, backup `…-bae80cdf-…-20261115-103219.json`.
  Rollback order: restore the Decisor backup, remove the node (restore the 580ca551 backup), then ROLLBACK-374.
  Not yet seen with real traffic: a silent capture, a paired split.

- T6/T7 (2026-11-15, Decisor md5 45374132, was 8b1fbe6e): 144/144 vitest (`npx vitest run pruebas/decisor/produccion`). The code was
  written before its tests this time (order slip); the tests were added right after and one defect they exposed was fixed (a wrongly
  copied fallback line). Capture applies when the chat is paused by hand, assigned or a human wrote in the last 5 minutes, AND the batch
  carries data (6+ digit run, e-mail, card/phone/Zelle/ID photo in the snapshot, or address/holder words), AND a send is open or the text
  asks for a new one; hidden chats and admin messages stay silent; a batch without data stays silent with the same reason as before.
  Regression replay, old Decisor 3219bc40 vs new, clock frozen at each execution's start: 42 production executions still kept by n8n
  -> 41 identical, 1 different (739599, the split note); the 12 saved executions of the two cases -> 10 identical, 736897 goes from
  `silencio` to `agente CAPTURA`, 739599 changes its split note.
  Model check with the production contract (prompt, model, tools mocked), 3 runs each: capture case -> registrar_beneficiario_zelle
  called 3/3 with the account and the holder taken from the customer's free sentence, answer exactly SKIP 3/3; split case ->
  registrar_reparto_multiple called 3/3 with both phones paired, phones shown in the confirmation, only the amount asked.
- T8a (2026-11-15): staging Cerebro dd7dc9ce -> 7b6eff78 (= active), "Respuesta valida?" 4 -> 5 conditions (AND), the new one
  `$('Decisor').first().json.captura === true` must be false; false output goes to "SKIP - no responder". Checked on the production
  graph: the only customer send after the agent is behind that IF. Staging's Decisor is another lineage and never sets `captura`.
- Known limits: a capture turn stores the model's "SKIP" in the chat memory like any skipped turn; a registration made in capture can
  move the send to the next stage and the stage notifier may then message the customer (same as when an admin verifies by hand: T4).

## Next step
Watch the first human-attended chat with a Zelle account (tool_execution_log / recipient with source of the reader) and the first split
with interleaved phones. Then T4: owner decision on the stage notice asking for data while a human attends.
