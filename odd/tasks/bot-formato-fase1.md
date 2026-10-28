# Bot conversation format, phase 1: agent-only deposits, no time promises, currency, usted

## Objective

First, low-risk phase of the conversation redesign (research pasted by the owner on 2026-10-28,
adapted to the live bot). Change only what the customer reads, on the live production Cerebro
(versionId 8faa133b, restore point tag `punto-bueno-2026-10-28`).

## Problem and why

- The business no longer takes deposits through the MMG app (Pay Merchant); deposits are by
  agent only (owner 2026-10-28). The live prompt still asks "¿Desde donde va a depositar, desde
  la app o con un agente?" and renders the app account.
- The bot promises times it does not control ("salen enseguida", "a primera hora", "en breve").
  Several of these are dictated by the live Decisor notes, not only by the model.
- Figures without a currency ("*7,000* que hablamos", "*5,000* a cada tarjeta") and informal
  "tú" in customer text ("Únete aquí").

## Decisions (owner)

- Deposits: agent only. Never ask "app o agente"; always give the agent account.
- Time wording (2026-10-28, "Hora de apertura, sin plazos"):
  - Closed: "queda registrado y se procesa a partir de las {hora_apertura} (hora de Guyana)".
  - Open, ready to transfer: "el equipo la está procesando; le avisamos por aquí cuando esté
    hecha".
  - Under review: "una persona lo revisa y le confirma por aquí".
  - Never "enseguida", "en breve", "a primera hora", "en cuanto abramos".
- Customers keep sending data in any order; that capture must not change.

## Scope

- `Agente Remesas` system prompt: remove the app path (question and app account), add short rules
  for currency on every figure, usted, and the time wording above. Replace conflicting rules
  instead of adding on top.
- Live Decisor `pruebas/decisor/produccion/decisor.jscode`: rewrite the notes that dictate time
  promises; fix any customer-facing "tú" text.
- Out of scope: vision, deposit readers, `Historial contacto` and other nodes that detect app
  receipts (an app receipt sent by mistake must still be recognised); message splitting and
  per-line layout (phases 2 and 3).

## Constraints

