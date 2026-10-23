# 269 / M5 staging (Cerebro agent side) - 2026-10-22

Staging workflow U52y1kSNvhgxvWeb only. Production untouched, workflow never executed.

## Done (version f74e9548 -> 0e362937, active = same)
- Backups: `~/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-f74e9548-...-151956.json` (before),
  `...-0e362937-...-152013.json` (after).
- Tools (Postgres tool nodes, staging credential, wired `ai_tool` -> Agente Remesas), builders in
  `pruebas/herramientas_269/herramientas.py`, applied by `aplicar_staging.py`:
  - `declarar_servicio(servicio)` -> `cerebro_declarar_servicio(conv, key, 'agent:declarar_servicio')`. It does NOT go
    through `cerebro_aplicar_servicio` with `p_intencion 'declarar'`: the resolver refuses that intent
    (265 R0 `intencion_invalida`, only cambiar|agregar). Declaring stores the intent; changing/adding executes.
  - `cambiar_servicio(servicio)` (existing node edited in place, was `cerebro_cambiar_servicio`) ->
    `cerebro_aplicar_servicio(conv, key, 'cambiar', 'agent:cambiar_servicio', exec)`.
  - `agregar_servicio(servicio)` (new) -> same with `'agregar'`, actor `agent:agregar_servicio`.
  - They return `mensaje` (DB plain Spanish), aplicado, permitido, motivo, minimo_gyd, faltante_gyd. Key normalisation
    only (`cup`->cuban_card, `efectivo`->efectivo_usd, `saldo movil`->saldo, `méxico`->mexico).
  - `registrar_numeros_recarga` now passes `p_abrir => true, p_actor => 'agent:registrar_numeros_recarga'`.
- Prompt (Agente Remesas `options.systemMessage`): the section `CAMBIO DE VIA` is replaced by `DECLARAR, CAMBIAR Y
  AGREGAR SERVICIO` (declare as soon as the customer states it, before paying; cambiar for a change of mind; agregar for
  an addition; never guess from receipt/amount/loose data; result handling by `motivo`), tool list and 2 few-shots
  updated, rule 10 reference updated. Backed by 18 offline tests (RED = module missing, GREEN after).
- SQL smoke (staging, one transaction, rolled back): the three queries and the numbers call run; `declarar mexico` and
  `cambiar mexico` return `servicio_invalido` until migration 273 (expected, no workaround).
- Albo leftovers: already absent from staging (no albo/clabe/spei/Humberto/mexico block in vision prompts, Historial
  contacto, Transcribir audio, Datos del negocio, Decisor). Nothing to remove.

## Blocked on 271/273 (not applied when this ran: rb_type_chk has no mexico types, no clabe/bank_name columns)
- `mexico` declarable/changeable: needs 273 (declarar/resolver/aplicar accept it).
- Recipient step for México (CLABE exactly 18 digits + bank + holder, or cardless withdrawal Coppel/BBVA + receiver
  name + phone) and removing the human handoff: no DB function exists, so no tool was added (a tool without its
  function would only fail). Needed DB side:
  - `cerebro_guardar_beneficiario_mexico(p_conv uuid, p_tipo text /* 'cuenta'|'retiro' */, p_clabe text, p_banco text,
    p_nombre text, p_telefono text, p_exec text) RETURNS jsonb` service_role only: finds/opens the conversation's
    `mexico` operation, validates CLABE ^[0-9]{18}$ (a CLABE never goes in card_number), retiro bank in (Coppel, BBVA),
    writes `remittance_beneficiaries` with beneficiary_type `mexico_cuenta`|`mexico_retiro` (clabe, bank_name, name,
    phone), merges partial data, returns `mensaje` + what is missing, audit actor `agent:registrar_destinatario_mexico`.
  - `cerebro_servicios.requiere_humano` for `mexico` -> false (and its message without "le paso con un operador") once the
    tool exists. Until then the prompt keeps following `consultar_servicio('mexico')` (handoff).
