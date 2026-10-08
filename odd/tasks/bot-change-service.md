# The bot changes the customer's service itself

## Objective
When a customer changes how they want to receive the money ("Mejor zelle"), before or after the receipt, before or after the deposit
is verified, the BOT changes the open operation's service by itself and tells the customer the new amount. No hand-over to a human
for the change itself. (Owner decision, 2026-10-08.)

## Incident (production, 2026-10-08, Carlos, operation 27fc3d2f, conversation b3334214, exec 364120)
Customer asked cash USD (quoted 290 GYD/USD -> 162 USD for 47,100 GYD), sent the receipt, then wrote "Mejor zelle". The bot quoted
181 USD by Zelle in words but the operation stayed `delivery_method='efectivo_usd'` / 162 USD. Root causes (verified):
1. The bot has NO write path to Zelle. `marcar_destino_usd` -> `cerebro_marcar_destino_usd` takes clasica / tropical / efectivo only
   (the agent prompt says "NO se usa para Zelle"); `cerebro_registrar_destino` never overwrites efectivo_usd / zelle;
   `calcular_usd_desde_gyd` with via=zelle only stores a quote (`cerebro_ultima_cotizacion`); the panel's `crm_cambiar_servicio`
   (222-224) is executable only by `authenticated` and needs `is_account_member`.
2. A race: the receipt turn processed its batch before the "Mejor zelle" text arrived and marked "efectivo" from chat memory.
3. The Decisor computes `viaSinDefinir` ignoring `operation.delivery_method` / `entrega_efectivo_en_curso`.
4. The Notifier sent "faltan los datos de quien recibe el efectivo" on ready_to_transfer because the rail was still efectivo_usd
   (`automation_late_deposit_verification` is in its `verificacion_manual` list).
Bot workflow `jEzlVLCLUaJhVwzs` ("Cerebro v2 — LEGACY OPTIMIZED V1"); notifier `wGud0KGR6eMqqfMQ`.

## TDD
Mode: strict TDD ON. Source: user global CLAUDE.md. Runners: DB = staging SQL assertion run with the docker `postgres:17` psql against
`CRM_STAGING_DATABASE_URL`, wrapped in `BEGIN; <assertion without its own BEGIN/ROLLBACK/\set>; ROLLBACK;` (never plain `psql -1`:
it can COMMIT a fixture). Bot prompt/Decisor (Part B): the evals harness `~/cerebro-fase1/pruebas/evals/evaluar.py` + node harness
(`banco-*.js`, `candidato-decisor-*.js`). No TypeScript touched: `tsc` not needed.

## Design (Part A, done)
Migration `supabase/migrations/230_bot_change_service.sql` (+ `ROLLBACK-230-bot-change-service.sql`, no BEGIN/COMMIT in either file).
- `_cambiar_servicio_core(op uuid, servicio text, audit_action text, actor text, reason text) RETURNS jsonb`: the ONE implementation,
  moved unchanged out of `crm_cambiar_servicio` (223). INTERNAL: no grants to PUBLIC/anon/authenticated/service_role.
- `crm_cambiar_servicio(uuid, text)`: same signature, grants (authenticated + service_role, not anon), refusals (P0002, 42501, 22023)
  and returned shape; after its validations it calls the core with `human_correction` / `wacrm_current_actor()` / no reason.
