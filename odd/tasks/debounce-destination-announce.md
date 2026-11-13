# Feature: the debounce waits when the customer announces a destination without giving it

## Objective
When the customer's last text names a destination still to come ("a la cuenta", "a esta cuenta", "al zelle", "a este
número") or asks for a Zelle without any account in the batch, the Cerebro debounce takes its one extra wait (25 s)
instead of answering after 30 s with the data still in flight.

## Problem / why (2026-11-12, conv 1727ef31)
- 20:59:33 UTC "Pásame 58 zelle a la cuenta"; the 30 s window closed 21:00:03 and the batch was answered; the account
  arrived 21:00:12. Node "Evaluar completitud" (n8n Cerebro, staging = production, jsCode md5 01304015) only extends on
  announcement phrases ("ahora te paso", "estos son", trailing ":") or Cuban card/phone half data; it ignores Zelle and
  "a la cuenta" endings.

## Owner decisions
- 2026-11-12: "si, hazlo también".

## Scope
In: node "Evaluar completitud" jsCode (repo source pruebas/debounce/evaluar-completitud.jscode, vitest harness);
staging publish; production publish with go-ahead. Out: wait amounts (30 s / 25 s), Decisor, SQL.

## Constraints
- Strict TDD with vitest (`npx vitest run pruebas/debounce`): RED then GREEN; real phrasing as fixtures, no customer data.
- Only the extension rule changes; the one-extension-per-execution behaviour stays.
- Backup before any write; staging first; production only with the owner's explicit go-ahead. Never execute workflows.
- Never touch pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts, pruebas/decisor/decisor-notas.test.ts,
  odd/tasks/bot-brevedad.md. No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Repo source + vitest harness of the live node (md5 pin 01304015); tests for current behaviour green
- [x] T2 Rule: trailing destination without data ("a la cuenta", "a esta cuenta", "a la tarjeta", "al zelle", "a este
      numero/número", "a mi mamá"-style is OUT) and Zelle asked with no account (email or US phone) in the batch -> incompleto;
      negatives (complete Zelle with account, plain greetings, "gracias") stay complete
- [x] T3 Staging publish (backup, PUT node, verify versionId == activeVersionId, md5)
- [x] T4 Production (needs go-ahead)
- [x] T5 Refinement (owner "si" 2026-11-13): no extra wait when the customer says the data comes later; recarga / saldo phones
      are not "celular sin tarjeta"; tests; staging
- [x] T6 Production of T5 (needs go-ahead)

## Acceptance criteria
- "Pásame 58 zelle a la cuenta" -> incompleto (extra 25 s).
- "Pásame 58 zelle a juan@x.com" -> complete.
- Existing triggers unchanged.

## Progress / evidence
- 2026-11-12 T1+T2: live node saved as pruebas/debounce/evaluar-completitud.jscode (md5 01304015, staging = production),
  harness pruebas/debounce/correr.ts. RED: `npx vitest run pruebas/debounce` 3 failed | 6 passed (the 3 new destination
  cases; existing triggers green). GREEN: 9 passed; new md5 e7958007. Rules added: trailing destination without data
  ((a|al|en) [la|el|esta|este|esa|ese] cuenta|tarjeta|zelle|numero|celular at the end; "misma" never matches) and Zelle in
  the batch with no e-mail, no US phone, no "same account" phrase and no question mark.
- 2026-11-12 T3 staging: backup staging-U52y1kSNvhgxvWeb-e400cbb0-...-antes-completitud.json; versionId e400cbb0 -> a8c8ffe4
  (= activeVersionId), nodes 132 == 132, node md5 e7958007 == repo. Not executed (never run the workflow).

- 2026-11-13 T4 production (owner "si, pásalo a producción"): backup produccion-jEzlVLCLUaJhVwzs-d0ef24b5-...-antes-completitud.json;
  versionId d0ef24b5 -> 181e9479 (= activeVersionId), nodes 128 == 128, node md5 e7958007 == repo, Decisor 97469eb2 unchanged.

- 2026-11-13 T5 (commit 85b47ef2): owner test exec 728308 waited 25 s extra for a message that said "en un rato le paso los
  datos". RED: `npx vitest run pruebas/debounce` 2 failed | 11 passed. GREEN: 13 passed; md5 e7958007 -> 73b86c91. Rules:
  vieneDespues (en un rato, al rato, más tarde, luego, después, mañana) cancels every extension; a recarga/saldo text with phones
  and no card is not half data. Staging: versionId 596a93bf -> 59b29594 (= active), node md5 73b86c91.

- 2026-11-13 T6 production (owner "si"): backup taken; node md5 e7958007 -> 73b86c91; versionId 25a25036 -> 580ca551
  (= active), 129 nodes, Decisor 3219bc40 unchanged.

## Next step
Done. Watch executions that skip "Espera extra" when the customer says the data comes later.
