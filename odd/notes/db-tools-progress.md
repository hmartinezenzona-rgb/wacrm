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

## 282 applied on staging - registrar_numeros_recarga gains `quitar` (no new tool)

TDD: assertion `recarga-quitar` RED (5-argument signature missing), GREEN 7 case groups. Cycle OK (dry-run, apply, assertion, rollback md5). relacionadas --ya-aplicada (97 assertions: recarga/numbers/writers/audit/visa/saldo...):
only DIFFs are the new assertion and `modificar-operacion` case 7 (a created_at tie inside one transaction made "survivor is the older" random; the assertion now checks the pair, fixed and re-run 4x).

Signature (old 4-argument overload dropped; 4-argument calls keep working):
```
crm_registrar_numeros_recarga(p_conv uuid, p_texto text, p_abrir boolean DEFAULT false, p_actor text DEFAULT NULL, p_accion text DEFAULT 'agregar') RETURNS text   -- service_role only
```
Tool query for n8n (extra param `accion` = agregar|quitar, default agregar):
`SELECT crm_registrar_numeros_recarga($1::uuid, $2, false, 'agent:registrar_numeros_recarga n8n:' || $3, COALESCE(NULLIF($4,''),'agregar')) AS resultado;`
(the existing query keeps working unchanged).
- `quitar`: the Cuban numbers written in `p_texto` (same parser/spellings as agregar: 55502222, 5550-2222, +53 5 5502222) leave the conversation's OPEN recharge (row retired, status `reemplazado`, positions compacted, audit
  `agent_recharge_number_removed`). Never opens a recharge. Answers (text): `quitados 1 numero(s) de recarga; la recarga tiene 2. [No estaban en la recarga: 55509999.] [Numeros completos (2 de 2). | FALTA n numero(s) ...]`;
  `no vi ningun numero cubano en el texto: no se quito nada; la recarga tiene N.`; `sin recarga en curso: no hay ningun numero de recarga que quitar`; transferring: `la recarga ya esta en transferencia: no quito numeros, una persona lo revisa`;
  recipients locked from the panel: the usual `los numeros de esta recarga los gestiona una persona desde el panel: no se cambian`; bad action: `ERROR: la accion debe ser agregar o quitar. No se cambio nada.`
- A removed number can be added back with `agregar`.
- The audit action list (`remittance_admin_audit_action_chk`) gained `agent_recharge_number_removed`.

## 283 applied on staging - cambiar_servicio absorbs marcar_destino_usd (every rail is a service target)

TDD: assertion `service-rails-as-targets` RED (case 2: "cup" was servicio_invalido), GREEN 8 case groups. Cycle OK (dry-run, apply, assertion, rollback md5 for declarar/aplicar/resolver/crm_registrar_numeros_recarga).
relacionadas --ya-aplicada (148 assertions): only DIFFs are the new one, the flaky `contexto-envio-mixto` and the pre-existing `delivery-feed-evidence`. The first runs found two real regressions that were fixed before this version:
`writers-target-by-service` case 6 (opening a recharge must not turn an empty clasica into the recharge: `crm_registrar_numeros_recarga` now asks the resolver only when money is registered, as before) and
`resolver-servicio` cases 10/17 (the 265 contract: recarga / saldo / combo / visa / mexico still need the money first; `cup` is no longer an invalid word, the invalid-word cases now use `pizza`).

Signatures unchanged (`cerebro_aplicar_servicio`, `cerebro_resolver_servicio`, `cerebro_declarar_servicio`). New helper (service_role only): `_cerebro_servicio_clave(text) RETURNS text`.
The `cambiar_servicio` / `declarar_servicio` / `agregar_servicio` tool queries need no change. What the agent can rely on:
- Words are understood by the DB: `cup`, `pesos`, `tarjeta cup`, `tarjeta` -> cuban_card; `efectivo`, `Efectivo USD` -> efectivo_usd; `CLASICA...` -> clasica; `Tropical...` -> tropical (also in declarar_servicio). Unknown words still answer `servicio_invalido`.
- A change TO A RAIL (zelle, clasica, tropical, cuban_card, efectivo_usd) with no money registered at all is applied (it used to answer `deposito_bajo_minimo "faltan 13,000"` for an empty operation); the minimum is checked when the deposit arrives.
  With a deposit nothing changed. recarga / saldo / combo / visa / mexico still need their money first.
