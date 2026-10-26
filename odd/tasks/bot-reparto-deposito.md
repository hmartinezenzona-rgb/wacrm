# Feature: bot splits a verified deposit across services

## Objective
When one verified deposit has to cover two different services of the same send (for example 100 USD by Zelle plus
the rest to a Cuban card), the bot must split the deposit before confirming anything as complete. Today it creates
the second operation but never splits, so the second service stays unfunded and the operator has to fix it by hand.

## Problem (2026-10-26, conversation 68a00ea7)
- 13:37 UTC: a 31,000 GYD deposit is verified. No agreed objective yet.
- 13:38:24: the customer gives a Zelle account and says "100 USD to this one". The system sets the objective for the
  Zelle operation to 26,000 GYD (`cerebro_objetivo_envio`, 13:38:53).
- 13:38:57: "the rest to this one" plus a card image. `gestionar_beneficiario` creates a second, empty
  `cuban_card` operation. The remainder (5,000 GYD) is never assigned.
- The bot confirms "Queda completo" twice. The Zelle operation keeps the whole 31,000 GYD (119 USD destination) and
  the card operation stays `collecting_information` with no deposit. The owner corrected it by hand at 14:11 and
  Claude applied the split at 14:45.

## Root cause
- The split instruction (`repartir_envio`) is only emitted from the `verificado_de_mas` branch, which needs a
  `Cruzar deposito con MMG` result. That node only runs on a receipt turn. The objective is set later, so no turn
  ever compares objective (26,000) against the verified deposit (31,000).
- The resolver's facts do expose both operations, the deposit and the objective, but no consumer reconciles them.
  `_cerebro_monto_acordado_previo` reads audit rows, not `cerebro_objetivo_envio`, so `monto_acordado_gyd` is null.
- Result: nothing deterministic turns "one operation holds a deposit larger than its objective, and another open
  operation with a recipient holds nothing" into a mandatory split.

## Scope
- Migration 325: `cerebro_resolver_servicio` returns `reparto_pendiente` = {deposito_gyd, resto_gyd, partes[]}
  only when the condition is unambiguous: exactly two open operations, no mixed group, exactly one holds the
  verified deposit, the other has a recipient and no money, the holder has an open objective smaller than the
  deposit, and the remainder reaches the second service's minimum.
- Decisor: when `reparto_pendiente` is present, emit the note and push the mandatory `repartir_envio` with the
  exact parts. The model only executes; the database computed the amounts.
- Tests: Decisor vitest for the note and the mandatory tool; staging assertion for the resolver fact.
- Out of scope: automatic splitting inside the beneficiary tools (unsafe: the tool cannot see the customer's intent
  or the "rest" wording), and prompt-only wording.

## Constraints
- No production write without an explicit go-ahead after staging is green.
- The notion of "the rest" stays in the customer's message; the database only acts when the facts are
  unambiguous (one empty operation with a recipient).
- English artifacts; Spanish only in user-facing bot text.

## Tasks
- [x] T1. Diagnose and record the root cause (done in this document and in Engram).
- [x] T2. Migration 325 + ROLLBACK-325 + staging assertion `reparto-pendiente.sql` (commit 5c1444b).
- [x] T3. Applied to staging: dry-run OK, apply OK, assertion OK, rollback OK (cerebro_resolver_servicio md5 d5c63849).
- [x] T4. Decisor note + mandatory tool; vitest 76/76 green (commit 74e7476).
- [x] T5. Decisor published to staging (versionId 1f672242, md5 467ef930 = repo). Verified at the SQL layer (assertion) and the Decisor layer (vitest); staging cannot be executed end to end.
- [ ] T6. Owner go-ahead; apply migration and Decisor to production; verify with a real send.

## Acceptance criteria
- With an open objective of 26,000 GYD, a verified 31,000 GYD deposit and an empty card operation with a
  recipient, the resolver returns `reparto_pendiente` with parts `zelle 26000` and `cuban_card 5000`.
- The Decisor's context for that turn contains the mandatory `repartir_envio` line with those exact parts.
- The bot calls `repartir_envio` and the two operations end `ready_to_transfer` in one group.
- Ambiguous cases (two empty operations, no recipient, remainder below the minimum) return no fact and the bot
  asks instead of guessing.

## Evidence
- Commits: 5c1444b (migration), 74e7476 (Decisor).
- Staging migration: dry-run OK / apply OK / assertion OK / rollback OK.
- Staging Cerebro: versionId 1f672242-f234-4770-a4f1-a9dadc875ba0, Decisor md5 467ef930.
- Production `previa`: EQUAL, VEREDICTO SEGURO.

## Checks
- `npx vitest run pruebas/decisor`
- `infra/db/staging-migracion.sh aplicar ...` + assertion PASS
- Post-deploy: replay the 68a00ea7 scenario on staging; production measurement of split outcomes in the corpus.