- When the function exists: clone `cambiar_servicio` node as `registrar_destinatario_mexico` (query
  `SELECT cerebro_guardar_beneficiario_mexico($1::uuid, $2, $3, $4, $5, $6, $7::text) AS resultado;`, fromAI: tipo,
  clabe, banco, nombre, telefono), add its line to the tool list and a MEXICO paragraph: ask for CLABE (18 digits),
  bank (Mercado Pago, Banco Azteca...) and holder, or Coppel/BBVA withdrawal (multiples of 100) with receiver name and
  phone; confirm in a block; no derivar_humano once the tool says complete.

## Risks
- 267 must not reach production before this prompt/tools (production constraint in service-resolution.md): production
  is still on the old design; this change is staging only.
- versionId == activeVersionId, but the in-memory-version trap is only ruled out by a later real execution (not run).
- A stray key `options.systemMessage` (old 44,964-char copy) sits in the Agente Remesas parameters; the live prompt is
  `options.systemMessage` (nested). Left alone.

## M5 follow-up: Mexico recipient tool (version 0e362937 -> 43cdf3ed, active = same, 131 nodes)
- Backups: before `...-0e362937-...-152948.json`; after: see `respaldo staging` of 43cdf3ed in `~/cerebro-fase1/respaldos-n8n/`.
- New tool node `registrar_destinatario_mexico` (fromAI: tipo, clabe, banco, nombre, telefono) ->
  `cerebro_guardar_beneficiario_mexico(conv, tipo, clabe, banco, nombre, telefono, p_exec)`, returns mensaje/ok/beneficiary_id.
  The 271 signature has NO p_actor, so the actor travels as the p_exec prefix `'agent:registrar_destinatario_mexico n8n:' || exec`;
  the DB side should read the actor from that prefix (or add p_actor and change the query).
- Prompt: MEXICO paragraph replaced (declare 'mexico', quote via=mexico, ask CLABE 18 digits + banco + titular OR Coppel/BBVA +
  nombre + telefono, save with the tool, no derivar_humano for Mexico once saved) and tool list line added.
- Deployed BEFORE 271 was applied on staging (odd/notes/db-mexico-progress.md absent): the tool fails until 271, 'mexico'
  is refused until 273. No rolled-back smoke of the call was possible. 21 offline tests GREEN (3 RED first).
- The catalog rule "requiere_humano=true => offer an operator" stays DB-driven; 273 flips it.

## Step 1 smoke (271+273 applied; one BEGIN/ROLLBACK, queries exactly as the nodes send them, conv PRUEBA TASAS)
- declarar mexico -> ok, "Anotado: el cliente va por mexico". cambiar mexico (no deposit) -> deposito_bajo_minimo, "el minimo es 13,000 GYD".
  agregar mexico -> adicional_aparte, new operation needs 13,000 GYD. Shapes match the node outputs.
- registrar_destinatario_mexico: cuenta complete (18-digit CLABE, bank, holder) saved; retiro Coppel saved; short CLABE, empty CLABE
  and retiro at another bank refused with a plain-Spanish mensaje. Audit actor = `agent:registrar_destinatario_mexico`, reason
  `agent:registrar_destinatario_mexico n8n:<exec>` (prefix parsing works). Beneficiaries written with clabe/bank_name/name/phone, source 'agente'.
- Difference found: NO partial merge for a cuenta (without a full CLABE nothing is saved). Tool description and prompt fixed to call
  the tool only with the full CLABE (cuenta) or banco+nombre+telefono (retiro). Deployed (see version in the report).

## Step 2 S4 (Contexto + Decisor read only the resolver state)
- `Contexto conversacion` (staging) now returns `servicio_resuelto` = `cerebro_resolver_servicio(v.id)` (resolver v2: operaciones, evidencia.declarado,
  motivo, permitido, minimo_gyd, faltante_gyd, adicionales) and each part of `envio_mixto` carries `usd` (destination USD, or GYD / unique rate for mexico).
  Verified read-only on staging (rolled back). Version 519650ba -> 1d6a3901.
