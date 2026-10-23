# DB tools for the agent (staging only) - progress log

Owner direction 2026-10-22: the bot (LLM) creates operations and recipients with its tools; the automatic readers
(Registrar beneficiario auto, Registrar zelle auto, Registrar destino auto) are DISABLED on staging; "la solucion esta en
mejorar esa herramienta". Single DB writer: this log. The n8n agent codes against the signatures recorded below
("<n> applied on staging"). Nothing here is in production. Migrations 274+.

## Step 0 - audit of the disabled readers (read-only, live staging bodies, 2026-10-22)

Legend: OK = the agent tool covers it; GAP n = closed by the migration named in the last column.

| Reader node -> function | Writes (what / multiplicity / position) | Timing | Operation it targets | Agent tool | Coverage |
|---|---|---|---|---|---|
| Registrar beneficiario auto -> `cerebro_guardar_beneficiario_auto(conv, tarjeta, celular, tarjeta_acum, celular_acum, exec)` | One `cuban_card` recipient (card 16 digits, phone 8 digits, name never), partial data merged (a different card starts without phone, 179 D1); a vigente 2-3 slot reparto is patched by slot, never replaced (184) | Before the deposit only the COMPLETE pair (accumulated by Merge) opens a remesa; with an open operation, what arrived in this burst is saved at once (before or after the deposit) | `cerebro_resolver_operacion_beneficiario` (250 several-operations rule: amount, proximity, anchor, `misma_cuenta`); excludes visa/combo/saldo; unresolved with several remesas -> derives to a person | `gestionar_beneficiario` -> `cerebro_guardar_beneficiario(conv,nombre,tarjeta,celular,exec)` (p_op NULL) | Writes OK. GAP 6: target resolver is `cerebro_resolver_operacion` (service-blind, no 250 rule): in a mixed send / next to a recarga or Mexico operation the card lands on the wrong operation or the chat is derived (F: card on the recarga; 275/276) |
| same (combo branch) | nothing: an open combo collecting its recipients owns typed numbers | any | combo | `registrar_destinatario_combo` | OK |
| same (recarga branch) | Cuban phones with no card -> `crm_registrar_numeros_recarga(...)`: one `recarga` row per number, deduped, positions 1..n | open recarga, or declared recarga | latest open recarga | `registrar_numeros_recarga` | Writes OK. GAP 2/6: with another operation open and no recarga, the tool refuses with the resolver's "no alcanza" instead of opening the recarga part (F2); with a declared recarga and no operation it only works through `p_abrir` (276) |
| same (cash branch) | Cuban phone only on an `efectivo_usd` operation -> `crm_registrar_datos_entrega_efectivo(phone)` (one `efectivo_usd` recipient: name, phone, address, ID photo; merge by replacement) | after the cash rail is set | open `efectivo_usd` remesa | `registrar_datos_entrega_efectivo` | Writes OK. GAP 2: raises when no cash operation exists yet although the bot declared `efectivo_usd` (M3b) (275) |
| Registrar zelle auto -> `cerebro_guardar_zelle_auto(conv, nombre, cuenta, exec)` | ONE `zelle` recipient (holder, account); partial merge; a different account starts without holder; replacement per operation | Before the deposit only holder+account opens a remesa; with an open operation partial data saves at once | 250 resolver by account (`misma_cuenta`) | `registrar_beneficiario_zelle` -> `cerebro_guardar_zelle(conv,nombre,cuenta,exec)` (p_op NULL) | GAP 1: a second Zelle recipient REPLACES the first (C: Maria Lopez 'reemplazado'); GAP 6: no 250 targeting, service-blind (274, 276) |
| Registrar destino auto -> `cerebro_registrar_destino(conv, texto_completo)` | Reads the words: writes `cerebro_destino_pendiente` (clasica / tropical / cuban_card, last wins) and re-types the vigente card-rail recipients and `delivery_method` of the SINGLE open remesa, recalculates the destination amount (157) | any | single open remesa only | `marcar_destino_usd` (clasica/tropical/efectivo), `declarar_servicio`, `cambiar_servicio` | GAP 6: `cerebro_marcar_destino_usd` uses the same service-blind single-operation resolver: with a Mexico operation open it re-typed the Mexico operation to `efectivo_usd` (M3). No value for the CUP rail (276) |
| (not a reader, agent-only data) | Mexico recipient (CLABE/banco/titular or Coppel/BBVA retiro) | any | open `mexico` operation | `registrar_destinatario_mexico` -> `cerebro_guardar_beneficiario_mexico` | GAP 2: refuses when `mexico` was declared but no operation exists (M2, M3) (275) |
| (not a reader) | multi-service split of one deposit | after the deposit | holder operation | `repartir_envio` -> `cerebro_repartir_envio` | GAP 3: "No hay un deposito registrado" before the deposit (M3b); a deposit different from the parts is refused with only two sums (277) |
| (calculator side effect) | `cerebro_fijar_objetivo` from `calcular_usd` | at quote time | conversation | `calcular_usd` | GAP 4: "NO se fijo nada: sin beneficiario ni comprobante" before any recipient even after the bot declared a service (278) |
| (agent tool) | `agregar_servicio` / `cambiar_servicio` messages | any | resolver | `cerebro_aplicar_servicio` | GAP 5: `mensaje` NULL for `agregar` with `nueva_operacion` (F1) (279) |

