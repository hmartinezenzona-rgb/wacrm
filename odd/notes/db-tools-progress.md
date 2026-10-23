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
