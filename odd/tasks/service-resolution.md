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

## S3 part 1: migration 266 (2026-10-22)

- cerebro_aplicar_servicio (VOLATILE, advisory lock per conversation, runs the resolver; on convertir calls
  _cambiar_servicio_core with the caller's actor; cancels empty duplicates and moves their recipients to the holder with
  dedupe; one sub-transaction, fail-open). _cambiar_servicio_core: converting to recarga/saldo keeps EVERY phone-only
  recipient as a 'recarga' number (parent review changed the writer's "lone phone only" rule: a recarga may go to
  several numbers; RED observed on case 14 "expected recarga:2, got none", then GREEN). Audit action
  agent_service_change added to the CHECK; agent locks recorded as automation:agent_<tool> so they do not block as a
  human lock; partial recipient restored after cancelling a duplicate; auth.uid() callers must be agents of the account.
- Staging aplicar: dry-run, apply, assertion OK, rollback OK (md5 equal); md5 _cambiar_servicio_core 19cae611,
  cerebro_aplicar_servicio 2e4c0e55. relacionadas (--ya-aplicada): 56 total, 54 SAME, 2 DIFF (aplicar-servicio new;
  contexto-envio-mixto flaky on base: random uuid order on tied created_at, passes with 266). probar_migraciones green.

## S3 part 2: migration 267 (2026-10-22, haiku writer + parent review)

- cerebro_registrar_deposito: advisory lock; service flags from cerebro_resolver_servicio(conv, NULL, NULL, monto)
  (live text precedence kept only when the resolver returns servicio NULL, e.g. varias_operaciones: needed by
  visa-model 5e); holder prefers destino_operacion; after attaching, accion convertir -> cerebro_aplicar_servicio
  (actor automation:registrar_deposito) in the movido/sumado/creado branches. RED 2/7 (cases 1 and 6), GREEN.
- Parent review added to case 1 "the number is kept" (the operator needs it). It exposed a PRE-EXISTING bug in
  crm_registrar_numeros_recarga: its regex does not read the WhatsApp format '+53 5 5599180' (space after the 5) ->
  moved to 268 with its own test. A defensive "register numbers after a conversion" change was tried and REVERTED:
  the test passes without it (the operation is created as recarga directly), so it was untested code.
- Staging aplicar OK (md5 7feb5cc7); relacionadas --ya-aplicada: 121, 118 SAME, 3 DIFF = deposito-resolver (new),
  delivery-feed-evidence (fixture fails on base too), contexto-envio-mixto (flaky: 5/6 pass on the applied state).
- Open: a resolver 'saldo' still files a new operation as remesa (live code has no saldo flag); handle with Q7 in S5/S6.

## S3 part 3: migration 268 review (2026-10-22)

Haiku draft of 268 (regex for '+53 5 5599180', convert-before-insert in crm_registrar_numeros_recarga with p_actor,
cerebro_guardar_beneficiario_auto via cerebro_aplicar_servicio) was green on its own cases. Parent review added cases:
7 (holder not converted -> the tool must not open a second, empty recarga) and 8 (mixed group -> no third operation):
RED (case 8 created a third operation; case 7's fixture had no receipt so the resolver saw no money). Design gap found:
the resolver did not tell ADDITION ("y también una recarga") from CHANGE ("mejor / es para una recarga"); with Q5
an addition the deposit does not cover is a SEPARATE operation awaiting its own deposit, not a conversion. Sent to a
writer: addition/change markers in 265 (edited in place: not in production), adicional_aparte motivo, crm inserts
only with no other open operation or adicional_aparte, otherwise explains ('no se abre otra recarga' + minimum /
shortfall / repartir_envio). 265 will be re-applied on staging.

## REDESIGN 2026-10-22 (owner): the bot decides intent, the database validates money and executes

Owner: "la idea era que el bot detectara la intención del cliente y actuara en consecuencia, no poner parches por cada
posibilidad". Word lists, question regexes and word recency in the resolver were patches; they are removed. The
running writer for addition/change markers was stopped before touching 265.

Split of responsibilities:
1. INTENT = the agent (LLM). It declares a structured intent with its tools: `cambiar_servicio(servicio)` for a change
   of mind, `agregar_servicio(servicio)` for an addition, and when the customer states a service before paying,
   `declarar_servicio(servicio)` persists it as the conversation's declared intent (one row per conversation,
   replaced by the latest declaration, cleared when the operation closes). No SQL reads customer words to infer intent.
2. RULES = the database, facts only: deposit vs minimum of the target service, whether one deposit covers both services
   (mixed) or not (separate operation awaiting its own deposit), human locks, closed/transferring states, mixed groups.
   It executes and answers the agent in plain Spanish (e.g. "no alcanza: el mínimo es 6,200 GYD y faltan 1,200").