- `cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL) RETURNS jsonb`, granted to
  `service_role` ONLY (the same role as `cerebro_marcar_destino_usd` on staging: ACL `{postgres, service_role}`).
  - Services: cuban_card, zelle, clasica, tropical, efectivo_usd, recarga, combo, visa, saldo (trim, case-insensitive); aliases
    `cup` -> cuban_card, `efectivo` -> efectivo_usd.
  - Operation: the conversation's single open operation among collecting_information, awaiting_deposit, deposit_received,
    deposit_verification, ready_to_transfer, incident. None open -> latest operation decides (completed / cancelled / transferring ->
    `estado_no_permite` with its status; no operation -> `sin_operacion`). Two or more -> the bot's usual hand-over
    (`cerebro_registrar_derivacion`, razon `operacion_ambigua`) and `operacion_ambigua`.
  - Reason codes (all `{ok:false, reason, ...}`, nothing written except the tool log line and the ambiguity hand-over):
    `servicio_desconocido`, `sin_operacion`, `operacion_ambigua` (+ `derivado`), `estado_no_permite` (+ `status`), `tipo_no_soportado`
    (+ `service_type`), `bloqueado_por_humano` (+ `campo`: delivery_method | service_type | quoted_destination_amount locked by a
    non-automation actor), `por_debajo_del_minimo` (+ `servicio`, `minimo_gyd`, `source_amount_gyd`), `varios_destinatarios`.
  - Minimum: judged by the existing `cerebro_minimo_gyd` on the changed operation inside a sub-block that is rolled back on failure
    (no threshold duplicated; the exact minimum passes; no source amount -> no check).
  - Same service: `{ok:true, changed:false, operation_id, servicio, source_amount_gyd, destination_amount, destination_currency, rate, status}`.
  - Success: `{ok:true, changed:true, operation_id, servicio, source_amount_gyd, destination_amount, destination_currency, rate,
    previous:{servicio, destination_amount, destination_currency, rate}, retired_recipients, retyped_recipients, status}`.
  - The automation sets `wacrm.origin='admin'` and `wacrm.actor='automation:cerebro_cambiar_servicio'` for the call only (restored on
    every path) because the 096 lock guard lets only a human or an asserted admin write the lock map. The rail lock it leaves is
    stamped `automation:`: the bot may change its own earlier change, and a LATE stale bot write of the old rail (the receipt turn of
    the incident) is suppressed and audited as `automation_write_suppressed`, exactly like after a panel change.
  - Audit: one `remittance_admin_audit` row, action `automation_service_change` (added to `remittance_admin_audit_action_chk`; the
    ROLLBACK restores the list and REFUSES while such rows exist), field `service`, actor `automation:cerebro_cambiar_servicio`, reason
    `n8n execution <id>`, before/after as the panel's. One `tool_execution_log` line per call (tool `cambiar_servicio`, key
    `<execution>:cambiar_servicio:md5(service)`, outcome changed | unchanged | <reason>).
- What the panel path does today with status/notices (mirrored): `crm_cambiar_servicio` changes NO status, so `notify_operation_status_change`
  never fires and `customer_notice_muted_for` is not involved; recipients retired do not move the status (no trigger on
  `remittance_beneficiaries` does). The bot function does the same: no message, outbox row, notification or http call (asserted).
  Side note: the ambiguity hand-over (`cerebro_registrar_derivacion`) assigns the conversation and fires the existing assignment
  notification to the agent (an internal notification, not to the customer); on staging its FK warns because the hard-coded agent id
  has no staging profile (pre-existing, same as `cerebro_marcar_destino_usd`).

## Tasks
- [x] A1 Feature document (this file)
- [x] A2 RED: assertion `bot-change-service.sql` first, observed failing on staging (function missing)
- [x] A3 Migration 230 + ROLLBACK-230; staging drift check; GREEN
- [x] A4 Rollback proof (rolled-back transaction), related assertions, fingerprint, staging left WITH 230
- [x] A5 Commit `8847848`
- [x] B1 Release path and staging bot evidence (below)
- [x] B2 Precise n8n edit plan (below)
- [x] B3 Staging test plan (below)
- [x] B4 Risks and owner go-aheads (below)
- [ ] C1 (owner go-ahead) n8n edits on the STAGING bot + evals + live staging test
- [ ] C2 (owner go-ahead) Production: migration 230 on `hqztotshnlzaiziwjyzh`, then the production bot workflow + notifier