- Never execute the staging or production workflow.
- Prompt deploy only with the gold battery green (`evaluar.py --prompt`, replicated).
- Backup before every write; owner go-ahead before every production write.
- Do not touch `pruebas/decisor/decisor.jscode`, `correr.ts`, `decisor-notas.test.ts`,
  `odd/tasks/bot-brevedad.md` (another session's uncommitted work).

## TDD

- Mode: strict, on (global CLAUDE.md). Runner: `npx vitest run pruebas/decisor/produccion`.
- Prompt: gold battery `python3 evaluar.py --prompt <candidate> --reps 3` in
  `/home/onlinefreedom/cerebro-fase1/pruebas/evals/`, compared with the live prompt.

## Tasks

- [x] F1.1 Decisor: time-promise notes rewritten to the decided wording. Writer: RED 13 failing
  (closed, closed-with-next-close, closed day, about to close, away, unverified, unsummed receipts,
  over/claimed/old deposit, duplicate, ready to transfer, by-verify, incident, recharge/visa, MLC);
  GREEN. Parent review: "el equipo esta procesando" was also said while closed; added the closed
  variant ("queda registrada y se procesa a partir de las {apertura} (hora de Guyana)") after the
  service replacements. RED 1 failing; GREEN. `npx vitest run pruebas/decisor` 133/133; md5
  `703e3d9e`. Away wording "se procesa a partir de que regresen" is the writer's (not decided).
- [x] F1.2 Prompt candidate `/home/onlinefreedom/cerebro-fase1/pruebas/evals/candidato-fase1-formato-2026-10-28.txt`
  (52,072 chars, live 53,545): app path and Pay Merchant removed, agent only; `## FORMATO` block
  (5 lines); conflicting rules replaced (rule 5, rule 14, VIA DE DEPOSITO/MAPEO, VIA USD first
  message, closing lines, change-of-service "enseguida"). Diff reviewed by the parent.
  `parameters.text` has no app mention. Owner 2026-10-28: "Apenas lo verifiquemos le hacemos la
  transferencia" (3 places) -> "Una vez verificado, el equipo procesa su envío y le avisamos por
  aquí." (52,511 chars). Owner accepted the away wording "se procesa a partir de que regresen".
- [x] F1.3 Gold case `doble-pregunta-tasa-y-calculo-inverso`: dropped `debe_preguntar_algo`
  (only the app question satisfied it). Backup `casos-conversaciones.json.antes-fase1-20261028`.
- [ ] F1.4 Battery: live prompt vs candidate, 3 reps; no new stable reds.
- [ ] F1.5 Publish with go-ahead: Decisor, then prompt; verify; new snapshot in
  `infra/n8n/snapshots/`.

## Acceptance criteria

- No customer-facing text asks "app o agente" or shows the app account.
- No Decisor note dictates "enseguida", "en breve", "a primera hora" or "en cuanto abramos".
- Baseline Decisor tests (Zelle, g82 split, card/phone, away, brevity) still green.
- Battery: no case that was green on the live prompt turns stably red.

## Progress

- 2026-10-28 created. RDD off (default).

## Next step

F1.1 and F1.2 (one writer).

## Side fixes published on 2026-10-28 (owner go-ahead: "si, aplícalo y luego tmbn lo de verificar el transid en texto")

- `Liberar chat`: every admin WhatsApp command failed with `cannot insert into view "tasas"`
  (the Oct-19 restore brought back the pre-113 query). Production query replaced with the
  pre-restore one (md5 7e06f38d, uses `cerebro_tasa_whatsapp`, has the `verificar_transid`
  branch). versionId 873f9038; only that node changed. Backups `...-8faa133b-...-072055.json`
  (pre) and `...-873f9038-...-072112.json` (post).
- Written TransID verification (312) ported to the live Decisor: admin sends the bare 10-20 digit
  number, "verifica <n>" or "transid: <n>" -> `verificar_transid`. Tests RED 2 -> GREEN.
  Published ALONE on top of the live Decisor (7909d4f8 + 7 lines = `36b4c91e`, copy in
  `infra/n8n/snapshots/decisor-produccion-36b4c91e-20261028.jscode`, 25/25 tests), so the phase 1
  Decisor changes are still unpublished. versionId 370b2480 == active, 128 nodes, only `Decisor`
  changed. Pre backup `...-873f9038-...-072309.json`.
- The repo file `pruebas/decisor/produccion/decisor.jscode` (md5 a6ae5ae5) = phase 1 + TransID;
  `npx vitest run pruebas/decisor` 137/137. Publishing it later replaces 36b4c91e
  (`--esperado 36b4c91e`).
- Admin receipt verification created an operation again (the Oct-19 restore lost migration 310's
  wrapper). Owner 2026-10-28 ("si"):
  - Operation `7ff1fc63` (Osmany's conversation, 15,120 GYD, TransID 20404307615905, no customer
    holds it) cancelled with the 2026-10-24 recipe; audit row `889b6f58`. The deposit stays
    consumed, as 310 does for an admin verification.
  - `Registrar deposito auto` now calls `cerebro_registrar_deposito_si_cliente` (only the function
    name changed; same signature and result; downstream `Cruzar deposito con MMG` identical to the
    Oct-27 bot). versionId 48ebefff == active, 128 nodes, only that node changed. Pre backup
    `...-370b2480-...-073217.json`, post `...-48ebefff-...-073224.json`.

## Handoff 2026-10-28 (session ended at the context limit)

- F1.4 battery was launched in the background: live prompt then candidate, `--reps 3` each,
  logs in the old session scratchpad (`bateria-vivo.log`, `bateria-candidato.log`); reports land
  in `/home/onlinefreedom/cerebro-fase1/pruebas/evals/informes/` (newest `informe-*.json`). It
  may have been killed with the session: check the newest reports' timestamps and `reps`
  metadata; rerun if incomplete. Compare with `comparar_informes.py`.
- Production now: versionId 48ebefff, Decisor 36b4c91e (7909d4f8 + TransID), Liberar chat and
  Registrar deposito auto fixed. NOT published: phase 1 Decisor (repo a6ae5ae5) and the phase 1
  prompt candidate (52,511 chars).
- Next: battery verdict -> owner go-ahead -> publish Decisor (`--esperado 36b4c91e`) then prompt
  (`desplegar_prompt.py --candidato candidato-fase1-formato-2026-10-28.txt --etiqueta fase1-formato`)
  -> new snapshot in `infra/n8n/snapshots/` -> ask the owner before pushing to `privado`
  (commits after tag `punto-bueno-2026-10-28` are not pushed).
- 2026-10-28 owner: publish without the battery ("publica los cambios del decisor y el prompt,
  luego en la practica vemos"). Battery stopped. Decisor a6ae5ae5 published (`--esperado
  36b4c91e`, versionId ceb96631). Prompt deployed (COINCIDE, versionId bb175eda == active, 128
  nodes). Rollback: `/home/onlinefreedom/cerebro-fase1/ROLLBACK-v2-antes-fase1-formato-20261028.json`.
  F1.4 skipped by the owner; watch real conversations. Pending: snapshot + push (ask first).
