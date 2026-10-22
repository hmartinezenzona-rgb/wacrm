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
- [x] S2 Migration: `cerebro_resolver_servicio` + assertion with the real cases as fixtures (1232671b at 14:30 and
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

## S1 design (2026-10-22, from live staging bodies; production equal for these functions)

Findings: `Snapshot final` fans out in parallel to the receipt chain, `Registrar carnet efectivo` and `Registrar destino
auto` (only the first feeds Contexto). `_cambiar_servicio_core` retires a phone-only recipient when converting to
recarga/saldo (fit test `ELSE false`). Audio exists only in n8n (`texto_completo`), not in `messages`. Four service
flags plus `riel_operacion` (remesa only). `cerebro_cambiar_servicio` hard-codes actor `automation:...`;
`crm_registrar_numeros_recarga` writes `reparto_auto` and `automation_recharge_numbers_registered`.

Contract: `cerebro_resolver_servicio(p_conv uuid, p_declarado text DEFAULT NULL, p_texto text DEFAULT NULL,
p_monto numeric DEFAULT NULL, p_ahora timestamptz DEFAULT now()) RETURNS jsonb` (STABLE, SECURITY DEFINER, never
writes). Output v1: servicio, en_curso (single OPERACION EN CURSO source), accion {ninguna, convertir, adicional,
preguntar}, confianza, motivo, destino_operacion, convertir_a, pregunta{opciones}, via_actual (null unless en_curso =
remesa and accion <> preguntar), servicio_pendiente, grupo_mixto, adicionales[], alerta, operaciones[] (id, servicio,
status, deposito, own data, phone-only, grupo, human lock), evidencia (negation-aware words, amount = recarga price,
number used in a past recarga of the same contact, phone-only, card, zelle, promo, declarado).

Decision table (first match wins): 1 human-locked or closed/transferring -> ninguna; 2 mixed group -> ninguna (changes
via repartir_envio); 3 card/Zelle present + recarga/saldo words -> ninguna (211); 4 recarga words without promo ->
ninguna (207); 5 correction: holder H of service X, words/declared Y, H has no own data for X, deposit meets Y's
minimum -> convertir; 6 addition: H has own data, or Y has its own amount/data, or deposit over objective ->
adicional (agent uses repartir_envio); 7 reverse: empty recarga + card/Zelle -> convertir (with numbers: preguntar);
8 no words, remesa H phone-only, deposit = recarga price, promo live -> preguntar [recarga, cuban_card]; 9 as 8 +
number used in a past recarga + switch resolver_convertir_sin_palabras (default off) -> convertir; 10 combo/visa/saldo
words: as 5-6, amount never evidence; 11 no open op: words per 3-4, deposit per 8-9; 12 default sin_cambio. Two open
ops of different services outside a group: convert the holder, alerta dos_operaciones_sin_grupo, never auto-cancel.

Execution: VOLATILE `cerebro_aplicar_servicio(p_conv, p_declarado, p_texto, p_exec, p_actor)` takes
`pg_advisory_xact_lock` on the conversation, calls the resolver and on convertir runs `_cambiar_servicio_core` (actor
automation:resolver). New n8n node `Resolver servicio` between `Snapshot final` and the three branches. The writers
take the same lock; agent tools call it with p_declarado and actor agent:<tool>. Converting inside each writer was
rejected (R1 again).

Integration: cerebro_registrar_deposito (flags L33-49, holder L118-125, type L242, numbers L199/L254 from the
resolver; preguntar still files remesa); cerebro_guardar_beneficiario_auto (L219-247 -> one aplicar call);
crm_registrar_numeros_recarga (L146-163 convert instead of insert; p_actor; real source/audit, R5);
_cambiar_servicio_core (keep a lone phone as a recarga recipient); cerebro_cambiar_servicio (L223-229 refusal uses
destino_operacion; actor agent:cambiar_servicio); n8n cambiar_servicio tool + prompt list recarga/combo/visa/saldo;
coherence checker alerts on dos_operaciones_sin_grupo and on convertir/preguntar not acted on (tipo column);
Contexto adds servicio_resuelto, keeps legacy aliases one release; Decisor notes (L336-343, 462, 508, 603-608,
729-737, 839, 888, 966, 974-978, 1011-1024) read only R = ctx.servicio_resuelto; new SERVICIO POR CONFIRMAR note.

Migrations: 265 resolver (+ assertion resolver-servicio.sql), 266 aplicar + core carry-over + audit names +
alert tipo, 267 deposit registration, 268 beneficiary auto-save + recharge numbers, 269 cambiar_servicio + coherence.
n8n (Contexto, Decisor, node, tools/prompt) in S4/S5. Re-run the recarga, saldo/visa/combo, deposit/recipient,
service-change and mixed-send assertion families plus n8n-repoint and live-baseline-parity.

Fixtures for S2: 1232671b@14:30 -> preguntar; 1232671b@14:32 -> convertir (phone kept); legacy duplicate -> convertir
+ alerta; d86574ab/d415e347 -> convertir; f8b7779c -> ninguna grupo_mixto; bf547067 -> ninguna + alerta; 89f6df7e ->
zelle; plain remesa, plain recarga, recarga without promo, combo, visa (explicit phrase), number from history, human lock.

Open owner questions: (1) rule 8 ask vs convert; (2) rule 9 switch; (3) legacy duplicate: alert or auto-cancel;
(4) card + recarga word holding the money: addition or correction; (5) combo + remesa outside a group: propose
grouping?; (6) convert after ready_to_transfer (deposit verified) without a human?; (7) auto-convert saldo/visa or
recarga only.

## Owner answers

- Q6 (2026-10-22): convert after ready_to_transfer (deposit verified) automatically and WITHOUT any alert: "que la
  convierta sola y que no avise; la idea es que el sistema sea autónomo; el cliente dijo que era para una recarga, no
  hay ninguna incidencia". Rule 5 applies to verified deposits; no coherence alert for an applied correction.
- Q1 (2026-10-22): rule 8 CONVERTS (no question): "2, ya que para eso están los datos de los montos mínimos para cada
  servicio". Condition: deposit = a recarga price (or multiple) + phone-only recipient (no card, no Zelle) + promo
  live -> recarga, accion convertir (or the deposit creates a recarga). Safety net: rule 7 converts back to a card
  rail when a card/Zelle arrives later. Note: 6,200 GYD also meets the CUP card minimum (5,000), so the phone-only
  condition is what separates them. Rule 9 (history switch) becomes unnecessary for this path.
- Q3 (2026-10-22): an empty operation (0 GYD, no deposit) next to the holder is CANCELLED automatically after moving
  its numbers/data to the holder: "que se cancele sola, pero con este arreglo no deberían salir más". Safety net only;
  S2/S3 assertions must also prove the new path never creates the duplicate.
- Q4 (2026-10-22): card + recarga word on a deposit: if the deposit covers both (remesa minimum + recarga price) ->
  ADDITION as a mixed send (two linked operations); otherwise keep the remesa to the card and the bot says the money
  does not cover the recarga. Owner: "el 1 me parece lo correcto".
- Q5 (2026-10-22): the DEPOSIT defines a mixed send. One deposit paying several services -> mixed (linked operations
  sharing it); one deposit per service (e.g. 5,000 for a CUP transfer and another 6,200 for a recarga) -> separate
  operations, never grouped. Owner: "las que se deben tratar como mixtas son aquellas que se ven cubiertas por un mismo
  depósito". bf547067-type pairs with separate deposits stay separate (no grouping, no alert for that reason).
- Q7 (2026-10-22): explicit words convert ANY service (recarga, saldo, visa, combo) automatically, like the recarga.
  Amount stays evidence only for recarga. Owner: "1, sí, exacto".
- Q2 (rule 9 history switch): not needed after Q1; the history of the number stays as evidence only.
- Q8 (2026-10-22, owner): the customer can ALWAYS change the service of the operation holding the deposit, in any
  direction, when the deposit meets the new service's minimum ("deposita 6,200, se intuye recarga, se crea como
  recarga, pero si cambia de opinión debe poderse convertir a una transferencia CUP ya que cumple su mínimo").
  Correction vs addition is decided ONLY by deposit coverage: covers both -> adicional (mixed); covers one ->
  convertir even if the holder already has its own data; below the new minimum -> ninguna deposito_bajo_minimo with
  minimum and shortfall for the bot. Replaces the "no own data" condition of rule 5 and the "with numbers ->
  preguntar" branch of rule 7.

## S2 review (2026-10-22)

First draft of 265 dry-run green (24 cases) but parent review found it would reintroduce the 2026-10-04 bug
(89f6df7e: an old question about a recharge promo + a later Zelle payment became adicional/recarga). Sent back with a
recency rule: the LATEST service signal (word, destination data, declared service) wins; an older word followed by
data of another rail is superseded; 'adicional' needs both services requested after the last superseding signal;
availability/price questions are not requests; recarga conversions need deposit >= recarga price (saldo: minimum).
Accepted from the draft: narrow saldo words, cancelar only on convertir for empty ops of another service, rail words
move only non-remesa holders, ambiguity -> preguntar, alerta null in v1, fail-open JSON with sqlstate.

## S2 done (2026-10-22)

- 265_service_resolver.sql (pure STABLE resolver, fail-open), ROLLBACK-265, assertion resolver-servicio.sql
  (cases 1-26). RED: assertion alone failed (function missing). The recency cases (8, 21, 25, 26) and the recarga
  price case (9) were added after the review and first ran against the new code (no separate RED against the first
  draft). Staging aplicar: dry-run, apply, assertion OK, rollback OK (md5 equal to previous); function md5 7d1b4c2e.
  probar_migraciones.sh green. Pure addition: no existing function changed, related assertions not re-run (nothing
  can regress yet; they run in S3 when writers change).
- Recency: window = customer texts since the holder (or last 24 h / last closed op) + p_texto + p_declarado, in order;
  availability/price questions dropped (regex c_preg); a service named before later data of another rail or another
  service word is superseded (evidencia.activas); same-message signals both count. Recarga conversion needs deposit
  >= promo price (6,200), saldo/rails their minimum.