## Evidence (Part A, staging `kolppplawzdsjfydwejr`, 2026-10-08)
- Drift check BEFORE building (md5 of `pg_get_functiondef`, staging vs the repo's latest definition): `crm_cambiar_servicio` ee82240e976cd036b8b23b085c8d8ca9
  (= 223), `crm_calcular_monto_destino` 2fd07252c7a6b229cc95b84965c3e944 (= 224), `cerebro_riel_op` dfd418a0b5a55db09836919a9f52ef97 (= 223),
  `cerebro_minimo_gyd` f709f161101cf1ab6b006b3d8eb44754 (= 223), `cerebro_marcar_destino_usd` f239d898e9533b82a9822f4eb98ee6e7 (= 221).
  No drift. Constraint `remittance_admin_audit_action_chk` equals 228's list.
- RED: first run of `bot-change-service.sql` stopped at case a: `function cerebro_cambiar_servicio(uuid, unknown, unknown) does not exist`.
- Migration 230 applied on staging (`BEGIN; <230>; COMMIT;`, psql, docker postgres:17).
- GREEN: `bot-change-service.sql` ALL PASS, cases a to m inside `BEGIN; ...; ROLLBACK;`:
  a efectivo_usd -> zelle after verification (47,100 GYD: 162 -> 181 USD at 260, status stays ready_to_transfer, cash recipient retired,
  audit row, tool log, rail locked by automation, nothing in messages/message_outbox/notifications/net queue);
  b same service = no-op (also upper case and a replayed execution; no new audit) and a late `marcar_destino_usd efectivo` is suppressed;
  c cup / efectivo aliases and a chain zelle -> cup -> efectivo -> clasica (4 audit rows); d zelle -> cuban_card retires the zelle recipient;
  e panel-vs-bot parity over 10 consecutive services (identical state, same retired count, 10 audits each) and the panel RPC keeps its shape;
  f servicio_desconocido (unknown, blank, null, injection text); g bloqueado_por_humano (delivery_method, service_type, quote locks and a
  panel-made change); h estado_no_permite for transferring / incident / completed / cancelled and the five open statuses allowed;
  i por_debajo_del_minimo (5,200 -> Zelle 13,000; 20,000 -> cash 29,000; exact minimum accepted); j varios_destinatarios; k sin_operacion,
  operacion_ambigua (hand-over, nothing changed), tipo_no_soportado; l panel refusals kept (22023 closed / unknown, 42501 non-member);
  m privileges (service_role yes; anon, authenticated, PUBLIC no; core callable by nobody; really called as each role; no context leaks).
- Rollback proof (one rolled-back transaction): after ROLLBACK-230 `crm_cambiar_servicio` md5 = ee82240e976cd036b8b23b085c8d8ca9 (pre-230),
  `cerebro_cambiar_servicio` and `_cambiar_servicio_core` gone, constraint definition text+newline md5 = a3453bb94deeb54ef1037f81e9ccfe73
  (pre-230), panel grants unchanged (authenticated yes, anon no). After the forced ROLLBACK staging again had 230.
- Related assertions after 230 (same wrapper): `change-operation-service` ALL PASS, `quote-from-rail` ALL PASS, `cash-recipient-add` ALL PASS,
  `saldo-model` ALL PASS. (`feed-mixed` and `delivery-feed-evidence` were failing before this work; not chased.)
- Leftovers: 0 contacts `5990230%`, 0 `automation_service_change` audit rows, 0 `cambiar_servicio` tool log rows, 8 operations (unchanged).

### Fingerprint (staging, with 230)
```sql
select p.proname, md5(pg_get_functiondef(p.oid)) md5, p.proacl::text acl
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
 where p.proname in ('_cambiar_servicio_core', 'cerebro_cambiar_servicio', 'crm_cambiar_servicio') order by 1;
select md5(pg_get_constraintdef(oid)) from pg_constraint where conname = 'remittance_admin_audit_action_chk';
```
| object | md5 | ACL |
|---|---|---|
| `_cambiar_servicio_core` | e217a37a479aeab46bcd77e38976dc9a | `{postgres=X/postgres}` |
| `cerebro_cambiar_servicio` | f47c288efed9aa967a90c5487b08c166 | `{postgres=X/postgres,service_role=X/postgres}` |
| `crm_cambiar_servicio` | cf530867ad701ec56d8cc0e935065fac | `{postgres=X/postgres,service_role=X/postgres,authenticated=X/postgres}` |
| `remittance_admin_audit_action_chk` (definition text, no newline) | c275d9816026ff7d37a29d9ed08c7c00 | |

Pre-230 (ROLLBACK targets): `crm_cambiar_servicio` ee82240e976cd036b8b23b085c8d8ca9; constraint (text + newline) a3453bb94deeb54ef1037f81e9ccfe73
(= e81119f6f5497bf9f7838d97ce1f456e without the newline).

---

# PART B — n8n change PLAN (read-only; nothing in n8n was edited, activated or executed)

## B1. How bot changes are developed and released today (evidence)
- Tooling lives in `~/cerebro-fase1/pruebas/`. `gate76-experimento.py` holds the n8n helper `api()` (public REST API at
  `https://automatizaciones-n8n.ttjgax.easypanel.host`, key file `~/.n8n-api-key`; per `~/cerebro-fase1/ARRANQUE.md` the n8n MCP does not work for
  these workflows and the key expires 2026-11-11). Release scripts are numbered "gates": the latest bot ones are `gate115-zelle-tiers.py`
  (5 Oct, bot only), `gate112` (notifier + bot), `gate81-staging-merge.py` (staging aligned with production). Pattern of a gate, read from
  `gate115-zelle-tiers.py`: `python3 gateNNN.py staging|produccion [--seco]` -> GET the workflow -> save the full pre-change JSON as
  `cerebro-<env>-antes-NNN-<timestamp>.json` (the rollback) -> `rep(text, old, new)` asserts each marker occurs exactly once -> edit only the named nodes
  (`Agente Remesas` system message, tool `query` / `toolDescription` / `queryReplacement`, `Decisor` jsCode, `Ultima cotizacion` / `Contexto conversacion`
  SQL) -> `PUT /api/v1/workflows/{id}` with only `name, nodes, connections, settings` (settings filtered to the allowed keys) -> read-back prints
  `active` and `versionId == activeVersionId` plus a check that each edit is present. `--seco` writes `seco-NNN-<id>.json` and PUTs nothing (dry run).
  Older changes keep `candidato-cerebro-{staging,PRODUCCION}-<tema>.json` + `ROLLBACK-cerebro-{staging,PRODUCCION}-antes-<tema>.json` and a pre-flight
  that asserts node count, `disabled` flags and `connections` byte-identical except the intended nodes (`odd/tasks/cash-usd-service-info.md` C3/C4).
- Test layers used before production (`odd/tasks/cash-usd-service-info.md`, `zelle-tiered-rate.md`, `cerebro-context-prompt.md`):
  1. SQL assertions on staging (done above for this feature).
  2. Evals harness `~/cerebro-fase1/pruebas/evals/evaluar.py` (cases in `evals/casos/*.json`, single- and multi-turn): builds a TEMPORARY n8n workflow
     (webhook -> agent) from the target workflow's own prompt and tools, with write tools neutralised or answered by recorded `_resultados_grabados`,
     deletes it in `finally`; `--workflow <id>` selects staging or production as the prompt source. Reports in `evals/informes/`.
  3. Decisor harness: node scripts `banco-*.js`, `candidato-decisor-*.js`, `casos-decisor-*.json` (the Decisor code runs offline against cases).
  4. A live WhatsApp test on staging with the owner's test number 529622896918, reset first (`supabase/staging/reset-test-contact.sql`)
     (`odd/tasks/align-staging-with-production.md` T5).
- STAGING copies exist and are active (n8n list, read-only GET, 2026-10-08):
  - Bot: `U52y1kSNvhgxvWeb` "[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1", 123 nodes (production `jEzlVLCLUaJhVwzs` has 122; staging has the extra node
    "DeepSeek Web Search Chat Model"). Webhook path `staging-wacrm-cerebro-green-v1` (production `wacrm-cerebro-green-v1`); Postgres credential
    "Supabase STAGING" (id np3egGrAcrWkOWd4; production "Supabase Account" S2CallLPSjzbVXN4); replies through `https://crm.onlinefreedom.site/api/v1/messages`
    (production `https://wacrm.onlinefreedom.site/api/v1/messages`); error workflow `1Elx6fZ3z5vQI3dj` (production `g3UgayrNlXBXZgnr`).
  - Notifier: staging `OCdJoHTkV6S0aAdk` "[STAGING] WaCRM - Notificar cliente por etapa del deal" (webhook `staging-wacrm-notify-etapa`, credential
    Supabase STAGING); production `wGud0KGR6eMqqfMQ`.
  - Staging also has its own outbox sender `WmcobAufVNWURbKc`, repartos `Yu0uskQhydWgNFEy`, ingestion and error handler workflows.
  - DRIFT TO CLOSE FIRST: 10 nodes' parameters differ between staging and production (`Webhook WaCRM`, `Validar evento`, `Contexto conversacion`,
    `Agente Remesas`, `Responder por WaCRM`, `Avisar espera al cliente`, `Confirmar al admin`, `consultar_servicio`, `DeepSeek sin pensamiento (comunidad)`,
    `Despertar al enviador`; most are URL/credential/path differences, but `Agente Remesas` and `Contexto conversacion` must be diffed text-wise).
    Re-align staging the way `gate81-staging-merge.py` did (production nodes, staging URLs/credentials) before editing, or the staging test proves nothing.