- Several open operations and no deposit, rail target: an operation already of that rail -> `sin_cambio`; otherwise the single plain REMESA is converted (Mexico / recarga / combo / visa / balance operations are never re-typed and nothing else is cancelled);
  two remesas stay `varias_operaciones`. A waiting split plan (`reparto_planeado`) is renamed to the new rail.
- `cerebro_marcar_destino_usd` is unchanged and still works; it now carries `COMMENT ... 'DEPRECATED (283): use cambiar_servicio...'`. The n8n side can stop offering `marcar_destino_usd`.

## 284 applied on staging - gestionar_beneficiario corrects ONE recipient and validates the operation the bot names (no new tool)

TDD: assertion `correct-recipient` RED (9-argument signature missing), GREEN 7 case groups. Cycle OK (dry-run, apply, assertion, rollback md5). relacionadas --ya-aplicada (144 assertions: beneficiary/recipient/reparto/zelle/writers/cash/recarga/combo/audit...):
only DIFFs are the new assertion, the flaky `contexto-envio-mixto` and the pre-existing `delivery-feed-evidence`.

Signature (7-argument overload dropped; old calls keep working through the defaults; `gestionar_beneficiario`'s tool query is `cerebro_guardar_beneficiario`):
```
cerebro_guardar_beneficiario(p_conv uuid, p_nombre text, p_tarjeta text, p_celular text, p_exec text,
                             p_op uuid DEFAULT NULL, p_tool text DEFAULT 'gestionar_beneficiario',
                             p_posicion integer DEFAULT NULL, p_tipo text DEFAULT NULL)
  RETURNS TABLE(deal_id uuid, accion text)      -- service_role only
```
Tool query for n8n (new params: op = uuid or empty, posicion = int or empty, tipo = tarjeta|zelle|efectivo|recarga|mexico or empty):
`SELECT deal_id AS id, accion FROM cerebro_guardar_beneficiario($1::uuid, NULLIF($2,''), NULLIF($3,''), NULLIF($4,''), $5, NULLIF($6,'')::uuid, 'gestionar_beneficiario', NULLIF($7,'')::int, NULLIF($8,''));`
Behaviour:
- `p_op`: must be an open operation of this conversation, else `NO SE GUARDO NADA: esa operacion no es de esta conversacion o ya no esta abierta. ...` (nothing written). Otherwise unchanged (the named operation is the target).
- `p_posicion` and / or `p_tipo` = CORRECTION of that one recipient with the data given (name, card, phone; the others stay): `corregido (destinatario 2 de 2): nombre Ana Perez. Destinatarios ahora: 1) ... ; 2) ...`.
  Operation = `p_op`, else the single open operation that has recipients of that kind (several: `NO SE GUARDO NADA: hay N envios abiertos con ese destinatario. Indica a cual (operacion)...`; the chat is NOT handed to a person here).
  Several recipients and no position: the answer lists them and asks which. Unknown position: lists them. Same data: `sin cambios: ...`. A card already used by another recipient of the operation: refused.
  A card or phone on a Zelle / cash / recharge / Mexico recipient is refused naming the tool that owns it (`registrar_beneficiario_zelle`, `registrar_datos_entrega_efectivo`, `registrar_numeros_recarga`, `registrar_destinatario_mexico`): only the name is corrected here.
  A lock a person left on the recipients is respected. Audit action `agent_beneficiary_corrected` (before / after), actor `agent:<p_tool> n8n:<p_exec>`. `deal_id` = operation id (NULL on a refusal).
- Without `p_posicion` / `p_tipo` the behaviour is exactly the old one (single recipient write, reparto slots, D1 rules).

## Step 3 summary (280-284) and final sweep

Final sweep of all 167 assertions on the staging state after 284 (each in a rolled-back transaction): 142 pass; the 25 that fail are exactly the known set of `staging-assertions-triage-2026-10-22.md` (19 pre-existing + 4 `pg_temp` harness +
`deal-free-beneficiary-writers` / `reparto-destino-node-adapters`, which print their own expected-error output). Nothing new fails; `contexto-envio-mixto` (flaky tie on created_at) passed in this run.
New agent-facing surface: `repartir_envio` partial deposit (280), `cerebro_modificar_operacion` (281), `registrar_numeros_recarga` `accion='quitar'` (282), `cambiar_servicio` words / rails / pre-deposit / service-aware target and `marcar_destino_usd` deprecated (283),
`gestionar_beneficiario` `p_posicion` / `p_tipo` / validated `p_op` (284). Left for n8n (step 4): tool nodes / descriptions for the new parameters above, the prompt lines, and the Decisor reading the plain-Spanish `mensaje` / `accion` texts.

## 285 applied on staging - registrar_beneficiario_zelle refuses the ambiguous second account (step 6, S5b2 finding)

TDD: assertion `zelle-ambiguous-account` RED (case 1: the second account replaced the first), GREEN 4 case groups. Cycle OK (rollback md5). relacionadas --ya-aplicada (135 assertions): only DIFFs are the new assertion, the updated
`zelle-several-recipients` case 9 (old contract was "replaced") and the pre-existing `delivery-feed-evidence`. `partial-beneficiary-tools` 6d now names `posicion=1` for its account correction. The automatic reader
(`p_tool = 'Registrar zelle auto'`, still alive in production) keeps its replace behaviour, so `partial-beneficiary-auto` is unchanged.

Signature unchanged: `cerebro_guardar_zelle(p_conv, p_nombre, p_cuenta, p_exec, p_op, p_tool, p_posicion, p_agregar, p_monto)`.
- ONE recipient in force + a DIFFERENT account + no `agregar` / `posicion`: nothing is written, `accion` = `NO SE GUARDO NADA: este envio ya tiene un destinatario Zelle (1) Maria Lopez / maria@example.com y esa cuenta (5551234567) es otra. Preguntale al cliente si es OTRA persona (llama con agregar=true) o si corrige la cuenta de ese destinatario (llama con posicion=1). No se cambio nada.`
  The retry with `agregar=true` adds recipient 2; `posicion=1` corrects the account of recipient 1.
- Completing a recipient that has no account yet, correcting a holder name and repeating the same account behave as before.
- Amounts (`p_monto`, USD) are stored on the recipient (`amount` + `currency 'USD'`), survive name-only and account-only calls, and a corrected account (`posicion=k`) keeps the slot's amount (the holder starts empty, as in 274).
  The S5b2 "200/100 never stored" case came from the agent tool not passing `monto`/`posicion`/`agregar` yet (n8n side); the DB side is asserted.

## 286 applied on staging - cambiar_servicio to efectivo_usd keeps the customer's data (step 6, S5b2 finding)

TDD: assertion `cash-keeps-recipient` RED (case 1: the card retired and NO cash recipient existed), GREEN 6 case groups. Cycle OK (rollback md5 for `_cambiar_servicio_core`, `cerebro_aplicar_servicio`).
relacionadas --ya-aplicada (126 assertions): only DIFFs are the new assertion, the flaky `contexto-envio-mixto` and the pre-existing `delivery-feed-evidence`. First run found a regression in `cash-recipient-add`
(the panel flow expects an empty operation after the card retires): the new recipient is created only for the bot's callers (`agent_service_change` / `automation_service_change`), never for `human_correction`.

Signatures unchanged. Behaviour (the `cambiar_servicio` tool query needs no change):
- To `efectivo_usd` with no recipient able to receive cash: the first recipient carrying a name or a phone gives them to a NEW `efectivo_usd` recipient (position 1); the card / Zelle account is retired (cash cannot use it).
  `_cambiar_servicio_core` returns `created` (ids); the audit `after` carries `created`/`created_recipients`.
- `cerebro_aplicar_servicio` appends to `mensaje`: `Se pasa la operación a efectivo en USD. Ya tengo el nombre Rosa Gomez y el celular 53821203; falta la dirección en Cuba.`
  (variants: only phone, only name -> `falta el celular y la dirección en Cuba`); with neither name nor phone no recipient is invented: `La tarjeta o cuenta guardada no sirve para efectivo y no tengo datos de quien recibe: falta el nombre, el celular y la dirección en Cuba.`
- `registrar_datos_entrega_efectivo` then completes that same recipient (one in force). A second conversion attempt answers `sin_cambio`.

## 287 applied on staging - cerebro_modificar_operacion gains `mover_deposito` (owner decision 2026-10-23, Engram cerebro/bot-moves-deposit)

TDD: assertion `move-deposit` RED (action unknown), GREEN 7 case groups. Cycle OK (rollback md5). relacionadas --ya-aplicada (161 assertions: modificar/deposit/audit/operation/lock): only DIFFs are the new assertion and the pre-existing `delivery-feed-evidence`.

Signature unchanged: `cerebro_modificar_operacion(p_conv uuid, p_op uuid, p_accion text, p_valor jsonb DEFAULT NULL, p_exec text DEFAULT NULL) RETURNS jsonb`. New `p_accion = 'mover_deposito'`:
`p_op` = operation that holds the deposit; `p_valor = {"a": "<target operation uuid>", "deposito": "<MMG trans_id>"}` (`deposito` only when the source holds several verified deposits).
- Rules: same conversation; source and target open (not transferring / completed / cancelled); neither in a split group; no lock a person left on either (any field); the source must hold a VERIFIED deposit (consumed, not voided / discarded);
  the deposit moves WHOLE (one `depositos_mmg` row plus the receipts of its reference): never split, never duplicated; the target with that deposit must reach its service minimum and may not exceed what it asks.
- ok=true: `{ok, cambio, deposito, monto_gyd, origen, destino, estado_origen, estado_destino, deposito_destino_gyd, mensaje}`. The target takes the deposit (an empty request becomes the deposit amount) and is `ready_to_transfer` when covered, else `deposit_verification`
  (mensaje says how much is still missing); the source goes back to `awaiting_deposit` when that was its only money (its request is kept); the open objective that followed the source follows the target.
- ok=false (nothing written), `motivo`: `falta_destino`, `operacion_no_encontrada`, `estado_no_permite`, `en_grupo`, `bloqueado_por_humano {campo}`, `sin_deposito_verificado`, `varios_depositos` (the mensaje lists them),
  `deposito_no_encontrado`, `por_debajo_del_minimo {minimo_gyd, deposito_gyd, faltante_gyd}`, `deposito_mayor_que_el_envio {deposito_gyd, monto_gyd}` (change the target's amount first).
- Audit: action `agent_deposit_move` on BOTH operations (before / after with trans_id and amount), actor `agent:modificar_operacion n8n:<exec>`; tool log outcome `deposito_movido`. The audit action list gained `agent_deposit_move`.
- The n8n tool query is the same as for the other actions: `SELECT cerebro_modificar_operacion($1::uuid, NULLIF($2,'')::uuid, $3, NULLIF($4,'')::jsonb, 'agent:modificar_operacion n8n:' || $5) AS resultado;` with accion `mover_deposito`.

## 288 applied on staging - explicit grants for everything 243 and 265-287 create or replace (production readiness B)

Production conventions read with catalog SELECTs (project hqztotshnlzaiziwjyzh, 2026-10-23): default privileges for `postgres` in public are functions `postgres=X` only, tables `anon/authenticated/service_role = Dxtm`
(no SELECT / INSERT / UPDATE / DELETE), sequences postgres only; comparable objects: agent tools (`cerebro_repartir_envio`, `cerebro_registrar_deposito`, `cerebro_fijar_objetivo`, `crm_registrar_datos_entrega_efectivo`...) = postgres + service_role;
panel RPCs (`crm_agregar_beneficiario`, `crm_beneficiarios_completos`, `crm_corregir_beneficiario`) = postgres + authenticated; `crm_operaciones_de_conversacion`, `cerebro_dashboard_historial`, `crm_repartir_envio` = postgres + authenticated + service_role;
helpers (`_repartir_envio_core`, `_cambiar_servicio_core`, `cerebro_minimo_gyd`, `cerebro_riel_op`, `cerebro_resolver_para_guardar`, `cerebro_guardar_*_auto`) = postgres only; `calculator_service_for_operation` = PUBLIC (left untouched).

`supabase/migrations/288_grants.sql` (idempotent; ROLLBACK restores the broad staging ACLs) states for 14 + 3 + 3 + 19 functions:
- agent-facing, EXECUTE for service_role only: cerebro_aplicar_servicio, cerebro_declarar_servicio, cerebro_cotizar, cerebro_fijar_objetivo, cerebro_guardar_beneficiario (9 args), cerebro_guardar_beneficiario_mexico, cerebro_guardar_zelle (9 args), cerebro_marcar_destino_usd,
  cerebro_modificar_operacion, cerebro_registrar_deposito, cerebro_repartir_envio, crm_registrar_datos_entrega_efectivo, crm_registrar_numeros_recarga (5 args), cerebro_parsear_beneficiarios;
- authenticated + service_role: crm_operaciones_de_conversacion, cerebro_dashboard_historial, cerebro_resolver_servicio; authenticated only: crm_agregar_beneficiario, crm_beneficiarios_completos, crm_corregir_beneficiario;
- postgres only (their callers are SECURITY DEFINER and run as the owner): _cambiar_servicio_core, _cerebro_aplicar_plan_reparto, _cerebro_nombre_servicio, _cerebro_op_parte, _cerebro_op_tiene_dinero, _cerebro_operacion_declarada, _cerebro_ops_para_datos,
  _cerebro_partes_envio_parse, _cerebro_reparto_planear, _cerebro_servicio_clave, _cerebro_texto_partes, _cerebro_usd_parte, _repartir_envio_core (6 args), calculator_resolve_operation_service, cerebro_guardar_beneficiario_auto,
  cerebro_limpiar_servicio_declarado (trigger), cerebro_minimo_gyd, cerebro_resolver_para_guardar, cerebro_riel_op;
- tables `cerebro_servicio_declarado` and `cerebro_reparto_planeado`: RLS on, `service_role` SELECT / INSERT / UPDATE / DELETE, nobody else. No sequences are owned by them and no column-level grants exist (the new `remittance_beneficiaries.clabe` / `bank_name` ride on the table privileges).

TDD / proof: assertion `grants-mirror-production` sets every public table / view to production's real ACL, the 33 functions to the production default (postgres only) and the two new tables to the default of a new table, then (RED) the calls AS `service_role`
and AS `authenticated` with a member JWT claim fail with 23 permission-denied errors; after 288's statements are re-applied in the same transaction every call passes (business refusals are ignored: the assertion proves privileges only), plus negative checks
(authenticated cannot execute the agent tools, service_role cannot execute the panel-only RPCs, no sequence). Objects that NEEDED a grant (the RED list): the 14 agent tools and `cerebro_parsear_beneficiarios` for service_role; `cerebro_resolver_servicio`, `crm_operaciones_de_conversacion`,
`cerebro_dashboard_historial`, `crm_agregar_beneficiario`, `crm_beneficiarios_completos`, `crm_corregir_beneficiario` for authenticated; the two new tables for service_role. Everything else passes through SECURITY DEFINER.
Cycle OK (dry-run, apply, assertion). Full sweep of the 170 assertions on the narrowed staging state: 146 pass, the 24 that fail are all in the known triage set (nothing new).

## 289 applied on staging - the declaration of the service is a consequence of the tools the bot already uses (production readiness A)

TDD: assertion `implicit-declaration` RED (case 1: a mexico quote declared nothing), GREEN 5 case groups. Cycle OK (rollback md5 for `cerebro_cotizar`, `crm_registrar_numeros_recarga`). relacionadas --ya-aplicada (151 assertions): only DIFFs are the new assertion and the pre-existing `delivery-feed-evidence`.
The staging `calcular_usd` / `calcular_usd_desde_gyd` / `calcular_envio` / `calcular_inverso` tools all call `cerebro_cotizar` (243); `cerebro_fijar_objetivo` receives only an amount, so it declares nothing.

Signatures unchanged (`cerebro_cotizar(p_conv, p_monto, p_direccion, p_moneda_destino, p_via, p_execution_id)`, `crm_registrar_numeros_recarga(p_conv, p_texto, p_abrir, p_actor, p_accion)`). New internal helper (postgres only, state set in the migration):
`_cerebro_declarar_implicito(p_conv uuid, p_servicio text, p_origen text) RETURNS boolean`.
- A quote that NAMES its service declares it with actor `implicit:cotizar`: `via` zelle / clasica / tropical / mexico (words accepted as in `_cerebro_servicio_clave`: "Clásica" ok), a CUP quote = `cuban_card`, `via` efectivo = `efectivo_usd` (declared even though the quote answers `efectivo_tiene_tasa_propia`).
  An empty `via` (the Zelle default) and `usdt` declare nothing.
- Never over a declaration the bot made (any actor not starting with `implicit:`: declarar_servicio, cambiar_servicio, recarga numbers...); an implicit declaration IS replaced by the next implicit one (customer asking prices of two services: the last quote wins).
  Skipped when an open operation of ANOTHER service already holds money (a price question is not a change of service).
- `crm_registrar_numeros_recarga` with `p_abrir = true` calls `cerebro_declarar_servicio(conv, 'recarga', actor)` (actor = `p_actor`, e.g. `agent:registrar_numeros_recarga`): latest declaration wins, cleared when the last operation closes. Without `p_abrir` nothing is declared.
- The later deposit attaches to the declared service (asserted: a mexico quote then a 13,000 deposit = the Mexico operation; recarga numbers then 6,200 = the one recarga operation).

## 290 applied on staging - México recipients carry the USD that goes to each one (owner panel review; no new tool)

TDD: assertion `mexico-recipient-amount` RED (observed against the rolled-back pre-290 state: `cerebro_guardar_beneficiario_mexico(... p_monto => ...)` does not exist), GREEN 12 case groups. Cycle OK (dry-run, apply, assertion, rollback).
relacionadas --ya-aplicada (13 assertions): 3 DIFFs, all updated here: `mexico-recipient` (case 10 now uses a field that still does not apply; privilege check on the new signature), `grants-mirror-production` (new signature), and the new assertion itself.
Fixture on staging: conversation 92d1eaf3 (PRUEBA Mexico panel), op 27a09750: both recipients now 50 USD through the new function (the operation is 26,000 GYD = 100 USD).

Signature (7 -> 10 arguments; the 7-argument function was dropped, the old call shape still works through the defaults):
```
cerebro_guardar_beneficiario_mexico(p_conv uuid, p_tipo text, p_clabe text, p_banco text, p_nombre text, p_telefono text, p_exec text,
                                    p_posicion integer DEFAULT NULL, p_agregar boolean DEFAULT false, p_monto numeric DEFAULT NULL)
  RETURNS jsonb  -- {ok, mensaje, beneficiary_id}; service_role only
```
Internal helper (postgres only): `_cerebro_mexico_tope_usd(p_op uuid, p_excluir uuid, p_monto numeric) RETURNS text` (NULL = fits). Panel RPCs keep their signatures: `crm_agregar_beneficiario` / `crm_corregir_beneficiario` accept `amount` (and `currency` only 'USD') on México rows; correction with `amount: null` clears it. Grants re-stated per 288 in the migration (agent tool service_role, helper none, panel RPCs authenticated).
- `p_monto` = USD for that recipient (amount + currency 'USD' + amount_origin 'manual'); kept when a later call has none; <= 0 refused.
- No `p_posicion` / `p_agregar` = old behaviour (same CLABE, or same retiro phone+bank, updates that recipient; anything else appends).
- `p_agregar = true` = another person (same CLABE patches that one). `p_posicion = k` (1..N+1) = correction of slot k in place (amount kept; fields not sent are taken from the slot, so only `p_monto` sets an amount); N+1 appends; other values and a CLABE that is another slot's are refused ("NO SE GUARDO NADA ...").
- Cap: sum of recipient amounts <= `_cerebro_usd_parte('mexico', quoted_source_amount)`; over it: `Los montos no cuadran: ... mas de los N USD de este envio. No se guardo nada; revisa los montos con el cliente.` (panel RPCs raise the same text, errcode 22023). No cap while the operation has no deposit.
- n8n tool query (params clabe, banco, nombre, telefono, tipo, monto, posicion, agregar): `SELECT cerebro_guardar_beneficiario_mexico(...,NULLIF($,'')::int, coalesce(NULLIF($,'')::boolean,false), NULLIF($,'')::numeric)`.

### 290 n8n (staging only, U52y1kSNvhgxvWeb)
`registrar_destinatario_mexico` now passes `posicion`, `agregar` and `monto` (`$fromAI`, required, empty when not applicable) as `$8..$10`; the tool description explains monto / agregar / posicion and the "No se guardo nada" cap refusal.
Backups: before `staging-U52y1kSNvhgxvWeb-6ce1b948-...-20261023-133542.json`, after `staging-U52y1kSNvhgxvWeb-141a7857-...-20261023-133610.json` (versionId == activeVersionId, 132 nodes, Decisor unchanged). Smoke (rolled back, the tool's exact query, no workflow execution): two CLABEs of 50 USD on a 100 USD operation both saved; a third of 10 refused with the cap message. Production not touched.
