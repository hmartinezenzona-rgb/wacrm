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
- [x] A6 Migration 231 (deterministic Zelle, v2, creation trigger, tool guard) + ROLLBACK-231 + assertion: staging GREEN (Part C)
- [ ] C1 (owner go-ahead) n8n edits on the STAGING bot (revised B2) + evals + live staging test
- [ ] C2 (owner go-ahead) Production: migrations 230 and 231 on `hqztotshnlzaiziwjyzh`, then the production bot workflow + notifier

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

# PART C — migration 231 (deterministic Zelle), evidence and design choices
Detector rules, v2 result shape and flow are in the header of `supabase/migrations/231_deterministic_destination_zelle.sql`. Choices: (item 2) v2 `cerebro_registrar_destino_v2(conv, text, execution, only_cards)` RETURNS jsonb + v1 kept as a wrapper returning the tipo text (least risky: the node reads nothing today, so v1 works unchanged and v2 is adopted later); (item 3) the beneficiary trigger is UNCHANGED and ignores a pending zelle (it only reads clasica/tropical), the card stays a card, the pending row is not cleared; (item 4) the tool refuses a rail different from a `cliente` pending row of the last 5 minutes (column `origen` added so rows written by the tool itself never block it); (item 5) card->card and any later change go through the engine when the rail lock is stamped `automation:`; a new AFTER INSERT trigger makes a new remesa zelle when zelle is pending (zelle stated first). Questions: only Zelle is question-filtered in the detector (157 results unchanged); card rails over a Zelle/cash operation also skip questions in the registrar. Cash is not detected (deposit/delivery ambiguity).
Detector examples: Mejor zelle -> zelle; Quiero zelle -> zelle; No quiero efectivo en cuba -> NULL; no quiero zelle, mejor tropical -> tropical; no zelle -> NULL; zelle o clasica? -> NULL; ¿tienen zelle? -> NULL; cuanto seria por zelle -> NULL; juan.zelle@x.com -> NULL; son pesos cubanos, no dolares -> cuban_card (unchanged).
Evidence (staging): drift check before building: detectar 174 / registrar 157 / marcar 221 / trigger 221 = staging (no drift). RED: assertion before 231 stopped at `case A: cerebro_detectar_destino('Mejor zelle') = NULL, expected zelle`. 231 applied (`BEGIN; <231>; COMMIT;`). GREEN: `deterministic-destination-zelle` ALL PASS (A-K). Related, same wrapper: deterministic-usd-destination, clasica-card-from-delivery-method, bot-change-service, change-operation-service, quote-from-rail, cash-recipient-add, reparto-usd-card-rail all pass. Rollback proof (rolled-back transaction): after ROLLBACK-231 detectar 31f6d02d599b491c586284251b0502f9, registrar c87c36beafde0cd256a601ee7290d045, marcar f239d898e9533b82a9822f4eb98ee6e7 (pre-231), new objects gone, check restored. Leftovers: 0 fixture contacts, 0 audit rows, 0 pending zelle.
Fingerprint (staging, with 231):
```sql
select p.proname, md5(pg_get_functiondef(p.oid)), p.proacl::text from pg_proc p where pronamespace='public'::regnamespace and proname in ('cerebro_detectar_destino','cerebro_registrar_destino','cerebro_registrar_destino_v2','cerebro_marcar_destino_usd','cerebro_destino_es_pregunta','cerebro_destino_riel_negado','cerebro_destino_pendiente_op_creada') order by 1;
select md5(pg_get_constraintdef(oid)) from pg_constraint where conname='cerebro_destino_pendiente_tipo_check';
```
| function | md5 | ACL |
|---|---|---|
| cerebro_destino_es_pregunta | cd47e7538427f1224128be11b38e3ab1 | postgres, service_role |
| cerebro_destino_pendiente_op_creada | 4ff0e4181300edebf1a25853ccab57b1 | postgres, service_role |
| cerebro_destino_riel_negado | 94a28fb5c086cfb426e0b0f18d3c9e4f | postgres, service_role |
| cerebro_detectar_destino | a973fb1c2ae007f55c3c6088df1d597b | postgres, service_role |
| cerebro_marcar_destino_usd | 11697cfbfed2e3c76e303029a72f44de | postgres, service_role |
| cerebro_registrar_destino | e7fddff9d21d2315ce6dc32895147ee4 | postgres, service_role |
| cerebro_registrar_destino_v2 | 868bc2c5b0c1ac298fcd905be11fc20c | postgres, service_role |
Decision gaps: (1) a customer sentence that merely mentions Zelle as a statement ('mi hermano usa zelle') changes the service (audited, reversible by the customer's next sentence); accept? (2) status after a post-verification switch with no recipient (see B4); (3) the stale `cerebro_objetivo_envio` minimum (B4). 

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

## B2. The exact edits, REVISED (owner decision 2026-10-08: no new LLM tool; extend 157's deterministic mechanism)
Superseded: the `cambiar_servicio` agent tool, its prompt block and the Decisor `cambioDeVia` regexes of the first plan. The customer's words now
change the rail in the DB (migration 231); the bot only has to REPORT the result. New gate, e.g. `gate131-registrar-destino-v2.py staging|produccion [--seco]`,
same `rep()` / backup / read-back pattern as B1.
What the current node reads (verified read-only, production `jEzlVLCLUaJhVwzs` and staging `U52y1kSNvhgxvWeb`): "Registrar destino auto" (postgres 2.6,
`SELECT cerebro_registrar_destino($1::uuid, $2::text) AS destino`, args `Snapshot final` conversation_id + texto_completo) is a side branch of
`Snapshot final` with NO outgoing connection and no node references its output. So v1 (kept, now a wrapper) is risk-free, and the Zelle fix works as soon as 231
is on the database, before any n8n edit. It runs in PARALLEL with `Comprobante nuevo?` and the beneficiary chain, so its result cannot reach the agent today.
1. Move/replace the node so its result feeds the agent: put a new node `Registrar destino v2` (postgres) in the serial chain
   `Snapshot final -> Comprobante nuevo? -> Merge beneficiario -> Beneficiario completo? -> Registrar beneficiario auto -> Contexto conversacion`
   (before `Contexto conversacion`, e.g. right after `Snapshot final` on the main path), query
   `SELECT cerebro_registrar_destino_v2($1::uuid, $2::text, $3::text) AS destino;` with `[conversation_id, texto_completo ?? '', $execution.id]`,
   `alwaysOutputData: true`, `onError: continueRegularOutput` (a failure must not stop the turn). Delete the old parallel node (or leave it disabled).
   It must run BEFORE the receipt/beneficiary writers of the same turn so the rail is right when the operation is created or the card inserted.
2. `Contexto conversacion` (SQL) / `Decisor` (jsCode): read `$('Registrar destino v2').first().json.destino` and, when `changed === true`, push into the
   agent notes (exact text, Spanish, same register as the Decisor notes):
   `EL CLIENTE CAMBIO LA VIA: ahora es {servicio_legible} (antes {previous.servicio_legible}). Con sus {source_amount_gyd} GYD recibe {destination_amount} {destination_currency}` +
   ` (antes {previous.destination_amount} {previous.destination_currency}). YA ESTA CAMBIADO en el sistema: dilo tal cual, NO recalcules, NO llames marcar_destino_usd ni calcular_usd para esto.`
   + (Zelle: ` Pide SOLO el nombre y el correo o celular de la cuenta Zelle.`) + (efectivo: telefono y direccion) + (tarjeta: tarjeta y celular). Data of the old recipient no longer applies.
   When `ok === false` and `reason` is set, push: `NO SE CAMBIO LA VIA: ` + by reason: `por_debajo_del_minimo` -> `Por {servicio} el minimo es {minimo_gyd} GYD y su deposito es de {source_amount_gyd} GYD; ofrece mantener la via actual o completar la diferencia.`;
   `estado_no_permite | bloqueado_por_humano | operacion_ambigua | varios_destinatarios | tipo_no_soportado` -> `Un companero le ayuda con ese cambio enseguida.` + llamar derivar_humano con el motivo;
   `es_pregunta | sin_destino | sin_operacion` -> no note (nothing to report; `sin_operacion` means it will apply when the operation is created).
   `changed === false && ok === true` -> no note (already on that rail). Also make `viaSinDefinir` false when the operation already has a rail
   (`Contexto` column `cerebro_riel_op(op)` as in the first plan) so the "TODAVIA NO SE SABE POR QUE VIA RECIBE" note does not appear after a change.
3. `Agente Remesas` system message: (a) the `marcar_destino_usd` line keeps "NO se usa para Zelle"; add: "Si el sistema ya cambio la via (nota EL CLIENTE CAMBIO LA VIA), no la marques otra vez: la herramienta
   rechaza una via distinta de la que el cliente acaba de decir"; (b) the VIA USD section: Zelle is now chosen by the customer's words and applied by the system; keep `registrar_beneficiario_zelle` for the data;
   (c) one example turn: `C: Mejor zelle` (note says changed 162 -> 181 USD) -> 'Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* (antes eran 162 USD en efectivo). ¿A nombre de quien esta la cuenta Zelle y cual es el correo o celular?'.
   The cash path stays on the LLM (`marcar_destino_usd('efectivo')`): the word is ambiguous between deposit and delivery.
4. Is the `cambiar_servicio` LLM tool still needed? Recommendation: NOT for the incident class (Zelle / clasica / tropical / CUP are decided by the words). Keep `cerebro_cambiar_servicio` in the DB as the engine
   (and for the panel parity); add the n8n tool only later as a FALLBACK for what the detector deliberately does not read: cash ("mejor en efectivo") and recarga <-> saldo, if the owner wants the bot to do them.
   Not needed for go-live of 231.
5. Notifier (`wGud0KGR6eMqqfMQ` / staging `OCdJoHTkV6S0aAdk`): unchanged; optional hold while messages are pending (first plan B2e) stays optional.
Staging drift to close before testing (10 nodes whose parameters differ from production; list unchanged): `Webhook WaCRM`, `Validar evento`, `Contexto conversacion`, `Agente Remesas`,
`Responder por WaCRM`, `Avisar espera al cliente`, `Confirmar al admin`, `consultar_servicio`, `DeepSeek sin pensamiento (comunidad)`, `Despertar al enviador` (staging also has the extra node
"DeepSeek Web Search Chat Model": 123 vs 122). Aligning IS needed before the live test of items 2-3 because `Contexto conversacion` and `Agente Remesas` are exactly the nodes edited; the URL/credential/path
differences are expected and stay (as `gate81-staging-merge.py` did). `Registrar destino auto` itself is identical in both.

## B3. Staging test plan (nine conversations, updated; contact 529622896918 reset before each; live WhatsApp needs the owner and is NOT run by an agent)
Offline first: evals `evaluar.py --workflow U52y1kSNvhgxvWeb` with the Decisor notes above (cases with `_resultados_grabados` taken from the DB results of the assertion).
| # | Customer script | Expected DB state | Expected bot reply |
|---|---|---|---|
| 1 Carlos | "47100 GYD en efectivo" -> "USD en Bayamo" -> receipt -> "Mejor zelle" (within seconds) | `zelle`, 181 USD @260, `ready_to_transfer`, cash recipient `reemplazado`, audit `automation_service_change`; a late `marcar_destino_usd('efectivo')` is refused | "Listo, queda por Zelle. ... 181 USD (antes 162)" + asks Zelle name/account; no "faltan datos del efectivo" |
| 2 CUP -> Zelle before the receipt | "30 mil CUP" (card+phone) -> "mejor por zelle" -> receipt | `zelle`, card retired, USD quote, then receipt verifies against Zelle's minimum (watch stale `cerebro_objetivo_envio`, B4) | new amount, asks name+account |
| 3 Zelle -> CUP after verification | verified Zelle -> "mejor en CUP" | `cuban_card`, 141,300 CUP, Zelle recipient retired | new CUP amount, asks card+phone |
| 4 Below minimum | 5,200 GYD CUP -> "mejor zelle" | nothing changed, `reason por_debajo_del_minimo` | states the 13,000 GYD minimum, offers to keep CUP |
| 5 Admin-locked | operator changes the rail in the panel -> "mejor zelle" | nothing changed (`bloqueado_por_humano`) | hand-over wording + derivar_humano |
| 6 Refused states | `transferring` -> "mejor zelle" | nothing changed (`estado_no_permite`) | hand-over wording |
| 7 Same service | "si, por zelle" on a Zelle operation | `changed:false`, no audit | no fake "new amount" |
| 8 Mere question | "¿y por zelle cuanto seria?" on a cash operation | NO change, nothing recorded | quote only (calcular_usd_desde_gyd via=zelle) |
| 9 Zelle before the operation | "mejor zelle" with no operation, then the receipt | operation created `zelle` (trigger), audit row, 181 USD | quotes Zelle, asks the data |
Extra: "No quiero efectivo en cuba" changes nothing; zelle -> CUP -> zelle works (no lock block). After each: `remittance_operations`, `remittance_beneficiaries`, `remittance_admin_audit`, `cerebro_destino_pendiente`, `messages` (one bot reply per turn), the n8n execution; rollback = PUT the saved pre-change JSON.

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