- Who activates: nobody toggles activation. Both workflows are `active=true`; the PUT updates the active version in place (the gate prints
  `versionId == activeVersionId`). Rollback = PUT the saved `cerebro-<env>-antes-NNN-<ts>.json` back (and run ROLLBACK-230 only after the tool is removed).
  Production edits so far were done by the assistant after the owner's explicit go-ahead; the DB migration goes first (MCP or `gate123-aplicar-db.py`
  style with a forced-rollback rehearsal, fingerprint and `probar` assertions).

## B2. The exact edits (new gate, e.g. `gate131-cambiar-servicio.py staging|produccion [--seco]`)
Every edit uses `rep()` with an exact marker and an assertion on counts; nodes not named below stay byte-identical (assert node count: staging 123 -> 124,
production 122 -> 123, only the nodes named here differ, `connections` differ only by the new tool).

### a. New agent tool (do not widen `marcar_destino_usd`: it is also the first-mark path and its idempotency/hand-over semantics stay)
New node `cambiar_servicio`, type `n8n-nodes-base.postgresTool` typeVersion 2.6 (clone of `marcar_destino_usd`: id `0806177d-...`, credentials of the target
environment), new id, position next to it (~[4880, 1000]):
```
query: SELECT cerebro_cambiar_servicio($1::uuid, $2::text, $3::text) AS resultado;
options.queryReplacement: ={{ [$('Decisor').item.json.conversation_id, $fromAI('servicio', 'a que via cambia el cliente: zelle, clasica, tropical, cup (tarjeta en pesos) o efectivo (dolares en mano en Cuba)', 'string'), $execution.id] }}
descriptionType: manual
toolDescription: Cambia la via por la que el cliente recibe su envio EN LA OPERACION YA ABIERTA (zelle, clasica, tropical, cup, efectivo). Llamala en cuanto el
  cliente diga que prefiere recibirlo de otra forma, aunque ya haya mandado el comprobante o este verificado. Devuelve el monto NUEVO: dilo tal cual, no lo
  recalcules. Si ok es false mira 'reason'. Para elegir la via por primera vez sigue usando marcar_destino_usd.
```
Connection: `"cambiar_servicio": {"ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}`.
Leave `marcar_destino_usd` untouched, but replace the tail of its `notes` ("NO se usa para Zelle: para eso esta registrar_beneficiario_zelle.") with
"NO se usa para Zelle ni para cambiar de via: para eso esta cambiar_servicio." Its toolDescription "No es para Zelle." stays true.

