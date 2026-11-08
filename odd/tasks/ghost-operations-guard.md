# Feature: a beneficiary write never opens a ghost operation

## Objective
Saving a recipient (Zelle account, card, reparto) must not silently open a new remittance operation when the customer
is still talking about a send that was just completed. The guarantee lives in the database, not in a Decisor note.

## Problem / why (root cause, 2026-11-08)
- Sandra (conv da820eba): op afb7096d completed 19:05 UTC; the customer then asked for the PAYER's name and the team
  posted it. The model called `registrar_beneficiario_zelle` (exec 669871). `cerebro_resolver_para_guardar` returned
  NULL (no open op, no declared service), so `cerebro_escribir_bloque_beneficiario` fell back to
  `cerebro_crear_operacion(p_conv)`: remesa f4e6060b in collecting_information, 0 GYD, no audit, no intent check.
- Same sink for `cerebro_guardar_zelle`, `cerebro_guardar_beneficiario`, `cerebro_guardar_reparto`
  (and `cerebro_guardar_zelle_auto`). The Decisor guards are notes only; the model bypassed them.
- Precedent: the Mexico writer refuses ("Primero hay que declarar el servicio mexico o registrar el deposito").
- 45-day production evidence: 59 ops opened by recipient writes; 43+ legit "account first, deposit later"; 13 ghosts
  (12 cancelled without deposit + f4e6060b). 32 of 46 legit ops had no logged intent signal, so a strict
  "declared service" rule would refuse legit first sends. 4 ghosts were created 0.1-4.3 h after a completion;
  only 1 of 46 legit ops was created within 3 h of a completion.

## Owner decisions
- 2026-11-08: root-cause fix. Window after a completed operation: 6 hours (owner "ok" to the 6 h proposal).

## Claude defaults (stated to the owner)
- Rule A (same send): data matching the account/card of an operation completed within 6 h is refused; nothing opens.
- Rule B (just completed): within 6 h of a completed operation in the same conversation, a recipient write with no
  new-send signal (declared/pending service, quote or agreed amount, deposit) opens nothing. Reply:
  "NO SE ABRIO NINGUN ENVIO ... pregunta al cliente si quiere hacer un envio nuevo".
- Outside the window, behavior is unchanged ("account first, deposit later" keeps working).
- Every operation opened from a recipient write is audited, and the tool reply says a new send was opened.
- No cleanup of the existing 13 ghost operations (owner action from the panel).

## Scope
In: migration 360 + ROLLBACK + staging assertions; staging apply; production with go-ahead.
Out: Decisor changes, panel UI, deleting existing ghost operations.

## Constraints
- Staging first; production only with an explicit go-ahead. Read LIVE bodies before redefining. SECURITY DEFINER
  for new predicates; keep grants.
- Strict TDD: SQL assertions on staging inside rolled-back transactions (RED then GREEN); `staging-migracion.sh
  relacionadas` for the touched writers. Existing assertions that rely on write-opens-op stay green (they have no
  recently completed op) or get fixtures.
- Never touch the other session's files. Never execute n8n workflows. No AI attribution in commits. RDD off.
  TDD on (user global config), runner: SQL assertions + vitest.

## Tasks
- [x] T1 Migration 360: recent-completion predicate (6 h), rule A + rule B in the resolver/writer path, no silent
      fallback creation, audit + "new send opened" reply; ROLLBACK; assertion with the Sandra shape as fixture,
      legit first send unchanged, write with new-send signal inside the window still opens, open op unchanged
- [x] T2 Staging: apply, assertion, related assertions
- [ ] T3 Production (needs go-ahead): previa, apply, verificar; watch the next real recipient writes

## Acceptance criteria
- Completed op < 6 h ago + recipient write with no new-send signal -> no operation created, refusal reply.
- Same data as the completed op -> refused (rule A).
- No completed op in 6 h -> unchanged behavior, op created and audited.
- Open operation present -> unchanged behavior.
- Inside the window with a quote/declared service/deposit -> op opens normally.

## Progress / evidence
- 2026-11-08: root cause and map done (read-only; exec 669871; op f4e6060b; 45-day counts above).

- 2026-11-08 T1+T2 (commit dc68bdf, staging only):
  - Design: guard decides before the fallback inside each writer (`cerebro_guardia_envio_nuevo`, service_role); fallback in
    `cerebro_escribir_bloque_beneficiario` now audits (agent_service_change, reason 'recipient write opened a new send: ...');
    writers append "SE ABRIO UN ENVIO NUEVO" via `_cerebro_envio_abierto_ahora`. `cerebro_guardar_zelle_auto` delegates to
    `cerebro_guardar_zelle`, so it needs no redefinition. Rule A is checked before the new-send signal (owner default).
  - TDD RED (assertion vs pre-360 staging): `ERROR:  20 expectation(s) failed` (1a `ops=2` = the ghost operation reproduced).
  - TDD GREEN (BEGIN; 360; assertion; ROLLBACK): 31 ok, `ERROR:  ALL PASS (rolled back on purpose)`.
  - relacionadas (41 assertions, base vs 360): TOTAL 41 | SAME 40 | DIFF 1. The DIFF was `correct-recipient` case 7 (it matched the
    reply ending in "Completo."; the reply now appends the new-send notice): fixture pattern loosened, rerun SAME. The SAME
    failures are pre-existing on the base (agreed-amount, deposit-anchor, grants-mirror-production, implicit-declaration, saldo-model,
    visa-model, writers-resolver, zelle-payee-resave, deal-free-beneficiary-writers, reparto-destino-node-adapters).
  - Staging apply (`staging-migracion.sh aplicar`): dry-run OK, apply OK, assertion OK, rollback OK (md5 igual al previo).
    md5 after apply: escribir_bloque b48e00df9172, guardar_beneficiario 2ed102214804, guardar_reparto ed0a74504d4b,
    guardar_zelle_auto 5416426c9c17 (unchanged), guardar_zelle a7300c9e59fb; ACLs postgres + service_role kept.

## Next step
T3 production: needs the owner's go-ahead (previa, aplicar, verificar).