3. BEFORE THE AGENT (deposit registration, beneficiary auto-save): facts only. The deposit takes the service from the
   persisted declared intent if any; with none, Q1 applies (amount = recarga price + phone-only + promo -> recarga);
   otherwise remesa. Data arrival (a card, a Zelle account) is stored, never used to guess a service change.
4. ONE STATE for the Decisor: it reads the resolved state (operations, declared intent, deposit coverage); no
   contradictory notes.

Consequences for the migrations (none of 265-268 is in production):
- 265 rewritten in place: `cerebro_resolver_servicio(p_conv, p_declarado, p_intencion, p_monto, p_ahora)`; no text
  parameter; rules only on money/data/state; output adds `permitido`, `motivo`, `minimo_gyd`, `faltante_gyd`,
  `cubre_ambos`, `accion` in {ninguna, convertir, mixto, aparte}. New table `cerebro_servicio_declarado`.
- 266 adjusted to the new contract (cambiar -> convert; agregar -> mixed when covered, else a separate operation).
- 267 deposit registration reads the declared intent instead of the text rules (cerebro_recarga/combo/visa_en_curso).
- 268 rewritten: number regex fix kept; the numbers tool and beneficiary auto-save never infer a service.
- 269: agent tools cambiar_servicio / agregar_servicio / declarar_servicio + prompt; S4 Decisor single state.
Q1-Q8 stay valid; they are now enforced as money rules plus the agent's declared intent.

## Redesigned 265 (2026-10-22, haiku writer + parent review)

- Facts-only cerebro_resolver_servicio(p_conv, p_declarado, p_intencion, p_monto, p_ahora) v2 (R0 invalid input, R1 mixed
  group, R2 several deposits / several ops, R3 lock/state, R4 recarga without promo, R5 agregar -> mixto|aparte and
  cambiar -> convertir|deposito_bajo_minimo, R6 sin_cambio, R7 new operation, R8 Q1 price + phone-only, R9 default);
  cerebro_declarar_servicio (latest wins) + table cerebro_servicio_declarado + clear-on-close trigger. No message text.
- Parent review: (1) the writer's case 1 did not reproduce the real 1232671b operation; new case 1c (a cuban_card
  recipient WITHOUT a card number, no rail) FAILED (sin_cambio) because a card rail counted as card data -> only a
  real card number counts now; GREEN. (2) cerebro_declarar_servicio restricted to service_role (RED: authenticated
  could execute -> GREEN). Accepted: varias_operaciones kept; R8 needs a live promo; declarar accepts 'remesa' but the
  resolver needs a concrete rail/service (the prompt will ask the agent to declare a specific one).
- Staging: 267/266/265 of the old design rolled back first; new 265 applied (dry-run, apply, assertion, rollback OK).
- Next: 266 (cambiar -> convert, agregar -> mixto via the mixed-send split / aparte as a new operation), 267, 268.

## Redesigned 266 (2026-10-22, haiku writer + parent review)

- cerebro_aplicar_servicio(p_conv, p_declarado, p_intencion, p_actor, p_exec), service_role only: advisory lock;
  persists the agent's declaration (not 'remesa'); executes the resolver v2: convertir -> _cambiar_servicio_core (every
  phone-only recipient kept as a recarga number) + cancel empty duplicates; mixto -> cerebro_repartir_envio (the 255
  split, parts as text, e.g. "tarjeta cup 6800, recarga 6200"; its own audit automation_mixed_split); aparte -> a new
  separate operation (not created if an empty one of the same service already exists: ya_existe_vacia). Fail-open.
- RED: function missing; GREEN 15 case groups. Staging applied (dry-run, apply, assertion, rollback OK; md5
  cerebro_aplicar_servicio f41e5416, core 19cae611). relacionadas --ya-aplicada: 58, 56 SAME, 2 DIFF (aplicar-servicio
  new; writers-resolver = the old-design 268 draft, to be rewritten). Redesigned 265 re-checked: 109, 108 SAME,
  only its own assertion differs (saldo-model, feed-mixed, deal-insert-creates-operation fail on base too).
- The writer left a background monitor that kept notifying; it ended with the agent.

## Redesigned 267 (2026-10-22)