Gaps found beyond the measurement list: (a) `marcar_destino_usd` retypes a Mexico/recarga operation (listed under 6);
(b) no `cup` rail value in `marcar_destino_usd` (default rail, closed in 276); (c) beneficiary tools derive to a person
whenever two operations are open (service-blind resolver) - the readers used the 250 rule, the tools did not (276);
(d) `registrar_numeros_recarga` cannot open the recarga part of a send while another operation is open (276).

Planned migrations (one coherent migration + ROLLBACK + assertion + commit each):
274 Zelle several recipients | 275 pre-deposit operations from the declared intent (mexico, cash, numbers, deposit attaches) |
276 service-aware target resolution for the recipient writers (mixed send, 250 rule for tools, marcar_destino cup) |
277 planned split before the deposit + facts on a different deposit | 278 objective without an operation |
279 `agregar` always answers a plain-Spanish `mensaje`.


## 274 applied on staging - Zelle: several recipients (gap 1)

TDD: assertion `zelle-several-recipients` RED (function with the new arguments missing, case 2), GREEN 11 case groups.
Cycle: dry-run, apply, assertion, rollback (md5 equal to the previous state for guardar_zelle, parsear_beneficiarios, guardar_zelle_auto) OK.
relacionadas --ya-aplicada: Zelle/writers set 6 (5 SAME, 1 DIFF = the new assertion); 265-273 set 31 (31 SAME; the known pre-existing failures
deal-insert-creates-operation, n8n-repoint, operation-incident-reason, repeated-receipt fail identically on base).