- Decisor (md5 252f1489 -> 0e482f66, repo pin updated): with `servicio_resuelto` present, OPERACION EN CURSO (recarga/combo/visa), VIA ACTUAL (now
  mentions cambiar_servicio AND agregar_servicio, mexico label), ESTADO REAL (stage from the holder operation) and the "otros servicios" of a
  deposit de-mas come only from it; the legacy aliases (riel_operacion, *_en_curso, servicio_pendiente, historial stage) are read only when it is absent
  (one release). New notes: EL CLIENTE YA DECLARO <svc> (replaces servicio_pendiente), SERVICIO POR CONFIRMAR (permitido=false with
  deposito_bajo_minimo | varias_operaciones | depositos_separados: facts from the DB, "PROHIBIDO decir que ya cambio", ask).
- Marlene case: DEPOSITO DISTINTO DE LO ACORDADO EN VARIAS PARTES: grouped send (envio_mixto >= 2 parts) with verdict verificado_incompleto: finds the
  single part that absorbs the difference into a whole-USD amount (Mexico 150 -> 100 USD) and tells the bot to ASK ("Su depósito de 71,200 cuadra con
  100 USD a mexico, no con 150; ¿confirma?"), prohibits "se transfiere el equivalente" and "quedas esperando el resto". Only for verificado_incompleto
  (deposit short); the de-mas case keeps its existing "confirm how the deposit is split" note. Needs the parts as a mixed group (envio_mixto).
- Vitest: 7 RED first, then 43/43 GREEN (7 new + md5 pin).

## Step 3 S5b (test without the automatic readers) - version dc144e1b -> 84e217b8
- DISABLED (flag `disabled: true`, nothing deleted): `Registrar beneficiario auto`, `Registrar zelle auto`, `Registrar destino auto`. The first two feed
  `Contexto conversacion` (a disabled node passes its input through); the third has no output. The "notes_parse writers" are these same nodes
  (`remittance_beneficiaries.source = notes_parse` is what they write); there is no separate node. Left ON on purpose: `Registrar deposito auto`
  (money facts), `Registrar carnet efectivo` (ID photo has no tool), `Merge beneficiario` (read-only merge).
- Prompt: new section "SIN LECTORES AUTOMATICOS" (before REGLA DE ORO DEL REGISTRO) lists the tool for each datum (gestionar_beneficiario,
  registrar_reparto_multiple, registrar_beneficiario_zelle, registrar_numeros_recarga, registrar_destinatario_combo, abrir_extension_visa,
  registrar_datos_entrega_efectivo, registrar_destinatario_mexico, marcar_destino_usd, declarar/cambiar/agregar_servicio, repartir_envio) and says it
  overrides any "el sistema lo registra solo" line; removed "Los numeros escritos se guardan solos". Old intro/examples that mention automatic
  registration were left untouched (the section states precedence).
- Re-enable: `python3 pruebas/herramientas_269/aplicar_staging.py --esperado <live versionId prefix> --lectores on`, or `cerebro_n8n.py restaurar` with the
  backup `...-dc144e1b-...-162050.json`.
- Cases for the owner (PRUEBA scripts): `odd/notes/cerebro-s5b-casos.md`. Measurement NOT run. Katiuska's script is assumed to be the 1232671b
  recarga sequence (the only Katiuska detail in the docs).

## S5b follow-up (offline measurement 2026-10-22): prompt and Decisor
- Prompt (version 84e217b8 -> 80508084): the wording that taught "the system registers the recipient by itself" is REMOVED (TAREA sentence, the
  "Beneficiario YA REGISTRADO -> NO llames" bullet, rule 6, the clasica/tropical "se registra solo", and the 3 examples that said "NO llames ninguna tool"),
  not only overridden; the override sentence in the SIN LECTORES section went with it. Added: C1 (Zelle to several people: NOMBRE y CUENTA of EACH recipient before
  amounts), M1 (PRIMERO declarar_servicio('mexico'), via=mexico, CLABE+banco+titular or Coppel/BBVA+name+phone), M4/F3 (a deposit that differs from the agreed total of a
  multi-part send: reconcile and ASK which part changes; forbids "se transfiere / se ajusta el equivalente"), F1 ("ademas una recarga" -> agregar_servicio).
  Offline tests 38/38 (RED first: the new class errored before the builder existed).
- Decisor (md5 0e482f66 -> 648aea17, staging version 356b122b, pin updated): (a) with a declared recarga the "TODAVIA NO HAY BENEFICIARIO REGISTRADO" note now
  says registrar_numeros_recarga (no card), with mexico registrar_destinatario_mexico; the stale "llama gestionar_beneficiario con el celular" is gone for
  those; (b) the reconcile note ("DEPOSITO DISTINTO DE LO ACORDADO EN VARIAS PARTES") also fires for over-deposits when one part fits in whole USD, and for a short
  deposit with no exact part it still asks which part changes. Vitest 4 RED -> 47/47 GREEN.
- Pending: planned parts (DB agent's repartir plan) and the new tool signatures (odd/notes/db-tools-progress.md did not exist yet).

## 274 wired (Zelle several recipients) - staging 356b122b -> 5ab? see report
- `registrar_beneficiario_zelle` now calls the 9-argument `cerebro_guardar_zelle` (p_tool 'registrar_beneficiario_zelle', posicion, agregar, monto). New fromAI params:
  posicion, agregar, monto (strings, empty = none). Tool description and the prompt (tool line + C1 block) explain agregar=true for another person, posicion=k to correct,
  monto in USD, and the "NO SE GUARDO NADA" refusal. 5 new offline tests (RED -> 43/43 GREEN).
- Rolled-back smoke (PRUEBA conversation, no open op): recipient 1 (60 USD) -> agregar=true recipient 2 (40 USD) -> correction by posicion=1 -> a third account without
  parameters is refused ("NO SE GUARDO NADA ... agregar=true") -> same account corrects the amount (45 USD). End state: 2 vigente, old rows 'reemplazado'.
- Waiting for 275-279 in odd/notes/db-tools-progress.md (only 274 present).

## 275 wired (pre-deposit operations from the declared intent)
- No tool signature changed. The prompt now says DECLARA PRIMERO (declarar_servicio before saving recipient data: the data tools open the operation from the declaration;
  without it the Mexico/cash tools say no open send). Rolled-back smoke: registrar_destinatario_mexico before declaring -> refused; after declarar_servicio('mexico') with no
  operation -> opens the mexico operation (0 GYD, MXN, collecting_information) and saves the recipient. Offline test added (44 total).

## 276 wired (writers target the operation of their service)
- `marcar_destino_usd`: description and fromAI now accept 'cup' and say it only touches remesas (never recarga/Mexico); prompt tool line updated and a
  "ENVIO MIXTO CON TARJETA" rule added (card -> gestionar_beneficiario + marcar_destino_usd on the remesa; recarga numbers -> registrar_numeros_recarga on their own op).
- Rolled-back smoke (mixed send): declared clasica + card -> the remesa; declared recarga + number -> its own recarga op (2 ops, each with its own data); 'cup' retyped only
  the remesa (cuban_card), the recarga untouched. 46 offline tests GREEN (RED first).

## 277-279 wired
- 277: `Contexto conversacion` already passes the whole resolver state, so `servicio_resuelto.reparto_planeado` reaches the Decisor with no query change (verified in a
  rolled-back smoke). Decisor reconcile note now built from `reparto_planeado.partes` (preferred over `envio_mixto`): with a receipt this turn (short or over) and WITHOUT one
  when a deposit is already registered and `coincide=false` (`deposito_gyd > 0`); one note only; no exact part -> still asks which part changes. `repartir_envio` description
  (plan BEFORE the deposit, mexico part, "REPARTO NO APLICADO" = ask which part changes) and a prompt rule "REPARTO ANTES DEL DEPOSITO". vitest 5 RED -> 52/52 GREEN
  (pin 8c421a94...), python 47 GREEN.
- Smoke (rolled back, PRUEBA conversation): `repartir_envio("mexico 39000, efectivo 29000, cup 5000")` before any deposit -> plan; a 60,000 deposit registered ("movido") ->
  `reparto_planeado` {total 73,000, deposito 60,000, diferencia -13,000, coincide false}; repartir again -> "REPARTO NO APLICADO ... faltan 13,000 GYD".
- 278/279: no n8n change needed (declarar_servicio keeps working, objetivo promoted by the DB; `mensaje` never NULL; the cambiar/agregar prompt already says to tell `mensaje`).