### b. `Agente Remesas` system message (Spanish, same register as the node)
1. Tool list, after the `marcar_destino_usd(tipo)` bullet (marker: `NO se usa para Zelle.\n   - registrar_beneficiario_zelle(nombre,cuenta)`):
   `- cambiar_servicio(servicio): cambia la via de recepcion de la operacion YA abierta (zelle, clasica, tropical, cup, efectivo). Devuelve ok, el monto nuevo (destination_amount, destination_currency), el previo y 'reason' si no pudo.`
2. New block just before `## VIA USD`:
```
## CAMBIO DE VIA (el cliente cambia de idea)
Si con una operacion abierta el cliente dice que prefiere recibirlo por otra via ("mejor zelle", "mejor en efectivo", "pasalo a la tarjeta"), antes
o despues de mandar el comprobante, antes o despues de verificado: llama cambiar_servicio(servicio) en ESE turno y SOLO DESPUES responde. NO uses
calcular_usd ni calcular_usd_desde_gyd para esto y NO digas un monto de memoria: el monto es destination_amount del resultado.
- ok=true y changed=true: "Listo, queda por {via}. Con sus *{source_amount_gyd} GYD* recibe *{destination_amount} {destination_currency}* por {via}." y, si la via
  nueva necesita datos (Zelle: nombre y cuenta; efectivo: telefono y direccion; tarjeta: tarjeta y celular), pide SOLO lo que el [CONTEXTO] diga que falta.
  Si el monto cambio, di en una frase de cuanto era antes (previous). Los datos del destinatario anterior ya no sirven: no los repitas.
- ok=true y changed=false: ya estaba asi; sigue con lo que falte, no repitas el monto como si fuera nuevo.
- reason por_debajo_del_minimo: no se cambio nada. "Por {via} el minimo es *{minimo_gyd} GYD* y su deposito es de *{source_amount_gyd} GYD*." y ofrece
  mantener la via actual o completar la diferencia.
- reason estado_no_permite, bloqueado_por_humano, varios_destinatarios o tipo_no_soportado: no se cambio nada. "Un companero le ayuda con ese cambio
  enseguida." y llama derivar_humano con el motivo (cambio de via, via pedida, monto depositado).
- reason operacion_ambigua: el sistema ya lo paso a una persona; dile que un companero le atiende enseguida. No confirmes ningun dato.
- reason sin_operacion: todavia no hay envio abierto; sigue como cotizacion normal (VIA USD) y marca la via con marcar_destino_usd cuando la elija.
- reason servicio_desconocido: pregunta a cual via lo quiere (Zelle, Clasica, Tropical, CUP o efectivo).
```
3. Adjust the "NO se usa para Zelle" statement in the SI ES EFECTIVO / VIA USD bullets: replace `llama marcar_destino_usd con 'efectivo' en cuanto el cliente la elija.`
   by the same text plus ` Si ya hay una via marcada y el cliente cambia, es cambiar_servicio.` Add one example turn in the examples section:
   `C: [comprobante verificado, via efectivo] ; C: Mejor zelle -> (llamar cambiar_servicio('zelle')) 'Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* por Zelle (antes eran 162 USD en efectivo). ¿A nombre de quien esta la cuenta Zelle y cual es el correo o celular?'`