Signature (6 -> 9 arguments; the 6-argument function was dropped, the old 4-argument tool call and zelle_auto's 6-argument call still work):

```
cerebro_guardar_zelle(p_conv uuid, p_nombre text, p_cuenta text, p_exec text,
                      p_op uuid DEFAULT NULL, p_tool text DEFAULT 'registrar_beneficiario_zelle',
                      p_posicion integer DEFAULT NULL, p_agregar boolean DEFAULT false, p_monto numeric DEFAULT NULL)
  RETURNS TABLE(deal_id uuid, accion text)      -- service_role only
```
Tool query for n8n (new tool params: nombre, cuenta, posicion (int or empty), agregar (true/false), monto (USD or empty)):
`SELECT deal_id AS id, accion FROM cerebro_guardar_zelle($1::uuid, NULLIF($2,''), NULLIF($3,''), $4, NULL, 'registrar_beneficiario_zelle', NULLIF($5,'')::int, coalesce(NULLIF($6,'')::boolean,false), NULLIF($7,'')::numeric);`
(the existing first argument order stays; p_nombre/p_cuenta may be NULL for a position or amount only correction).

Behaviour the prompt can rely on:
- Same account as a recipient in force (no parameter) = correction of THAT recipient only (the others stay vigente).
- `agregar = true` adds another recipient (position N+1); same account as an existing one patches it, never duplicates.
- `posicion = k` (1..N+1) patches slot k; a NEW account in a slot starts without holder unless `nombre` is given; k = N+1 appends.
- One recipient and no parameter and a different account: replaced (old behaviour) and the answer ends with
  "(Reemplazo al destinatario anterior; si es OTRA persona, no una correccion, vuelve a llamar con agregar=true.)".
- Two or more recipients, no parameter, an account that matches none: NOTHING is written; accion starts with
  "NO SE GUARDO NADA: este envio ya tiene N destinatarios Zelle (1) nombre / cuenta; 2) ...) ... llama con agregar=true ... posicion". Same prefix for an invalid posicion.
- `monto` is USD for that recipient (stored amount + currency 'USD'), kept when a later call has none, changed by a new one; <= 0 is refused ("ERROR: ...").
- Names are stored exactly as passed (pipes, accents, double spaces kept); account normalised as before.
- Return `accion` texts: single recipient, no amount: "guardado: titular X, cuenta Y. Completo." (unchanged). Several or with amount:
  "guardado (destinatario k de N): titular X, cuenta Y[, monto M USD]. Completo.|. FALTA: ... Pideselo al cliente. Destinatarios Zelle ahora: 1) A / a@x[ / 60 USD]; 2) ...".
  "sin cambios: esos datos ya estaban guardados" when nothing differs. `deal_id` is the operation id (NULL on a refusal).
- Other operations of the conversation are never touched when `p_op` is passed (250 targeting); with `p_op` NULL the old resolver still picks the
  operation (service-aware targeting for the tools arrives with 276).
- Parser: `cerebro_parsear_beneficiarios` reads a new block `ZELLE VARIOS DESTINATARIOS` (one line per recipient).

## 275 applied on staging - pre-deposit operations from the declared intent (gap 2)

TDD: assertion `declared-operation-before-deposit` RED (case 1: the Mexico tool refused), GREEN 7 case groups. Cycle OK (dry-run, apply,
assertion, rollback md5 equal). relacionadas --ya-aplicada (writers, deposit, resolver, mexico, recarga): 48 assertions, 47 SAME, 1 DIFF = the new one;
the SAME errors are the known pre-existing ones (deal-insert-creates-operation, n8n-repoint, operation-incident-reason, saldo-model, repeated-receipt,
deal-free-beneficiary-writers, reparto-destino-node-adapters).

No signature changed. New internal helper (service_role only): `_cerebro_operacion_declarada(p_conv uuid, p_servicio text, p_actor text DEFAULT 'agent:declarar_servicio') RETURNS uuid`
(finds the open operation of the service, or opens it ONLY when that service is the declared one: collecting_information, 0 GYD, MXN for mexico).

What the agent can now rely on (same tool queries as before; the prompt must say "declare first"):
- `registrar_destinatario_mexico` after `declarar_servicio('mexico')` with no operation: opens the mexico operation (0 GYD, awaiting deposit) and saves the recipient;
  the later deposit joins it ('movido'). Without the declaration the answer stays "No hay un envio a Mexico abierto en esta conversacion: ... Primero hay que declarar el servicio mexico o registrar el deposito." (ok=false).
- `registrar_datos_entrega_efectivo` after `declarar_servicio('efectivo')`/`efectivo_usd` with no operation: opens the cash operation (remesa, delivery_method efectivo_usd) with the recipient; undeclared it still raises 22023.
- `registrar_beneficiario_zelle` / `gestionar_beneficiario` / `registrar_reparto_multiple` with nothing open and a declared rail that fits the data
  (zelle for a Zelle account; cuban_card|clasica|tropical for card data) open the operation typed with that rail. A declared `mexico` + card data opens no mexico operation.
- `registrar_numeros_recarga` after `declarar_servicio('recarga')` already opened the recarga (268); the assertion now proves the 6,200 deposit joins it.
- Return shapes unchanged.

## 276 applied on staging - writers target the operation of their service (gap 6, plus 250 for the tools)

TDD: assertion `writers-target-by-service` RED (case 1: the clasica card went to a person / the recarga), GREEN 7 case groups. Cycle OK (rollback md5
equal). relacionadas --ya-aplicada (writers, deposit, resolver, tools): 55 assertions, all SAME except the new one; first run found two real regressions
(231 guards of marcar_destino_usd, an unchanged invalid-type message) which were fixed before this version.

No signature changed. New internal helper (service_role only): `_cerebro_ops_para_datos(p_conv uuid, p_kind text) RETURNS TABLE(operation_id uuid)`
(kinds tarjeta | zelle | efectivo | remesa).

What the agent can rely on (same queries as before):
- `gestionar_beneficiario`, `registrar_reparto_multiple` (card data) and `registrar_beneficiario_zelle` write on the open REMESA of their rail
  (or a rail-less remesa). A recarga, mexico, combo, visa or saldo operation is never the target: with only those open, the card opens a plain remesa next to them.
  In a mixed send (clasica + recarga) the card lands on the clasica part. Several candidates of the service: the 250 rule (by card / account) decides; an unresolved tie
  still answers "NO SE REGISTRO NADA ... un companero le atiende" and hands the chat to a person.
- `marcar_destino_usd`: only REMESAS are targeted (the Mexico operation is no longer re-typed to efectivo_usd); new accepted value `tipo = 'cup'` (also 'cuban_card', 'pesos',
  'tarjeta cup') sets the rail cuban_card and answers "destino marcado: tarjeta en pesos (CUP)" (new remesa: "envio nuevo creado, tarjeta en pesos (CUP)"). The invalid-type message is unchanged
  ("ERROR: el tipo debe ser clasica, tropical o efectivo. No se marco nada.").
- `registrar_numeros_recarga` (p_abrir) with every other open operation still EMPTY (collecting, 0 GYD, no receipt/deposit, not grouped) opens the recarga as its own empty
  operation and saves the number there: "guardados 1 numero(s) de recarga nuevos; la recarga tiene 1.". With money or a mixed group on another operation the refusal text is unchanged.
- Pre-deposit mixed send: card on the clasica op + number on the recarga op, then after the deposit `repartir_envio("clasica 18200, recarga 6200")` reuses both operations (no third) and each keeps its data (proved).

## 277 applied on staging - split planned before the deposit; facts on a different deposit (gap 3)

TDD: assertion `planned-split-before-deposit` RED (case 1: "No hay un deposito registrado..."), GREEN 8 case groups. Cycle OK (rollback md5 equal).
relacionadas --ya-aplicada (repartir, deposit, resolver, mixed, aplicar, writers): 47 assertions; the only real DIFFs were `bot-mixed-split` cases 3 and 5, which asserted the OLD
behaviour the owner asked to change (refusal with two sums; "No hay un deposito registrado") - updated to the new contract (same numbers, now facts / a plan); the `deal-free-money-rules`
DIFF was a deadlock (clean alone). Known pre-existing failures unchanged (contexto-envio-mixto flaky, deal-insert-creates-operation, n8n-repoint, operation-incident-reason, saldo-model, repeated-receipt).

Signatures unchanged: `cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL) RETURNS text` (the tool still reads `AS resultado`).
New table `cerebro_reparto_planeado(conversation_id PK, partes jsonb, total_gyd numeric, actor, creado_at)` (service_role only). Helpers (service_role only): `_cerebro_usd_parte`, `_cerebro_texto_partes`,
`_cerebro_op_parte`, `_cerebro_reparto_planear`, `_cerebro_aplicar_plan_reparto`.

Behaviour the prompt / Decisor can rely on:
- `repartir_envio("mexico 39000, efectivo 29000, cup 15000")` BEFORE any deposit: answers `Reparto planeado (todavia sin deposito, nada aplicado): mexico 39,000 GYD (150 USD), efectivo USD 29,000 GYD (100 USD), tarjeta CUP 15,000 GYD. Total 83,000 GYD. Cada parte tiene ya su operacion vacia donde guardar sus datos; cuando llegue un deposito de exactamente 83,000 GYD se reparte solo. ...`.
  The plan is persisted and one EMPTY operation per part is opened (recipient tools of 276 then land on the right part). Fewer than two parts / repeated service: "No se pudo repartir: ..." and nothing is saved.
- A deposit of EXACTLY the planned total is split automatically inside `cerebro_registrar_deposito` (one mixed group, amounts per part, plan deleted); the deposit call's return shape is unchanged.
- A deposit DIFFERENT from the plan is registered normally and the plan stays. `cerebro_resolver_servicio(...)` (so `servicio_resuelto`) has a new key `reparto_planeado`:
  `{ "partes": [{"servicio","monto_gyd","usd"}], "total_gyd", "deposito_gyd", "diferencia_gyd" (deposit - plan), "coincide": bool }` or null. `usd` is whole dollars (zelle by tier, clasica/tropical/mexico at the USD rate, efectivo_usd at the cash rate) or null for cuban_card/recarga/combo/visa/saldo.
- `repartir_envio` with a deposit already registered and parts that do not add up no longer refuses: it keeps the plan and answers
  `REPARTO NO APLICADO: las partes suman 83,000 GYD y el deposito a repartir es 71,200 GYD (faltan 11,800 GYD para cubrir las partes). Partes planeadas: mexico 39,000 GYD (150 USD), ... No se cambio nada. Preguntale al cliente que parte cambia (o si deposita el resto) y vuelve a llamar con montos que sumen exactamente 71,200 GYD. No prometas ninguna entrega hasta entonces.`
  ("sobran N GYD del deposito" when the parts are smaller). A later call whose parts add up splits and deletes the plan ("Reparto hecho: ...").
- The plan is deleted when the conversation's last operation closes.

## 278 applied on staging - send objective without an operation (gap 4)

TDD: assertion `objective-without-operation` RED (case 2: "NO se fijo nada: sin beneficiario ni comprobante"), GREEN 6 case groups. Cycle OK (rollback md5 equal).
relacionadas --ya-aplicada (objective / quote / declare): 40 assertions, 39 SAME (all failing ones are pre-existing on base: deals-free-views, n8n-repoint, objetivo-requiere-compromiso fixture, operation-keyed-money,
rekey-shipment-alerts, saldo-model, tag-sync-without-deals, target-origin-label), 1 DIFF = the new assertion.

Signatures and return shapes:
- `cerebro_fijar_objetivo(p_conv uuid, p_monto numeric, p_moneda text DEFAULT 'GYD') RETURNS TABLE(objetivo_gyd numeric, pedido text, accion text)` - unchanged. The commitment test now also accepts a DECLARED service, a planned split
  or any open operation (even empty); the objective is stored at conversation level (operation_id NULL) and the next deposit consumes it (`cerebro_objetivo_atar_op` in `cerebro_registrar_deposito`). A bare quote with none of those still answers
  "NO se fijo nada: sin beneficiario ni comprobante todavia (solo cotizacion)".
- `cerebro_declarar_servicio(p_conv uuid, p_servicio text, p_actor text DEFAULT NULL) RETURNS jsonb` = `{ok, servicio}` (+ `objetivo_gyd` when it promoted a quote). The agent quotes first (`calcular_usd`) and declares after, so declaring
  promotes the standing quote (`cerebro_ultima_cotizacion`, inside `cotizacion_ventana_horas`, newer than the last closed operation) to the send objective when no open objective exists; an existing objective is never overwritten; no quote = nothing.
  The `declarar_servicio` tool query keeps working unchanged (it reads ok/servicio/motivo).

## 279 applied on staging - `mensaje` is never NULL (gap 5)

TDD: assertion `apply-service-message` RED (case 1: `agregar` recarga with no operation, mensaje NULL), GREEN 6 case groups. Cycle OK (rollback md5 equal).
relacionadas --ya-aplicada (aplicar / resolver / cambiar): 18, 16 SAME + the new assertion + `resolver-servicio` case 7, which asserted the old NULL mensaje of `sin_cambio`
(updated: "La operación ya es Zelle: no hay nada que cambiar."). Full sweep of the 156 assertions on the final staging state: every failure also fails on the pre-274 state
(compared with the rollbacks 279..274 inside a rolled-back transaction): deal-insert-creates-operation, deals-free-views-and-inert-edits, delivery, delivery-feed-evidence, feed-mixed, field-lock-persistence,
guard12-matrix, history-readiness, n8n-repoint, objetivo-requiere-compromiso, operation-creator-without-deals, operation-incident-reason, operation-keyed-money, rekey-shipment-alerts-onto-operations,
repeated-receipt, requested-amount-target, saldo-model, stale-operations-alert, tag-sync-without-deals, target-origin-label, cup-excess-equivalent, chat-media-members-only-read, duplicate-receipt-marker,
deal-free-beneficiary-writers / reparto-destino-node-adapters (their own expected-error output). `contexto-envio-mixto` (flaky) passed.

Signatures unchanged: `cerebro_aplicar_servicio(p_conv uuid, p_declarado text DEFAULT NULL, p_intencion text DEFAULT NULL, p_actor text DEFAULT 'automation:resolver', p_exec text DEFAULT NULL) RETURNS jsonb` and
`cerebro_resolver_servicio(p_conv uuid, p_declarado text DEFAULT NULL, p_intencion text DEFAULT NULL, p_monto numeric DEFAULT NULL, p_ahora timestamptz DEFAULT now()) RETURNS jsonb`.
The tool queries for `cambiar_servicio` / `agregar_servicio` need no change; `mensaje` is now always plain Spanish:
- `agregar`, nothing open (`motivo nueva_operacion`, `permitido true`, `aplicado false`): "Anotado: se agrega la recarga como operación nueva; todavía no hay otra operación abierta y se abre con sus datos o al repartir el depósito."
  (`cambiar`: "Anotado: la recarga será la operación; todavía no hay ninguna abierta y se abre con sus datos o con su depósito.").
- `sin_cambio`: "La operación ya es <servicio>: no hay nada que cambiar."; nothing to do: "No hay ningún cambio de servicio que aplicar."
- skipped apply: `ya_existe_vacia` -> "Ya hay una operación vacía de ese servicio esperando su depósito: no se abre otra."; `reparto_rechazado` -> "No se pudo repartir el depósito entre los dos servicios: <detalle> No se cambió nada."; `sin_operacion` -> "No hay ninguna operación abierta de la que abrir la adicional: no se cambió nada."
- early refusals / errors (`sin_conversacion`, `no_autorizado`, internal error, resolver fail-open) carry a sentence too. Applied changes keep their sentence ("Se pasa la operación a ...", "El depósito cubre ... y ...", "Se abre una operación aparte para ...").

## Summary of the new agent-facing surface (274-279)

- `cerebro_guardar_zelle(conv, nombre, cuenta, exec, p_op, p_tool, p_posicion, p_agregar, p_monto)` - several recipients (274).
- Recipient writers open the declared operation before the deposit (275) and target the operation of their service, 250 rule included (276); `marcar_destino_usd` accepts `cup`.
- `repartir_envio` plans before the deposit, applies on an exact deposit, answers facts on a different one; `servicio_resuelto.reparto_planeado` (277).
- `calcular_usd` objective survives without an operation once `declarar_servicio` ran; declaring promotes the standing quote (278).
- `mensaje` never NULL from `cambiar_servicio` / `agregar_servicio` (279).
Left for the n8n side: tool nodes for the new Zelle parameters (posicion, agregar, monto), the `cup` value in `marcar_destino_usd`, a prompt line "declare first, then save data", and the Decisor reading `servicio_resuelto.reparto_planeado`.

## Step 3 check of the capability audit against 274-279 (before 280)

Already covered by 274-279: several Zelle recipients with a per-recipient `monto` (274); recipient writers and `registrar_numeros_recarga` open the declared
operation before the deposit (275); service-aware targeting of recipient writers with the 250 rule, `marcar_destino_usd` no longer re-types Mexico, `cup` rail (276);
a split planned before the deposit and facts on a different deposit (277); objective without an operation (278); `mensaje` never NULL (279). Per-recipient amounts for
cards already live in `registrar_reparto_multiple` (monto per card) and for Zelle in `registrar_beneficiario_zelle` (274), so `repartir_envio` does not duplicate them.
Still open when step 3 started: partial deposit (280), amount change / cancel / merge (new general tool), recharge number removal, `cambiar_servicio` absorbing
`marcar_destino_usd`, `gestionar_beneficiario` correction by position/type and `p_op`.

## 280 applied on staging - repartir_envio with a partial deposit (P1)

TDD: assertion `partial-deposit-split` RED (case 1: the 68,000 of 71,200 was refused with facts), GREEN 7 case groups. Cycle OK (dry-run, apply, assertion, rollback md5 equal for
_repartir_envio_core, cerebro_repartir_envio, cerebro_registrar_deposito). relacionadas --ya-aplicada (142 assertions): only DIFFs are the new assertion, the known flaky `contexto-envio-mixto`
and the pre-existing `delivery-feed-evidence` fixture error. `bot-mixed-split` case 3 was updated: parts ABOVE the verified deposit (a smaller sum is now a partial application).

Signatures:
- `cerebro_repartir_envio(p_conv uuid, p_partes text, p_execution text DEFAULT NULL) RETURNS text` - unchanged (the tool still reads `AS resultado`).
- `_repartir_envio_core(p_operation_id uuid, p_partes jsonb, p_audit_action text, p_actor text, p_reason text, p_parcial boolean DEFAULT false) RETURNS jsonb` (internal; the 5-argument overload was dropped,
  `crm_repartir_envio` still works). jsonb gains `parcial`, `asignado`, `deposito_verificado`, `sobrante`.

What the bot / Decisor can rely on (the bot decides, the DB validates money):
- Parts total = the operation's total: exact split as before ("Reparto hecho: ...").
- Parts total different, VERIFIED deposit (consumed MMG rows) > 0 and parts total <= verified deposit: PARTIAL application. Answer starts
  `Reparto parcial hecho: zelle 39,000 GYD, efectivo USD 29,000 GYD. Deposito verificado 71,200 GYD; asignado 68,000 GYD (sobran 3,200 GYD del deposito sin asignar). Pendiente, con su operacion y sus datos esperando deposito: tarjeta CUP 15,000 GYD (total 15,000 GYD). Cuando el cliente deposite se unira a su operacion.`
  (or `No quedan partes pendientes.`). `tool_execution_log.outcome = 'parcial'`. One part is accepted when the plan still has other parts (no group is created for it).
- Each part sent must reach the minimum of its service, else `REPARTO NO APLICADO: la parte tarjeta CUP (3,000 GYD) esta por debajo de su minimo (5,000 GYD). No se cambio nada. ...` and nothing changes.
- Parts above the verified deposit (or a deposit not verified yet): the 277 facts answer (`REPARTO NO APLICADO: las partes suman ...`), now ending with "o con solo las partes que el deposito verificado cubre (el resto queda pendiente)".
  A refused attempt never overwrites an existing plan.
- Pending parts = plan parts not sent: their empty operations (and recipient data) stay open and the plan keeps only them (`servicio_resuelto.reparto_planeado`). With two or more pending parts, a later verified
  deposit of exactly their total splits them by itself (277); a single pending part just receives the deposit (275).
- The holder of the deposit must be one of the parts sent (unchanged rule): with a plan waiting, `cerebro_registrar_deposito` now attaches the deposit to the plan's first listed part (deterministic), never to a member of an
  already covered group; the next deposit after a partial application goes to the pending part.
- Per-recipient amounts: use `registrar_beneficiario_zelle` (monto) and `registrar_reparto_multiple` (cup per card); not duplicated here.

## 281 applied on staging - cerebro_modificar_operacion: ONE general tool for the operation (amount, cancel, merge)

TDD: assertion `modificar-operacion` RED (function missing), GREEN 9 case groups (first GREEN attempt also exposed `remittance_admin_audit_action_chk`: the migration widens it with the three new actions).
Cycle OK (dry-run, apply, assertion, rollback md5). relacionadas --ya-aplicada (about 105 assertions matching audit/operation/cancel/merge/lock/incident/admin, run twice because the runner timed out before TOTAL): only DIFFs are the
new assertion, the known flaky `contexto-envio-mixto` and the pre-existing `delivery-feed-evidence` fixture error.

Signature (service_role only):
```
cerebro_modificar_operacion(p_conv uuid, p_op uuid, p_accion text, p_valor jsonb DEFAULT NULL, p_exec text DEFAULT NULL) RETURNS jsonb
```
Tool query for n8n (params: accion = monto|cancelar|unir, op = uuid or empty, valor = number / JSON object or empty):
`SELECT cerebro_modificar_operacion($1::uuid, NULLIF($2,'')::uuid, $3, NULLIF($4,'')::jsonb, 'agent:modificar_operacion n8n:' || $5) AS resultado;`
Helpers (service_role only): `_cerebro_op_tiene_dinero(uuid) boolean`, `_cerebro_nombre_servicio(text) text`.

Return: always `{ok boolean, mensaje text (plain Spanish, the Decisor can read it as is), motivo text (on ok=false), operation_id, ...}`.
- `monto`: `p_valor` = `19500` or `{"monto_gyd": 19500}` (GYD, what the customer deposits; compute it with calcular_usd first). ok=true: `{cambio, servicio, monto_anterior_gyd, monto_gyd, destino_monto, destino_moneda, deposito_verificado_gyd, mensaje}`;
  same value -> `{ok:true, cambio:false}`. Refusals (`ok:false`, nothing written): `monto_invalido`, `por_debajo_del_minimo {minimo_gyd}`, `supera_el_deposito {deposito_verificado_gyd, faltante_gyd}`
  (group-aware), `bloqueado_por_humano {campo}` (a lock left by a person; a lock left by automation:/agent: does not block), `estado_no_permite {estado}` (completed, cancelled, transferring).
  The destination amount follows through the existing trigger; the open send objective and a part of a waiting split plan follow the new amount.
- `cancelar`: only an operation with NO money (no deposit row, no receipt, not in a split group): `{ok:true, cambio:true, servicio, operaciones_abiertas}`; its part leaves the waiting plan, its objective closes.
  With money: `{ok:false, motivo:'tiene_dinero'|'en_grupo'}` and a mensaje saying a person handles it (owner question 1). Never moves or touches deposits (owner question 2).
- `unir`: `p_valor = {"con": "<uuid>"}` (or empty when exactly one other open operation of the same rail exists; p_op may also be empty when the conversation has exactly one such pair). Survivor = the operation that holds money,
  else p_op. Recipients move (twins by phone/card/account retired), amounts added, the other is cancelled. `{ok:true, operation_id (survivor), absorbida, monto_gyd, destinatarios_movidos, duplicados_retirados}`.
  Refusals: `no_hay_par`, `servicios_distintos`, `en_grupo`, `dinero_en_ambas`, `supera_el_deposito`, `por_debajo_del_minimo`, `bloqueado_por_humano`, `operacion_no_encontrada`, `estado_no_permite`.
- `p_op` empty with several open operations: `{ok:false, motivo:'varias_operaciones', operaciones:[{id,servicio,monto_gyd}], mensaje}` (the bot asks the customer which and calls again with the id).
- Audit: `remittance_admin_audit` actions `agent_amount_change`, `agent_operation_cancel`, `agent_operation_merge`; actor = p_exec when it starts with `agent:`, else `agent:modificar_operacion n8n:<p_exec>`. `tool_execution_log.tool_name = 'modificar_operacion'`.
