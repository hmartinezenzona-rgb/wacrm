# Bot conversation format, phase 2: layout inside one message + owner decisions

## Objective

Make each bot reply easy to read on a phone without splitting it into several messages (that is
phase 3), and apply the owner's business decisions of 2026-10-28, on the live production Cerebro
(versionId bb175eda, Decisor a6ae5ae5, prompt = phase 1).

## Decisions (owner, 2026-10-28)

- Over-deposit: an admin is notified and resolves it with the customer (the bot only says a person
  reviews it).
- Group link: sent to a NEW customer, ONCE only, ever.
- Thousands separator: keep the current comma (26,000 GYD); decimals keep the dot. No change.
- No emojis in bot text.
- Business days: Monday to Saturday; only Sunday closed. Hours come from `cerebro_config`
  (`horario_abre` 09:00, `horario_cierra` 17:00, `dias_cerrados`); already used by the Decisor.
- "5 mil pesos" without a surname in a single remittance = GYD deposited (rule from the
  2026-10-27 work, owner-approved then).
- Customers send data in any order: ask one thing at a time, accept everything.

## Scope

1. Layout rules (prompt, replacing conflicting ones): one datum per line ("Etiqueta: valor"),
   blank line between blocks, at most one question and it goes last, bold only amounts and states
   (at most about 3 per message), every figure with its currency, no emojis.
2. Grouped confirmation for several recipients: one block per recipient with its data and what is
   still missing; ask for one missing item at a time.
3. Group link once to a new customer: Decisor note with the literal text (usted: "Únase") and a
   reliable "already sent" signal. Production `Contexto conversacion` has no `mensajes_cliente`;
   proposed new read-only field: whether any earlier agent message in the conversation contains
   the group link (to be validated with a SELECT before touching the node).
4. "5 mil pesos" as GYD (port from the uncommitted staging-lineage diff, adapted).
5. Out-of-hours line: when closed and the reply talks about a deposit, verification or transfer,
   the hours line is required (real misses: 2026-10-27 19:35 verified deposit + missing data;
   2026-10-28 08:02 cash question).
6. Verify that an over-deposit incident notifies an admin (read-only check).

## Out of scope

- Message splitting (phase 3), digit grouping of cards and phones (the model must not rewrite
  digits; a code-side formatter would be phase 3), thousands separator.

## Constraints

- Never execute the workflows. Backup before writes; owner go-ahead before every production write.
- Do not touch `pruebas/decisor/decisor.jscode`, `correr.ts`, `decisor-notas.test.ts`,
  `odd/tasks/bot-brevedad.md` (staging lineage, uncommitted, from another session).
- The gold battery costs the owner a lot: before publishing, ask whether to run a reduced one.

## TDD

- Strict, on. Runner `npx vitest run pruebas/decisor/produccion`.

## Tasks

- [x] F2.1 Decisor (writer + parent). Group link: `!ctx.es_admin && ctx.grupo_enviado === false &&
  !(h && Number(h.envios_previos) > 0)`, fails closed while the field is missing. "5 mil pesos" in
  the `CALCULO A HACER` block (cuanto-llega branch + plain statement, CUP card route, off with
  cubanos/guyaneses or another rail). Closed + deposit turn (comprobante, Por verificar, Lista para
  transferir, or deposit/transfer/comprobante/transid words): hours line mandatory. Writer RED 9 ->
  GREEN. Parent: the notes still asked for card/phone/Zelle data in bold, against the owner's rule;
  4 notes now say one per line without bold. RED 3 -> GREEN. `npx vitest run pruebas/decisor`
  157/157; md5 `0a31fc73`. Business name stays bold (presentation), unchanged.
- [x] F2.2 `Contexto conversacion`: `grupo_enviado` added after `cierra_cortesia` (no semicolon or
  backslash, per the node's own warning). Validated with PREPARE on production (parses, nothing
  executed). versionId aaacee26; pre backup `...-bb175eda-...-124207.json`.
- [x] F2.3 Prompt candidate `/home/onlinefreedom/cerebro-fase1/pruebas/evals/candidato-fase2-formato-2026-10-28.txt`
  (53,889 chars, live 52,129): FORMATO block 8 lines (one datum per line, one question last, bold
  only amounts/states max 3, digits verbatim, no emojis); bold-data rules replaced (PRIORIDAD
  MAXIMA, rules 6/14, ESTILO); rule 16 "X pesos" = GYD; VARIOS BENEFICIARIOS: any order + grouped
  confirmation per recipient; 12 example lines and several examples rewritten. `*Nombre:*` 0,
  emojis 0. Diff reviewed by the parent (FORMATO and multi-recipient blocks).
- [x] F2.4 Verify the over-deposit admin notice. An over-deposit puts the operation in Incidencia
  and the admin chat receives "Aviso de Remesas Ya / Operacion en incidencia / Remesa - X GYD
  necesita revision manual" (23 in 30 days, last 2026-10-27 20:33). Gap: "Detalle: -" never says
  why (over-deposit, how much). Possible follow-up, owner to decide.
- [x] F2.2 prep: `grupo_enviado` SELECT validated read-only on production (per contact, any
  agent message containing `chat.whatsapp.com/`; 6 ms; 5 contacts already received it). Node
  change pending go-ahead.
- [x] F2.5 Owner 2026-10-28: "Publicar ya, sin bateria". Decisor 0a31fc73 (`--esperado a6ae5ae5`),
  prompt deployed (COINCIDE; rollback `/home/onlinefreedom/cerebro-fase1/ROLLBACK-v2-antes-fase2-formato-20261028.json`).
  Final versionId 0922ab9f == active, 128 nodes; vs bb175eda only Agente Remesas, Contexto
  conversacion and Decisor changed, connections equal. Snapshot
  `infra/n8n/snapshots/produccion-cerebro-0922ab9f-20261028.json`. Pushed to `privado` (c9a213c..d900654).

## Progress

- 2026-10-28 created. RDD off.

## Next step

F2.1 + F2.3 (one writer); F2.2 and F2.4 by the parent.

## Follow-up 2026-10-28: first real phase-2 reply (owner: "corrige esos dos fallos y subelo a github")

- Reply 14:46 Guyana (execution 569429): "La cuenta Zelle nueva queda anotada" without showing it,
  and "Una vez hecha su remesa le notificamos" while the holder's name was missing. The Decisor
  note already said "uno por linea"; the model ignored the generic instruction, and repeated the
  phrase from its own earlier turn.
- Fix (Decisor only): the Zelle note now carries the exact lines ("Cuenta Zelle anotada:",
  "Nombre: ...", "Celular:/Correo:/Cuenta: ...") and, while the name or the account is missing,
  forbids "una vez hecha su remesa"/"le notificamos" and asks one question for that datum; card
  notes carry "Tarjeta: ... / Celular: ..." lines; the duplicate-receipt "Lista para transferir"
  note only promises the remittance when the recipient is known (`sabeDestino`).
- Tests: RED 4 -> GREEN; `npx vitest run pruebas/decisor pruebas/partir` 257/257. Decisor
  `982b147c` published (`--esperado 0a31fc73`), versionId 6feb0fd1 == active, 128 nodes, only
  Decisor changed. Snapshot `infra/n8n/snapshots/produccion-cerebro-6feb0fd1-20261028.json`.