- cerebro_registrar_deposito: advisory lock; the service of a new operation = the bot's declared intent, else Q1
  facts, else remesa (the three text rules removed); open recarga/combo/visa keeps winning; holder prefers
  destino_operacion; accion convertir -> cerebro_aplicar_servicio after attaching (receipts inserted first: the resolver
  reads the holder's money from them). RED 5/9, GREEN 9/9.
- Old assertions that relied on the removed text rules (combo-deposit-calculator 2/2b/..., visa-model 1/5a/...,
  recarga-numbers 5) are being updated so the bot declares the service before the deposit (expectations unchanged).
- PRODUCTION ORDER CONSTRAINT: 267 must NOT reach production before 269 (agent tools declarar/cambiar/agregar
  + prompt): without the bot declaring, "quiero una recarga" would end as a remesa.
- 267 done: old assertions updated with bot declarations only (visa-model 1/5a/5b/5g/7b, combo-deposit-calculator
  2/2b/4/5b, recarga-numbers 5; expectations unchanged; ALL PASS with and without 267). Every assertion that calls
  cerebro_registrar_deposito passes on both, except deal-insert-creates-operation, n8n-repoint and
  operation-incident-reason, which fail identically on base (a new deal creates no operation on staging; unrelated).
  Staging applied (dry-run, apply, assertion, rollback OK; md5 a3c9c101). relacionadas --ya-aplicada: 122, 119 SAME,
  3 DIFF = deposito-resolver (new), delivery-feed-evidence (fixture fails on base too), contexto-envio-mixto (flaky).

## Redesigned 268 (2026-10-22)

- crm_registrar_numeros_recarga(p_conv, p_texto, p_abrir DEFAULT false, p_actor DEFAULT NULL): number regex reads the
  WhatsApp format '+53 5 5599180'; never infers a service (the text rule replaced by the declared intent); with p_abrir
  it converts the holder through cerebro_aplicar_servicio and inserts a new recarga only when no other operation is
  open, otherwise returns the resolver's mensaje; real actor (source 'agente' for agent calls).
  cerebro_guardar_beneficiario_auto no longer opens operations from words.
- RED 9 cases; GREEN; relacionadas 127, 123 SAME (DIFF: the new assertion, recarga-before-deposit, flaky
  contexto-envio-mixto, delivery-feed-evidence fails on base). recarga-before-deposit updated like 267: the bot
  declares recarga before the numbers (case 1) and the tool call passes p_abrir (case 3); ALL PASS with 268.
- Staging applied.

## Owner direction 2026-10-22: test without the automatic readers

Cases Clarita (faaa62ea, op 1eedc3a3: the Zelle auto-reader overwrote the bot's names with 'Se ve bien' / none) and
Marlene (4afda26a: one 71,200 deposit for Mexico + cash + card became ONE CUP remesa of 213,600 CUP) were corrected by
hand (Engram bug/multi-recipient-multi-service-sends-persisted-wrong-clarita-marlene-2026-10-22). Owner: "esos
lectores automáticos están entorpeciendo el trabajo del bot; debemos probar sin esos lectores automáticos y dejar al
bot que cree las operaciones con las herramientas, porque él confirma y entiende bien todo".
- [ ] S5b Staging experiment: disable the automatic readers (Registrar beneficiario auto, Registrar zelle auto,
  Registrar destino auto, notes_parse writers) in the staging Cerebro; the agent creates operations, recipients and
  multi-service splits only through its tools (gestionar_beneficiario, registrar_beneficiario_zelle,
  repartir_envio / registrar_reparto_multiple, cambiar/agregar/declarar_servicio). Measure with real-shaped cases
  (Katiuska, Clarita, Marlene, f8b7779c) before any production change.
- ~~Gap: Mexico (Mercado Pago) is not a modelled service.~~ Wrong: Mercado Pago is the BANK of a CLABE account (owner
  2026-10-22, conv 4afda26a: 18-digit CLABE + "Es de mercado pago"). See the México section below.

## México as a real operation (owner 2026-10-22: "sí, mételo en el rediseño")

Business (cerebro_servicios 'mexico'): customer pays GYD by MMG; 260 GYD per USD, minimum 13,000 GYD (50 USD), no
maximum; same day. Payout in MXN at the day's rate set by the operator (no stored USD->MXN rate). Receive by CUENTA
BANCARIA (CLABE, banco, titular; e.g. Banco Azteca, Mercado Pago) or RETIRO SIN TARJETA at Coppel/BBVA (multiples of
100). One conversation can carry several México accounts (4afda26a, 2026-08-20: 100 + 200 USD plus a Zelle).
Today: requiere_humano = true; 0 operations with service_type 'mexico'; in 90 days 16 conversations, their sends filed as
rail-less remesas (12 completed, 496,600 GYD) outside the calculator. Code already knows service_type 'mexico'
(src/lib/service-name.ts, dashboard, 229 history, 243 cerebro_cotizar tasa unica). Open with Osmany: cost per send,
cardless-withdrawal data, completion evidence (docs/negocio/PEDIR-A-OSMANY-mexico.md 2-5).

- [ ] M1 Map (read-only): what an operation of service_type 'mexico' needs end to end: recipient model for CLABE /
  banco / titular and cardless withdrawal, resolver/aplicar/declarar minimums, deposit registration, agent tools and
  prompt (consultar_servicio, calcular_usd via=mexico, requiere_humano handoff), Decisor notes, panel/board,
  calculator/ledger/finances, customer notifier. Output: gaps and a task split (M2..), written here.
