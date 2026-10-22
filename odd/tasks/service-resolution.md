# Service resolution: one authoritative service state per conversation

## Objective

Decide "which service is this operation" in ONE place, before the agent speaks, using all the evidence, and tell a
correction ("era una recarga") from an addition (a real mixed send). The Decisor, the agent tools and the
automations read that single state, so the bot can no longer file a top-up as a remittance (or the reverse), open a
duplicate operation, or receive contradictory notes.

## Problem and why

Incident 2026-10-22, conversation 1232671b (corrected by hand, audit b0617f65, 63c18348, 701e8eb7): a receipt of
6,200 GYD (exactly the top-up price) plus a Cuban mobile only became a remesa (5f9c2ffd); "es para una recarga" made
the agent's tool `registrar_numeros_recarga` open a second, empty recarga (34e587bb) instead of converting; the
Decisor sent "OPERACION EN CURSO: RECARGA" and "VIA ACTUAL: CUP" at once. Owner, 2026-10-22: no patch, a root-cause
solution. Measured in production since 2026-10-07 (lower bound): 3 remesa -> recarga/saldo hand corrections
(d415e347 10-15, d86574ab 10-20, 5f9c2ffd 10-22), 2 recarga ops cancelled at 0 GYD, 1 combo/remesa pair (bf547067),
about 17% of recarga operations started as a phone-only remesa. Full analysis: Engram `cerebro/service-resolution-root-cause`.

The reverse direction was patched on 2026-10-04 (`odd/tasks/recarga-misfiled-deposits.md`, migration 211: the typed
"recarga" rule also needs a promo and no Zelle). Both are symptoms of the same design: the service is guessed from
words, in several places.

Root causes:
- R1 No single service intent: deposit registration, beneficiary auto-save, agent tools and the Decisor each infer it.
- R2 Create vs correct not distinguished: `crm_registrar_numeros_recarga` only opens; `cambiar_servicio` is optional,
  its prompt does not offer recarga/combo/visa, and it refuses with two open operations.
- R3 Deposit-time service comes only from words (recarga/etecsa/cubacel); amount = product price, a number already
  used for a top-up and a phone-only recipient are ignored; nothing re-evaluates it.
- R4 The Decisor builds notes from three different readings (text rule, latest remesa rail, status) that contradict.
  The coherence checker is silent when two operations are open.
- R5 The audit hard-codes `automation_*` / `reparto_auto`, hiding that the agent created the operation.

## Decisions (owner)

- 2026-10-22: approach A (one resolved state before the agent) approved: "me parece bien, si resuelve el problema actual".
- No patches; staging first; each production step with its own go-ahead.

## Design (to refine in S1)

- `cerebro_resolver_servicio(conversation_id)` -> one jsonb state: open operations (id, service, rail, deposit,
  destination data, mixed group), `servicio` resolved, `accion` in {ninguna, convertir, adicional, preguntar},
  `evidencia` (words, amount = product price, number used for a past top-up, phone-only recipient, card present),
  `confianza`.
- Correction vs addition: an open operation of another service that holds the deposit and has no destination data of
  its own rail (e.g. no card) is CORRECTED (converted with `_cambiar_servicio_core`, actor `cerebro:resolver`); a
  second service with its own amount/data, or an operation in a mixed group, is an ADDITION.
- Ambiguous evidence -> `preguntar`: the Decisor asks one question instead of guessing.
- Writers stop deciding: deposit registration, beneficiary auto-save and `crm_registrar_numeros_recarga` ask the
  resolver (convert instead of insert when it says so). Contexto and the Decisor read ONLY the resolver state for
  OPERACION EN CURSO / VIA ACTUAL / ESTADO REAL.
- Audit names the real actor (agent tool vs automation vs human).

## Constraints

- Mixed sends (mixed_group_id, migration 255) must keep working: dedicated regression cases. The 211 rules (promo
  needed, Zelle excludes recarga) must keep holding.
- Staging first; never execute the Cerebro workflows; every production step with its own go-ahead.
- TDD: strict (CLAUDE.md). Runners: SQL self-reverting assertions via `infra/db/staging-migracion.sh`,
  `npx vitest run pruebas/decisor`, full `npx vitest run`.
- Never send customer data to other models; cases referenced by 8-char ids.

## Tasks

- [ ] S1 Design detail: read the live bodies (cerebro_registrar_deposito, cerebro_guardar_beneficiario_auto,
  crm_registrar_numeros_recarga, cerebro_cambiar_servicio, cerebro_recarga_en_curso/combo/visa, Contexto query,
  Decisor service notes) and fix the resolver contract, the correction/addition rule and the evidence weights;
  write it into this document.
- [ ] S2 Migration: `cerebro_resolver_servicio` + assertion with the real cases as fixtures (1232671b at 14:30 and
  14:32, d86574ab, d415e347, f8b7779c mixed, bf547067, 89f6df7e Zelle-not-recarga, a plain remesa, a plain recarga).
- [ ] S3 Migration: writers use the resolver (deposit registration, beneficiary auto-save, recharge-number tool:
  convert instead of insert); real actor in the audit (R5).
- [ ] S4 Contexto + Decisor read only the resolver state; contradictory notes removed; `preguntar` note; node tests.
- [ ] S5 Agent tools/prompt: `cambiar_servicio` offers recarga/combo/visa/saldo; coherence checker alerts on two
  open operations of different services outside a mixed group.
- [ ] S6 Staging end to end with PRUEBA fixtures (owner sends the messages to the staging number).
- [ ] S7 Production (migrations, Cerebro), each step with the owner's go-ahead.

## Acceptance criteria

- The 1232671b sequence ends with ONE recarga operation holding the deposit, or with the bot asking, never two.
- A real mixed send still produces two linked operations; the 89f6df7e Zelle case is still not a recarga.
- One source feeds every service note; no contradictory notes in the node tests.
- Audit rows name the real actor.

## Progress

- 2026-10-22 created after the read-only root-cause analysis; Katiuska data already corrected.

## Next step

S1, after the owner's go-ahead to implement.