### c. `Decisor` (jsCode) and `Contexto conversacion` (SQL)
- Contexto: new columns next to `entrega_efectivo_en_curso` (marker `AS entrega_efectivo_en_curso,`):
  `(SELECT cerebro_riel_op(o9.id) FROM remittance_operations o9 WHERE o9.conversation_id = v.id AND o9.status NOT IN ('completed','cancelled') ORDER BY o9.created_at DESC LIMIT 1) AS riel_operacion,`
  and `(SELECT o9.status ...) AS estado_operacion`.
- Decisor, current code (offset ~79,660): `const viaSinDefinir = !sabeDestino && !tarjetaCtx && !celularCtx && !s.datos_zelle && !recargaEnCurso && !comboEnCurso && !visaEnCurso;`
  proposed: `... && !visaEnCurso && !ctx.entrega_efectivo_en_curso && !ctx.riel_operacion;` (a rail already on the operation is a rail defined; this also
  stops "TODAVIA NO SE SABE POR QUE VIA RECIBE" notes in a cash operation).
- New detection after `sabeDestino` (offset ~67,643), using the regexes the Decisor already uses for `calcular_usd` (`/zelle/i`, `/cl[aá]sica/i`, `/tropical/i`,
  `/efectivo|cash|en mano|f[ií]sico/i`, plus `/\bcup\b|pesos|tarjeta cup/i`):
  `const viaPedida = ...; const cambioDeVia = !!(ctx.riel_operacion && viaPedida && viaPedida !== normalizar(ctx.riel_operacion) && /mejor|prefiero|cambi|en vez|ya no|pasalo|por .*mejor/i.test(texto));`
  then `if (cambioDeVia) notas.push('EL CLIENTE PIDE CAMBIAR LA VIA de ' + ctx.riel_operacion + ' a ' + viaPedida + ': llama cambiar_servicio("' + viaPedida + '") y responde con el monto del resultado. PROHIBIDO calcular_usd para esto.');`
  A bare mention of another rail in a question ("¿y por zelle cuanto seria?") is a quote, not a change: the verb regex keeps it out.

### d. The race (receipt turn marks the rail from chat memory)
Evidence (execution 364120, read-only GET): `Esperar ventana` 12 s, `Reclamar lote` 12:21:46 claimed ONLY the image event (id 9282, text empty); vision
took until 12:22:05; `marcar_destino_usd` ran 12:22:13 with "Efectivo" from the memory of the previous turn; "Mejor zelle" was a later `session_events` row
(`pending`), so a separate batch/turn.
With the new tool the late text turn now repairs the rail (that is the main fix). Smallest hardening against marking a rail on stale information:
a DB guard, no workflow edit, in `cerebro_marcar_destino_usd` (and `cerebro_registrar_destino`): when `session_events` has rows for the conversation with
`processing_status IN ('pending','retry_wait')` (the customer wrote something not yet claimed, same predicate `cerebro_reclamar_lote` uses) return
`ERROR: el cliente acaba de escribir otro mensaje; no marques la via ahora, se atiende en el siguiente turno` and do nothing. Needs its own migration + staging
assertion; not part of 230 (owner decision, see B4). Alternative without SQL: a Decisor note when the `Verificar si soy el ultimo` style count of newer events
is > 0 ("PROHIBIDO marcar via en este turno"). The automation lock left by 230 also suppresses a stale write of the OLD rail if the text turn happens to run first.

### e. Notifier (`wGud0KGR6eMqqfMQ`, node `Filtrar cambio de etapa` + `Leer secreto`)
- Current: `verificacion_manual` is true when `remittance_admin_audit` has `human_deposit_verification`, `human_forced_verification` or
  `automation_late_deposit_verification` for the operation in the last 15 minutes; then the text is built from `cerebro_riel_op` (`riel`): with no
  recipients and `riel==='efectivo_usd'` it says "los datos de quien recibe el efectivo en Cuba". `automation_late_deposit_verification` is legitimately in
  that list (a late MMG email verifies with no bot turn), so do NOT remove it.
- The service change itself changes no status, so the notifier does not fire on it; it reads the rail at the moment of a status transition. Only needed edit:
  hold the notice while the bot is about to answer: add to `Leer secreto`'s SELECT
  `(SELECT count(*) FROM session_events e JOIN remittance_operations o ON o.conversation_id = e.conversation_id WHERE o.id::text = $1 AND e.processing_status IN ('pending','retry_wait','processing')) AS mensajes_en_curso`
  and in the code `if (Number(cfg.mensajes_en_curso) > 0) return [];` before building the text (the bot's own reply covers it). Optional; no change is required for 230.

## B3. Staging test plan
Setup for every scenario: reset the contact (memory note: wipe 529622896918 before EVERY staging test):
`set -a; source .env.staging; set +a; docker run --rm -i postgres:17 psql "$CRM_STAGING_DATABASE_URL" -v ON_ERROR_STOP=1 -v phone=529622896918 < supabase/staging/reset-test-contact.sql`.
Pre-flight: staging bot aligned with production (B1 drift), migration 230 on staging (done), staging `cerebro_config.notify_url` pointing at the staging notifier,
rates efectivo 290, usd/zelle 260 (tiers per `cerebro_zelle_tiers`), minimos zelle 13,000 / efectivo 29,000. The live scenarios need the owner's phone (the
staging WhatsApp line); they send real WhatsApp messages and are NOT run by an agent without authorization. Offline layer first: add
`evals/casos/casos-cambio-de-servicio.json` (multi-turn, `_resultados_grabados` for `cambiar_servicio` taken from the DB results below) and run
`evaluar.py --workflow U52y1kSNvhgxvWeb`: expect the tool call with the right `servicio`, no `calcular_usd*`, the amount quoted from the result, 0 DSML.
| # | Script (customer) | Expected DB state | Expected bot reply |
|---|---|---|---|
| 1 Carlos | "quiero mandar 162 USD en efectivo / 47,100" -> "USD en Bayamo" (cash recipient data) -> receipt of 47,100 GYD -> within 5 s "Mejor zelle" | after the receipt turn: `efectivo_usd`, 162 USD; after the text turn: `zelle`, 181 USD @260, status `ready_to_transfer`, cash recipient `reemplazado`, audit `automation_service_change` (execution id in reason), rail lock `by automation:`; no stale revert (a `automation_write_suppressed` row is acceptable if the turns interleave) | "Listo, queda por Zelle. Con sus 47,100 GYD recibe 181 USD (antes 162 USD en efectivo)" + asks Zelle name and account; no "faltan datos del efectivo" message from the notifier |
| 2 CUP -> Zelle before the receipt | "30 mil CUP" (card+phone given) -> "mejor por zelle" -> receipt of the quoted GYD | `cuban_card` -> `zelle`, card retired, USD quote by Zelle tier, status `collecting_information`; the receipt then verifies against the Zelle objective (watch the stale `cerebro_objetivo_envio`: see B4) | new USD amount from the tool; asks name+account |
| 3 Zelle -> CUP after verification | Zelle with verified 47,100 -> "mejor a la tarjeta cup" | `cuban_card`, CUP `round(47100*3)`=141,300, Zelle recipient retired, status unchanged | new CUP amount; asks card and phone |
| 4 Below minimum | deposit 20,000 GYD on clasica -> "mejor efectivo" | nothing changed, no audit row (tool log `por_debajo_del_minimo`) | states the cash minimum 29,000 GYD and offers to keep clasica or complete |
| 5 Admin-locked | operator changes the service in the panel (`crm_cambiar_servicio`) -> customer says "mejor X" | nothing changed (`bloqueado_por_humano`) | hand-over wording + `derivar_humano` |
| 6 Refused states | operation in `transferring` / `incident` -> "mejor zelle" | nothing changed (`estado_no_permite`) | hand-over wording |
| 7 Same service | "si, por zelle" while already zelle | `changed:false`, no audit | no fake "new amount" |
| 8 Mere question | "¿y por zelle cuanto seria?" with a cash operation | NO change | quote only (calcular_usd_desde_gyd via=zelle) |
| 9 No operation | "mejor zelle" with no open operation | `sin_operacion` | continues as a quote, no change |
After each: query `remittance_operations`, `remittance_beneficiaries`, `remittance_admin_audit` (action `automation_service_change`), `tool_execution_log` (`cambiar_servicio`), `messages`
(exactly one bot reply per customer turn), the execution in staging n8n (tool called once, no DSML, no execution error), and confirm nothing was sent to a
number other than 529622896918. Rollback: PUT `cerebro-staging-antes-131-<ts>.json`.

## B4. Risks and what needs the owner's explicit go-ahead
Go-aheads needed (none given yet):
1. Editing the STAGING bot and notifier workflows and running evals / live WhatsApp tests with 529622896918.
2. Applying migration 230 to PRODUCTION (`hqztotshnlzaiziwjyzh`): DB first (rehearsal with forced rollback, fingerprint, assertions), then:
3. Editing the PRODUCTION bot workflow `jEzlVLCLUaJhVwzs` (and the notifier if the optional edit is accepted). This is the risky step; backup JSON + read-back + watch of the first real conversations.
4. The race hardening migration (B2d) and its behaviour change in `cerebro_marcar_destino_usd`.
Risks:
- The model may call `cambiar_servicio` on a question ("¿y por zelle?"): mitigated by the tool description, the Decisor verb check and eval case 8. A wrong call changes a real operation (it is audited and reversible with the same tool).
- After the switch the operation (e.g. `ready_to_transfer`) has NO recipient for the new rail; today nothing moves the status back (same as the panel). The operator board may show a ready operation with missing recipient data. Decision gap: should the status go back to `deposit_verification`/`collecting_information` when recipients are retired after verification?
- A stale open `cerebro_objetivo_envio` (its `monto` is `greatest(minimum, quote, previous)`) may keep the OLD rail's minimum for a switch BEFORE the receipt (e.g. cash 29,000 -> Zelle 13,000: a 20,000 GYD deposit could still be treated as short). Not exercised in the assertion; scenario 2 must prove it on staging; fix would be to close/refresh the objective inside the core.
- The rail lock the bot leaves suppresses later writes of `cerebro_marcar_destino_usd` / `cerebro_registrar_destino` for that operation (intended, audited as `automation_write_suppressed`); the model must therefore use `cambiar_servicio` for every later change.
- `por_debajo_del_minimo` uses the minimum of the new rail on the quoted source amount; a deposit split over several receipts that is still partial may be refused until complete.
- Staging bot drifts from production in 10 nodes: testing on a stale staging prompt proves little. Align first.
- n8n API key expires 2026-11-11 (ARRANQUE.md).
- Ambiguity hand-over notifications fail on staging (FK on the hard-coded agent profile): pre-existing.

## Open points / decision gaps for the owner
1. Status after a post-verification switch with no recipient for the new rail (see risks).
2. Apply the race guard (B2d) now or rely on the new tool + lock?
3. Notice hold in the Notifier (B2e) yes/no.
4. Whether `incident` should be refused (current: refused, hand-over) or allowed.
5. Whether a switch to `recarga`/`combo`/`visa`/`saldo` should be reachable by the bot at all (the function accepts them like the panel; the proposed tool description lists only the five rails).
