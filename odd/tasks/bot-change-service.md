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
- [x] A6 (SUPERSEDED 2026-10-08, see Part D) Migration 231 keyword version (deterministic Zelle, v2, creation trigger, tool guard): staging GREEN, commit c54713d; owner REJECTED it as fragile
- [x] D1 Replace 231 by the agent-tool design: rolled back on staging (pre-231 md5 verified), new `231_agent_service_change_guards.sql` + `ROLLBACK-231-agent-service-change-guards.sql` + assertion `agent-service-change-guards.sql`
- [x] D2 RED (assertion failed on the pre-231 detector), GREEN, rollback proof, related assertions, fingerprint (Part D)
- [x] D3 n8n plan for the STAGING bot and notifier (Part D, read-only)
- [ ] D4 (owner go-ahead) execute the Part D n8n plan on the STAGING bot `U52y1kSNvhgxvWeb` and run the nine test conversations
- [ ] C1 SUPERSEDED by D4
- [ ] C2 (owner go-ahead) Production: migrations 230 and the NEW 231 on `hqztotshnlzaiziwjyzh` (the keyword 231 was never applied there), then the production bot workflow + notifier

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

# PART C — SUPERSEDED (2026-10-08) — migration 231, keyword version (owner rejected it; kept as history, commit c54713d)
The keyword approach (the customer's words decide Zelle) is REPLACED by Part D. Nothing of it remains on staging or in the repo files except the negation test.

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

## B2. SUPERSEDED twice: first by Part C, now by Part D (the agent DOES get a tool). Kept as history. The exact edits of the keyword plan:
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

---

# PART D — the agent acts with a tool; the database only guards it (owner decision 2026-10-08)

Owner: the keyword approach is fragile ("mi hermano usa zelle" would switch the service). "El agente debe tener capacidad de entender el contexto y de
usar las herramientas ... el entendio que quiere cambiar a zelle, lo que le falta es actuar". Approved design: (1) the agent acts with
`cambiar_servicio` (-> `cerebro_cambiar_servicio`, 230) and decides from context; NO detection of the customer's words decides a Zelle or cash switch;
(2) a safety net that does not guess: if the bot quoted one service and the open operation is on another, the team is alerted, nothing is changed;
(3) the late/stale turn cannot overwrite the change the bot just made.

## D1. What migration 231 contains now (`231_agent_service_change_guards.sql`; rollback `ROLLBACK-231-agent-service-change-guards.sql`)
Staging was first brought back to pre-231 by applying the old ROLLBACK-231 for real (detector 31f6d02d599b491c586284251b0502f9, registrar
c87c36beafde0cd256a601ee7290d045, tool f239d898e9533b82a9822f4eb98ee6e7; v2, question helper, creation trigger gone; 230 kept).
- **Removed from the old 231**: Zelle (and cash) detection, the e-mail and question filters, `cerebro_registrar_destino_v2`,
  `cerebro_destino_es_pregunta`, `cerebro_destino_pendiente_op_creada` + `trg_zz_destino_zelle_al_crear` (keyword-fed). `cerebro_registrar_destino` is untouched (never changes zelle/efectivo from text).
- **Kept from the old 231**: only the negation of the card rails already detected (`cerebro_destino_riel_negado`) + a small `cerebro_destino_riel_afirmado`. The
  misfire was REAL on the pre-231 function (staging, before -> after):
  | input | before | after |
  |---|---|---|
  | no quiero clasica | clasica | NULL |
  | sin tropical | tropical | NULL |
  | no quiero cup | cuban_card | NULL |
  | clasica no | clasica | NULL |
  | no quiero clasica, mejor tropical | NULL | tropical |
  | no es clasica, es tropical | NULL | tropical |
  | tropical, no clasica | NULL | tropical |
  | prefiero tropical no clasica | NULL | tropical |
  | en vez de clasica quiero tropical | NULL | tropical |
  | no quiero tropical, mejor clasica | NULL | clasica |
  | ni clasica ni tropical / no se si clasica o tropical / no quiero clasica o tropical | NULL | NULL |
  | mejor zelle / mi hermano usa zelle / no quiero efectivo en cuba | NULL | NULL |
  | quiero clasica, tropical, en cup, pesos cubanos no dolares, clasica o tropical, hola ... (all 157/174 inputs) | same | same |
  Positive detection is 174's own regex on the raw text; the negation runs on folded text only; the surviving rail must be affirmed (written before the rejected one, or after a comma / mejor / pero / sino / prefiero / entonces / ahora / sea / quiero), else NULL (conservative).
- **b. Pending agent-declared service** (`cerebro_destino_pendiente`: `origen` cliente|agente, `ejecucion`, tipo CHECK = clasica, tropical, cuban_card, zelle, efectivo_usd).
  `cerebro_cambiar_servicio(p_conversation_id uuid, p_servicio text, p_execution_id text DEFAULT NULL) RETURNS jsonb` (same signature, grants, shape; fields only added):
  with NO operation at all in the conversation and one of the five rails (aliases cup, efectivo) it records the pending row (24 h) and returns
  `{"ok":true,"changed":false,"pendiente":true,"servicio":"zelle"}`; tool log outcome `pendiente`. recarga / combo / visa / saldo (and an unknown conversation) return
  `{"ok":false,"reason":"sin_operacion","pendiente":false}` -- DECISION: pending only makes sense for the remesa rails, because the operation that gets created is a remesa.
  A new AFTER INSERT trigger `trg_zz_destino_agente_al_crear` on `remittance_operations` (WHEN remesa, no rail, open) applies an `origen='agente'` pending row of the last 24 h when the
  new remesa is the conversation's single open remesa, through `cerebro_cambiar_servicio` (same core as the panel and the tool: retire/retype recipients, quote, lock, ONE `automation_service_change` audit row,
  reason `n8n execution pendiente:<declaring execution>`), and consumes the row; a refusal keeps it. DECISION trigger vs creation function: the trigger is the least invasive (no
  edit of `cerebro_crear_operacion`, which many paths call). A per-conversation advisory lock taken by the tool and by the trigger closes the "pending written while the operation is being created" race
  (both interleavings are serialized: either the trigger sees the committed row or the tool sees the committed operation). When the operation exists the tool deletes the agent pending row first
  (otherwise `cerebro_riel_op`, which falls back to the pending row, would read it as the operation's rail). A customer-word rewrite of the row's tipo (157) relabels it `cliente`.
- **c. Stale-write guard** of `cerebro_marcar_destino_usd` (221 body; signature, grants, rows unchanged): refuses, writing nothing, with `ERROR: ya elegiste <X> ...` when (1) an `agente` pending row of the last 5 minutes differs
  from what it is asked to mark; or `ERROR: la via vigente de la operacion es <X> (la cambiaste con cambiar_servicio) ...` when (2) the open operation's rail lock is stamped `automation:` and the rail differs; in its
  operation-creating branch it no longer claims a rail the new operation did not get (`ERROR: se creo el envio pero su via ya es <X> ...`). What 230's lock ALREADY covered (probed on staging): a late `marcar_destino_usd('efectivo')`
  after a tool change was suppressed by the 096 lock guard (WARNING + `automation_write_suppressed` audit) but the tool still answered "destino marcado: entrega en USD por Efectivo" (the agent was told the opposite of the truth), and
  the pending case (no operation yet) was not covered at all. 231 adds the honest refusal and the pending case, with nothing written. Calls are now logged with an outcome in `tool_execution_log`: marcado | sin_cambios | rechazado | tipo_invalido | operacion_ambigua.
- **d. Safety net** `cerebro_verificar_coherencia_servicio(p_conversation_id uuid, p_execution_id text) RETURNS jsonb` (service_role only). HONEST FINDING: neither table recorded the quote's via. Checked on staging: `tool_execution_log`
  holds only the write tools (no calculation tool writes to it) and `cerebro_ultima_cotizacion` keeps amount + tool name per currency (overwritten, no via). So 231 adds, additively and without touching 153, `cerebro_registrar_via_cotizada(p_conv, p_herramienta, p_via, p_execution_id, p_origen_gyd DEFAULT NULL)`:
  one `tool_execution_log` line per quote (tool_name = the quote tool, outcome = the normalised via: zelle | clasica | tropical | cuban_card | efectivo_usd | otra_via). The quote tools must call it (D3.5b). Rule: take the LAST quote of the execution; if the conversation has a single open remesa whose rail
  (`cerebro_riel_op`) differs, and the execution has no successful `cambiar_servicio` (changed | unchanged) or `marcar_destino_usd` (marcado | sin_cambios) to the quoted service, and no `agente` pending row for it -> ONE alert and
  `{"coherente":false,"cotizado":"zelle","operacion":"efectivo_usd","alert_id":"<uuid>","operation_id":"<uuid>","nueva":true,"resueltas":0}`; otherwise `{"coherente":true,"motivo":<sin_conversacion|sin_operacion|operacion_ambigua|no_remesa|sin_ejecucion|sin_riel|sin_cotizacion|misma_via|via_confirmada|via_declarada>,"resueltas":n}`.
  Quoted-to-compare vs confirmed-the-switch CANNOT be told apart with bot-side evidence (both = a quote for another rail, no change call), so the behaviour is conservative: neutral text, at most one OPEN alert per operation and pair of services (table `cerebro_alertas_coherencia`, unique partial index),
  closed by the next check once the operation's rail is no longer the alerted one (they match, moved to a third rail, no open operation): its notifications are marked read. No priority column exists on `notifications`; the neutral wording is the low priority.
  Alert = one `notifications` row per account member (as migration 134), type `coherencia_servicio` (added to `notifications_type_check` the way 058/059/134/151 added theirs, 13 old types kept), title "Revisar servicio: el bot cotizó Zelle y la operación está en Efectivo en USD",
  body "... Puede haber sido solo una consulta de precio. Revise si el cliente cambió de servicio y, si es así, cámbielo en el panel. El bot no cambió nada y no escribió al cliente por este aviso." CRM: `src/app/(dashboard)/notifications/page.tsx` renders `title` and `body` straight from the row and falls back to the Bell icon for a type
  without an entry in `TYPE_ICON` (9 DB-only types already work that way: chat_atascado ... entrega_efectivo_lista), so NO app change, i18n key or parity-test change is needed. Limits: cash quotes (`consultar_servicio('efectivo_usd')`) are not logged, so zelle -> cash is invisible to the net; a panel change leaves the alert open until the next bot turn;
  a quote tool that does not pass a via records nothing (the check answers coherent, it never guesses a via from an amount); only the LAST quote counts.
- **e. Grants**: `service_role` only on every new/changed bot function (asserted for anon, authenticated, PUBLIC); internal helpers and trigger functions have no grant at all; `cerebro_alertas_coherencia` is closed to API roles (RLS on, no policy, no grant).

## D2. Staging evidence (kolppplawzdsjfydwejr, 2026-10-08)
- ROLLBACK-231 (old) applied for real: pre-231 md5 verified (above), new objects gone, 230 kept.
- RED: `agent-service-change-guards.sql` (wrapped in `BEGIN; ...; ROLLBACK;`) against pre-231: stopped at `case A: cerebro_detectar_destino('zelle o clasica?')` (expectation fixed: that input names clasica, as in 157), then `case A: cerebro_detectar_destino('mejor zelle, no clasica') = clasica, expected NULL`
  (the negation misfire, the only detector change that remains). GREEN after applying the new 231 (`BEGIN; <231>; COMMIT;`): cases A-I, ALL PASS (A 60 detector inputs; B zelle sentences change and record nothing; C the incident driven by tool calls: efectivo marked, deposit verified, `cambiar_servicio('zelle')` -> 181 USD at 260, ready_to_transfer,
  one audit row, no message/outbox/http, late `marcar('efectivo')` refused naming Zelle with nothing written; D pending + creation (both the 5-minute refusal and the production-like path where the tool itself creates the operation as cash outside the window); E pending edge cases (recarga/combo/visa/saldo, 24 h, two operations, own rail, relabel);
  F stale-write guard; G coherence (alert, no duplicate, resolution, excuses, last quote, no-evidence cases); H zelle -> cup -> zelle; I grants/constraints). `bot-change-service.sql` case k1 was updated: zelle with no operation is now `pendiente` (230's other refusals unchanged).
- Rollback proof (one rolled-back transaction): detector 31f6d02d599b491c586284251b0502f9, tool f239d898e9533b82a9822f4eb98ee6e7, `cerebro_cambiar_servicio` f47c288efed9aa967a90c5487b08c166 (= 230), registrar c87c36beafde0cd256a601ee7290d045; new objects/triggers/table/columns gone; both CHECKs back to their text; then forced ROLLBACK: staging WITH 230 + new 231.
- Related assertions after the new 231 (same wrapper), all ALL PASS: deterministic-usd-destination, clasica-card-from-delivery-method, bot-change-service, change-operation-service, quote-from-rail, cash-recipient-add, reparto-usd-card-rail (PASS 1-5), delete-notifications and reparto-tool-usd-rail (their "ALL PASS (rolled back on purpose)" exception), plus reparto-destino-node-adapters (22 parity cases) and ultima-cotizacion. (`feed-mixed`, `delivery-feed-evidence` failed before this work; not chased.)
- Leftovers after all runs: 0 fixture contacts, 0 audit rows, 0 pending rows, 0 alerts, 0 notifications, 0 extra tool-log rows, 8 operations (unchanged).
Fingerprint (staging, with 230 + new 231):
```sql
select p.proname, md5(pg_get_functiondef(p.oid)), p.proacl::text from pg_proc p where pronamespace='public'::regnamespace and proname in ('cerebro_detectar_destino','cerebro_registrar_destino','cerebro_marcar_destino_usd','cerebro_cambiar_servicio','cerebro_destino_riel_negado','cerebro_destino_riel_afirmado','cerebro_servicio_normalizar','cerebro_registrar_via_cotizada','cerebro_verificar_coherencia_servicio','cerebro_coherencia_resolver','cerebro_destino_agente_al_crear','cerebro_destino_pendiente_origen') order by 1;
select tgname from pg_trigger where tgname in ('trg_zz_destino_agente_al_crear','trg_destino_pendiente_origen','trg_zz_destino_zelle_al_crear');
select md5(pg_get_constraintdef(oid)) from pg_constraint where conname in ('cerebro_destino_pendiente_tipo_check') ; select md5(pg_get_constraintdef(oid)) from pg_constraint where conname='notifications_type_check';
```
| function | md5 | ACL |
|---|---|---|
| cerebro_cambiar_servicio | c45bff5f48b88c862f37648d5cbf6593 (was 108249804b3a64690259e1a87bf06236 before gap D4.1, 2026-10-08) | postgres, service_role |
| cerebro_coherencia_resolver | 8ab1541d7269c3c4a79c863a12a74a42 | postgres only |
| cerebro_destino_agente_al_crear | ebf54651b826da9fc3046556d24ec14f | postgres only |
| cerebro_destino_pendiente_origen | 01c7888fda2de43665e90a53f4d1af66 | postgres only |
| cerebro_destino_riel_afirmado | 21941876a6c3bf97642ca3c3226b1134 | postgres, service_role |
| cerebro_destino_riel_negado | f6b9062f105967cc587ea7997696d56e | postgres, service_role |
| cerebro_detectar_destino | f039e465f4beb0e2aa0ea71faf60a93c | postgres, service_role |
| cerebro_marcar_destino_usd | 2aeb6b92ac97997f32523a7e3cf112fb | postgres, service_role |
| cerebro_registrar_destino | c87c36beafde0cd256a601ee7290d045 (untouched) | postgres, service_role |
| cerebro_registrar_via_cotizada | ad72f2526e716f92d769327b0f26177e | postgres, service_role |
| cerebro_servicio_normalizar | af01e77dc076617d955ce712ecf2c897 | postgres, service_role |
| cerebro_verificar_coherencia_servicio | 5b849da27e0478a0626e0df56331c397 | postgres, service_role |
Triggers: trg_destino_pendiente_origen, trg_zz_destino_agente_al_crear (trg_zz_destino_zelle_al_crear absent). Constraints md5: cerebro_destino_pendiente_tipo_check 8bd3a0385975e6201caeec84400f5a87, notifications_type_check c68e5f5bb5829822121c6e0a6007ad3f.

## D3. n8n PLAN (read-only; nothing in n8n was edited, activated or executed). Next task executes it on the STAGING bot `U52y1kSNvhgxvWeb` and notifier `OCdJoHTkV6S0aAdk`
Tooling: a new gate in `~/cerebro-fase1/pruebas/`, e.g. `gate131-agente-cambia-servicio.py staging|produccion [--seco]`, with the pattern of `gate115-zelle-tiers.py` (GET, save `cerebro-<env>-antes-131-<ts>.json` as the rollback, `rep()` asserting each marker occurs exactly once, drift-checked PUT of `name,nodes,connections,settings`, read-back). Migration 230 + the new 231 are already on staging, so no database step is left.
(The old `gate131-registrar-destino-v2.py` idea of Part B is dropped.) Run the evals first (D3.8), then the PUT, then the live tests.

### D3.1 The 10 "drifted" nodes (staging vs production, measured now, parameters only; connections are byte-identical)
Not all of it is drift to close: most is the environment, and the three feature nodes carry staging-only work (138 catalog), so DO NOT copy production over staging. Keep staging's value for each, and apply the SAME string edits of D3.3-D3.5 to staging now and to production later (each marker below was checked to occur exactly once in both prompts / queries):
| node | what differs | action |
|---|---|---|
| Webhook WaCRM | `path` `staging-wacrm-cerebro-green-v1` vs `wacrm-cerebro-green-v1` (and webhookId) | keep staging (environment) |
| Validar evento | `SECRETO` is a literal in staging, `$env.CEREBRO_WEBHOOK_SECRET` in production | keep staging (environment) |
| Responder por WaCRM / Avisar espera al cliente / Confirmar al admin | `url` `https://crm.onlinefreedom.site/api/v1/messages` vs `https://wacrm.onlinefreedom.site/api/v1/messages` | keep staging (environment) |
| Despertar al enviador | `workflowId` `WmcobAufVNWURbKc` vs `K4ijL3NzmY1VX7XI` (staging has its own outbox sender) | keep staging (environment) |
| DeepSeek sin pensamiento (comunidad) | staging sets `model: custom`, `customModel: deepseek-flash`; production has no such parameters | keep staging (model config of the unused community node) |
| consultar_servicio | `queryReplacement` description: staging "clave EXACTA del servicio segun el catalogo de tu [CONTEXTO] (138)" vs production "combos, recargas, visa, traduccion, mexico o efectivo_usd" | keep staging (138 catalog); production gets 138 only when the owner releases it |
| Contexto conversacion | staging adds `catalogo_servicios` (138) and `monto_recibe_valor/moneda` (153) and moves `deposito_ya_verificado` earlier; production ends with `deposito_ya_verificado` | keep staging; edit D3.4 applies to both (anchor below) |
| Agente Remesas | staging "OTROS SERVICIOS" section reads the 138 catalog (production lists combos/recargas/... and keys) and staging carries a stray 4th parameter literally named `options.systemMessage` (a B1.1 prompt n8n never uses; see T3 of align-staging-with-production) | keep staging; the stray key is harmless, do not touch it; edit D3.3 applies to `options.systemMessage` of both |
Extra node on staging only: "DeepSeek Web Search Chat Model" (123 vs 122 nodes). Credentials: staging "Supabase STAGING" (id np3egGrAcrWkOWd4), production "Supabase Account" (S2CallLPSjzbVXN4); every new node in staging uses np3egGrAcrWkOWd4.
Decisor, Registrar destino auto, marcar_destino_usd and the four quote tools are identical in both environments (Decisor jsCode byte-identical).

### D3.2 New agent tool node `cambiar_servicio`
Type `n8n-nodes-base.postgresTool` typeVersion 2.6 (same as `marcar_destino_usd`, whose position is [4880, 912]; put the new one next to it, e.g. [4880, 1040]), credential `Supabase STAGING` (np3egGrAcrWkOWd4), `descriptionType: manual`, connection `{"ai_tool":[[{"node":"Agente Remesas","type":"ai_tool","index":0}]]}`. onError default (the tool must fail loudly into the agent's error handling like the other tools).
- `query`: `SELECT cerebro_cambiar_servicio($1::uuid, $2::text, $3::text) AS resultado;`
- `options.queryReplacement`: `={{ [$('Decisor').item.json.conversation_id, $fromAI('servicio', 'a que servicio cambia el cliente: zelle, clasica, tropical, cup (tarjeta en pesos) o efectivo (dolares fisicos en Cuba)', 'string'), $execution.id] }}`
- `toolDescription` (Spanish, as the agent reads it): "Cambia el servicio con el que el cliente recibe el dinero en su envio abierto: 'zelle', 'clasica', 'tropical', 'cup' (tarjeta en pesos) o 'efectivo' (dolares en efectivo en Cuba). Llamala SOLO cuando el cliente haya DECIDIDO cambiar de servicio para ESTE envio, aunque no use esas palabras ('mejor zelle', 'ponlo en efectivo', 'prefiero la clasica', 'no, en CUP'). NO la llames si solo pregunta un precio o compara ('¿y por zelle cuanto seria?'), si habla de otra persona u otro envio ('mi hermano usa zelle') ni si ya esta en ese servicio. Devuelve JSON con ok, changed y las cifras nuevas (source_amount_gyd, destination_amount, destination_currency, previous), o reason si no se pudo. Si todavia no hay envio abierto devuelve pendiente=true: queda anotado para cuando se registre. Responde siempre con lo que devuelve, nunca con cifras de memoria."
- `notes`: "Cambio de via por decision del agente (230/231). El sistema NO detecta el cambio en las palabras del cliente: lo decide el agente. Audita automation_service_change."

### D3.3 `Agente Remesas` -> `options.systemMessage` (exact edits, `rep()` each marker exactly once)
(a) Replace the line (currently line 125 of the staging prompt):
`- marcar_destino_usd(tipo): marca que la entrega es en DOLARES por tarjeta 'clasica' o 'tropical', o en 'efectivo' (dolares fisicos en Cuba). NO se usa para Zelle.`
with:
`- marcar_destino_usd(tipo): marca la via en DOLARES la PRIMERA vez que el cliente la elige: tarjeta 'clasica' o 'tropical', o 'efectivo' (dolares fisicos en Cuba). NO se usa para Zelle ni para CAMBIAR una via ya elegida: para eso esta cambiar_servicio. Si responde ERROR porque la via ya fue elegida con cambiar_servicio, no insistas: la via vigente es la que dice el error.`
`- cambiar_servicio(servicio): cambia la via de la operacion abierta ('zelle', 'clasica', 'tropical', 'cup' o 'efectivo'). Ver CAMBIO DE VIA.`
(b) Replace `- Respuesta ambigua a la via ('clasica tropical', 'cualquiera', nombra dos) -> pregunta '¿En cual de las dos: Clasica o Tropical?'. marcar_destino_usd SOLO con una via clara.` by the same text followed by
` Si el cliente YA tenia una via (el [CONTEXTO] trae `riel_operacion`) y ahora pide otra, NO uses marcar_destino_usd: es un cambio, ver CAMBIO DE VIA.`
(c) Insert, right before the line `## ESTILO`, this block (marker `## ESTILO` occurs once):
```
## CAMBIO DE VIA (el cliente cambia como recibe el dinero)
Tu decides, con el contexto de la conversacion, si el cliente CAMBIO de via para ESTE envio. Es un cambio cuando lo decide ('mejor zelle', 'ponlo en efectivo', 'prefiero la clasica', 'no, en CUP'), antes o despues del comprobante, antes o despues de que se verifique el deposito. NO es un cambio: una pregunta de precio ('¿y por zelle cuanto seria?'), comparar vias, hablar de otra persona u otro envio ('mi hermano usa zelle'), o nombrar la via que ya tiene (`riel_operacion` del [CONTEXTO]). Si dudas, pregunta: '¿Quiere que se lo cambie a <via>?'.
Si el cliente cambio: PRIMERO llama cambiar_servicio(servicio), ANTES de escribir la respuesta, y DESPUES responde SOLO con las cifras que devuelve. PROHIBIDO decir que ya cambio si en este turno no llamaste a la herramienta. PROHIBIDO usar calcular_usd, calcular_usd_desde_gyd o marcar_destino_usd para hacer un cambio.
Segun el resultado:
- ok=true y changed=true: 'Listo, queda por <via>. Con sus *<source_amount_gyd> GYD* recibe *<destination_amount> <destination_currency>* (antes eran <previous.destination_amount> <previous.destination_currency>).' y pide SOLO los datos de la via nueva (Zelle: nombre y cuenta; tarjeta: tarjeta y celular; efectivo: lo que diga `entrega_efectivo_falta`). Los datos del destinatario anterior ya no sirven.
- ok=true y pendiente=true: todavia no hay envio abierto; el cambio queda anotado y se aplica cuando se registre. Confirma la via; si cotizas, usa calcular_usd / calcular_usd_desde_gyd con esa via.
- ok=true y changed=false: ya estaba en esa via; confirmalo sin cifras nuevas.
- reason=por_debajo_del_minimo: 'Por <via> el minimo es *<minimo_gyd> GYD* y su deposito es de *<source_amount_gyd> GYD*.' Ofrece mantener la via actual o completar la diferencia. No se cambio nada.
- reason=estado_no_permite, bloqueado_por_humano, tipo_no_soportado o varios_destinatarios: 'Un compañero le ayuda con ese cambio enseguida.' y llama derivar_humano. No prometas el cambio. (Excepcion a la regla 10: aqui SI.)
- reason=operacion_ambigua: ya viene con derivado=true; NO llames derivar_humano otra vez; di que un compañero le atiende enseguida.
- reason=sin_operacion (pendiente=false): ese servicio no se cambia sin un envio abierto; sigue la conversacion normal.
- reason=servicio_desconocido: pregunta a cual via se refiere.
```
(d) In rule 10 (marker `NUNCA porque no entendiste algo o una transcripcion salio rara — eso se resuelve PREGUNTANDO.`) append: ` Tambien cuando cambiar_servicio responde estado_no_permite, bloqueado_por_humano, tipo_no_soportado o varios_destinatarios (ver CAMBIO DE VIA).`
(e) Two examples at the end of `## EJEMPLOS`:
`C: Mejor zelle (envio abierto en efectivo, deposito verificado, 47,100 GYD) -> [llama cambiar_servicio('zelle')] 'Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* (antes eran 162 USD en efectivo). ¿A nombre de quien esta la cuenta Zelle y cual es el correo o celular?'  ## primero la herramienta, luego solo las cifras que devolvio`
`C: Mi hermano usa zelle (envio abierto en efectivo) -> 'Entendido. ¿Quiere que su envio siga siendo en efectivo?'  ## NO es un cambio: no llamas cambiar_servicio`
(f) The "NO se usa para Zelle" statement also appears in the `notes` of the `marcar_destino_usd` node and in its `toolDescription` ("No es para Zelle."): keep, and append to the toolDescription: ` Para CAMBIAR una via ya elegida usa cambiar_servicio.`

### D3.4 Contexto and Decisor: expose the operation's rail, fix `viaSinDefinir`
- `Contexto conversacion` (`query`): replace the anchor `\n\nFROM conversations v WHERE v.id = $1::uuid;` (occurs once in both environments) with
```
,
-- (231) VIA ACTUAL de la operacion abierta (cerebro_riel_op) y servicio declarado antes de que exista la operacion.
(SELECT cerebro_riel_op(o9.id) FROM remittance_operations o9
  WHERE o9.conversation_id = v.id AND o9.service_type = 'remesa'
    AND o9.status IN ('collecting_information','awaiting_deposit','deposit_received','deposit_verification','ready_to_transfer','incident')
  ORDER BY o9.created_at DESC LIMIT 1) AS riel_operacion,
(SELECT p9.tipo FROM cerebro_destino_pendiente p9
  WHERE p9.conversation_id = v.id AND p9.origen = 'agente' AND p9.actualizado > now() - interval '24 hours') AS servicio_pendiente

FROM conversations v WHERE v.id = $1::uuid;
```
(`riel_operacion` is non-null exactly when the database knows the via: operation rail, recipient type, a 157 pending destination or a partial beneficiary.)
- `Decisor` (`jsCode`, identical in both): (i) replace
`const viaSinDefinir = !sabeDestino && !tarjetaCtx && !celularCtx && !s.datos_zelle && !recargaEnCurso && !comboEnCurso && !visaEnCurso;`
by
`const rielOp = ctx.riel_operacion ? String(ctx.riel_operacion) : null;\nconst viaSinDefinir = !rielOp && !ctx.servicio_pendiente && !sabeDestino && !tarjetaCtx && !celularCtx && !s.datos_zelle && !recargaEnCurso && !comboEnCurso && !visaEnCurso;`
so "TODAVIA NO SE SABE POR QUE VIA RECIBE" never appears after a change (the original ignored the operation's rail); (ii) right after that `if (!s.comprobante && viaSinDefinir ...) {...}` block add
`if (rielOp) { notas.push('VIA ACTUAL DE LA OPERACION: ' + ({zelle:'Zelle',clasica:'tarjeta Clasica',tropical:'tarjeta Tropical',cuban_card:'CUP (tarjeta en pesos)',efectivo_usd:'efectivo en USD',recarga:'recarga',combo:'combo',visa:'visa',saldo:'saldo movil'}[rielOp] || rielOp) + '. Si el cliente DECIDE otra, llama cambiar_servicio; una pregunta de precio o hablar de otra persona NO es un cambio.'); }\nif (ctx.servicio_pendiente) { notas.push('EL CLIENTE YA ELIGIO ' + ctx.servicio_pendiente + ' (anotado, todavia no hay envio abierto): se aplica solo cuando se registre el envio.'); }`
Add the Decisor harness cases (`candidato-decisor-*.js` / `casos-decisor-*.json`): (1) op efectivo -> note VIA ACTUAL ... efectivo en USD and no TODAVIA NO SE SABE; (2) no op + pending zelle -> the pending note; (3) nothing known -> TODAVIA NO SE SABE as today.

### D3.5 The end-of-turn check, and the evidence it needs
(a) New node `Verificar coherencia servicio`, `n8n-nodes-base.postgres` 2.6, credential Supabase STAGING, `alwaysOutputData: true`, `onError: continueRegularOutput` (an error must never stop or delay the turn), query `SELECT cerebro_verificar_coherencia_servicio($1::uuid, $2::text) AS coherencia;`, queryReplacement `={{ [$('Decisor').first().json.conversation_id, $execution.id] }}`.
Place: a connection from `Agente Remesas` (main output; today it goes only to `Renderer conversacional`) added as the FIRST connection, so it runs for every turn the agent handled (answered, silent or handed over) and before the send chain; it has no outgoing connection, nothing reads its result, and it can never message the customer.
(b) Make the quote tools record the via (the safety net is blind without it), editing the four nodes' `query` + `queryReplacement` (same `rep()` markers in both environments; each `cerebro_registrar_cotizacion(` occurs once per node):
- `calcular_usd_desde_gyd`: after `... 'USD', 'calcular_usd_desde_gyd') AS r) c ON true` add `LEFT JOIN LATERAL (SELECT cerebro_registrar_via_cotizada($2::uuid, 'calcular_usd_desde_gyd', NULLIF($3, ''), $4::text, t.gyd_depositados) AS v) cv ON true` (the `;` stays at the end) and append `, $execution.id` to the `queryReplacement` array.
- `calcular_usd`: same with `cerebro_registrar_via_cotizada($2::uuid, 'calcular_usd', NULLIF($3, ''), $4::text, t.gyd)`.
- `calcular_envio` and `calcular_inverso` (CUP): `cerebro_registrar_via_cotizada($3::uuid, 'calcular_envio', 'cuban_card', $4::text, NULL)` / `(... 'calcular_inverso', 'cuban_card', $4::text, NULL)` and `, $execution.id` appended to their `queryReplacement`.
An empty `via` (the customer has not said how they receive) records nothing: a generic Zelle price is not a statement about the rail. Efectivo quotes come from `consultar_servicio('efectivo_usd')` (text) and are NOT recorded (documented limit).
(c) No change to `Registrar destino auto` (it keeps applying clasica / tropical / CUP words through 157, now with negation) and none to `Snapshot final`.

### D3.6 Notifier (`OCdJoHTkV6S0aAdk`, production `wGud0KGR6eMqqfMQ`): NO edit needed
The text is already built from the rail the database reports AT NOTIFICATION TIME: `Leer secreto` selects `cerebro_riel_op(operation) AS riel` and `Filtrar cambio de etapa` uses `cfg.riel || rec.delivery_method` ("el nombre y la cuenta Zelle de quien recibe" for zelle, "los datos de quien recibe el efectivo en Cuba" for efectivo_usd). The incident's wrong message was true at that instant (the rail was still efectivo_usd). After the bot's switch the same code says the Zelle text; an `automation_service_change` is NOT in the `verificacion_manual` action list, so a switch itself sends nothing. What stays: when "Mejor zelle" arrives AFTER the notifier fired, the customer receives the cash text first and the bot's reply second; the optional hold of Part B (B2e) would remove that and stays optional. Staging notifier differs from production only by the webhook path and the WaCRM url.

### D3.7 Staging test conversations (number 529622896918; run `supabase/staging/reset-test-contact.sql` before EACH; live WhatsApp needs the owner — an agent does not send messages)
Check after each: `remittance_operations`, `remittance_beneficiaries`, `remittance_admin_audit` (`automation_service_change`), `cerebro_destino_pendiente`, `tool_execution_log` (cambiar_servicio / marcar_destino_usd outcomes, quote lines with via), `notifications` (type coherencia_servicio), `messages` (exactly one bot reply per turn), the n8n execution.
| # | Customer script | Expected database state | Expected bot reply |
|---|---|---|---|
| 1 Carlos | "Voy a mandar 47100 GYD" -> "Puede ser en USD en Bayamo, granma?" (bot quotes cash 162) -> receipt -> "Mejor zelle" within seconds | `zelle`, 181 USD @260, `ready_to_transfer`, cash recipient `reemplazado`, ONE audit row; a late `marcar_destino_usd('efectivo')` refused (outcome `rechazado`); no coherence alert (the execution called cambiar_servicio) | "Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* (antes eran 162 USD)..." + asks Zelle name and account; NO "faltan los datos del efectivo" |
| 2 Declared before the operation | "mejor zelle" with no operation (before the receipt turn creates it) -> receipt | pending row (origen agente) then the operation created `zelle` by the trigger, audit row `pendiente:<exec>`, pending consumed; the receipt turn's `marcar('efectivo')` (if any) refused | confirms Zelle, asks the account data |
| 3 Mi hermano usa zelle | operation in cash; "mi hermano usa zelle" | NOTHING changes, no cambiar_servicio call, no pending row | acknowledges / asks if the cash delivery stands |
| 4 Price question | cash operation; "¿y por zelle cuanto seria?" | no change; quote line with via zelle in `tool_execution_log`; the end-of-turn check raises ONE alert (honest limit: indistinguishable from a switch) and a second identical question does not duplicate it | quotes Zelle without changing; the alert reads "Revisar servicio: el bot cotizó Zelle y la operación está en Efectivo en USD" |
| 5 Zelle -> CUP -> Zelle | verified Zelle; "mejor en CUP" then "no, otra vez zelle" | three audit rows, 141,300 CUP then 181 USD; no lock block | each reply with the new amount and the data to ask |
| 6 Below the minimum | 5,200 GYD in CUP; "mejor zelle" | nothing changed, tool answers `por_debajo_del_minimo` | states the 13,000 GYD minimum and offers to keep CUP |
| 7 Human lock | operator changes the rail in the panel; "mejor zelle" | nothing changed (`bloqueado_por_humano`) | "Un compañero le ayuda con ese cambio enseguida." + derivar_humano |
| 8 Negation | CUP card operation; "no quiero clasica" | nothing changes (detector NULL) | continues without changing |
| 9 Alert resolves | after #4, tell the bot to switch ("sí, cámbialo a zelle") | operation `zelle`; the next turn's check resolves the alert (`resuelta_en` set, notification read) | normal change reply |
Evals first (`~/cerebro-fase1/pruebas/evals/evaluar.py --workflow U52y1kSNvhgxvWeb`, new `casos/casos-cambio-servicio.json`, recorded results taken from the assertion): "Mejor zelle" with an open operation -> `cambiar_servicio` obligatory, `marcar_destino_usd`/`calcular_usd*` forbidden, answer contains the recorded amounts; "mi hermano usa zelle" and "¿y por zelle cuanto seria?" -> `cambiar_servicio` forbidden; a `por_debajo_del_minimo` result -> the minimum is stated; `bloqueado_por_humano` -> `derivar_humano` obligatory.
Rollback: PUT the saved `cerebro-staging-antes-131-<ts>.json`; the database side rolls back with `ROLLBACK-231-agent-service-change-guards.sql` only AFTER the two new nodes (and the via lines) are out of the workflow.

## D4. Decision gaps for the owner
1. RESOLVED 2026-10-08 (owner: treat "no OPEN operation" like "no operation"; see Part E1). Was: a conversation whose latest operation is completed / cancelled and who then says "mejor zelle" BEFORE the new operation exists still gets `estado_no_permite` (230's contract, asserted in bot-change-service case h): the choice is not remembered and the prompt tells the agent to hand over. Repeat customers hit this often. Fix = treat completed / cancelled as "no open operation" for the pending path (changes 230's refusal and its assertion). Not done: needs your call.
2. The safety net cannot tell a price question from a switch, so a comparison question will raise a (low-wording) alert each time the pair is new; it is also blind to zelle -> cash quotes (cash quotes come from `consultar_servicio`, unrecorded) and inert until the four quote nodes call `cerebro_registrar_via_cotizada`. Accept the noise for the first week and measure?
3. The pending service is applied at creation with no deposit amount yet, so the Zelle minimum is not checked at that instant (the deposit-time minimum logic and the stale `cerebro_objetivo_envio` risk of B4 still decide); scenario 2 of D3.7 must prove it on staging.
4. Status after a post-verification switch with no recipient for the new rail (B4), and whether `incident` should be refused: unchanged open points.
5. Staging carries 138 (service catalog) and the 153 `monto_recibe` columns that production does not run; D3.1 keeps them. Decide whether production gets 138 before or after this feature.
6. Production: migration 230 and the NEW 231 are still not applied there (the keyword 231 never was).

---

# PART E — executed on the STAGING bot (2026-10-08; owner go-ahead "sigue", staging only)

Production bot `jEzlVLCLUaJhVwzs`, production notifier and production database were NOT touched. Only workflow `U52y1kSNvhgxvWeb` was written.
(This document is over Engram's 50,000-char limit: it is NOT mirrored; this file is the record.)

## E1. Database follow-up (gap D4.1, staging only; commit 098ead5)
Decision: "no OPEN operation" is treated like "no operation". `cerebro_cambiar_servicio`: with no open operation, only an operation in `transferring` still answers
`estado_no_permite`; a completed / cancelled latest operation (repeat customer) records the pending service (`pendiente:true`, five remesa rails; recarga/combo/visa/saldo stay `sin_operacion`).
`incident` stays refused (it is open, reached later, refused there). Edited the 231 files in place (231 is not in production, not pushed).
- RED first: `bot-change-service.sql` case h (completed/cancelled now `pendiente`, nothing written to the old operation, recarga -> `sin_operacion`) failed with `estado_no_permite`;
  `agent-service-change-guards.sql` case E (new: completed and cancelled -> pending -> `cerebro_crear_operacion` -> the new remittance is born `zelle`, old one untouched, row consumed) failed the same way.
- Re-applied: `ROLLBACK-231` then 231 (each `BEGIN; ...; COMMIT;`). GREEN: `agent-service-change-guards` ALL PASS, `bot-change-service` ALL PASS, and the D2 related set: change-operation-service, deterministic-usd-destination,
  clasica-card-from-delivery-method, quote-from-rail, cash-recipient-add, reparto-usd-card-rail, ultima-cotizacion, reparto-destino-node-adapters (22 parity), delete-notifications and reparto-tool-usd-rail (their "ALL PASS (rolled back on purpose)").
- New fingerprint: `cerebro_cambiar_servicio` md5 `c45bff5f48b88c862f37648d5cbf6593` (was 108249804b3a64690259e1a87bf06236); every other function of the D2 table unchanged (marcar 2aeb6b92..., via_cotizada ad72f252..., coherencia 5b849da2...).
- Side fix found while resetting the test contact: `reset-test-contact.sql` failed (FK `remittance_calculator_week_entries`) when the contact had calculator entries archived in a weekly cut; it now deletes those link rows first.

## E2. What was changed on the staging bot (script `~/cerebro-fase1/pruebas/gate131-cambiar-servicio-staging.py staging [--seco]`; it asserts the target id before the PUT; every marker matched exactly once; the final texts are byte-exact in that script and equal to D3.2-D3.5)
- Backup (rollback): `~/cerebro-fase1/pruebas/cerebro-staging-antes-131-20261008T142309.json` (the `...T142235.json` next to it is the dry run's identical copy). versionId BEFORE `d45b5c97-4156-4d08-9c4a-e0ef24a2dd14`, AFTER `e5ca7171-753b-4e63-878f-233c69dc656c` (= activeVersionId, still active, 123 -> 125 nodes). No re-activation needed.
- New `cambiar_servicio` (postgresTool 2.6, "Supabase STAGING", [4880,1040], `SELECT cerebro_cambiar_servicio($1::uuid,$2::text,$3::text) AS resultado;`, `$fromAI('servicio', ...)`, `$execution.id`, tool description of D3.2) -> `ai_tool` of Agente Remesas.
- New `Verificar coherencia servicio` (postgres 2.6, `alwaysOutputData`, `onError: continueRegularOutput`, `cerebro_verificar_coherencia_servicio(conversation, $execution.id)`), FIRST main connection of `Agente Remesas` (before `Renderer conversacional`).
- `Agente Remesas` systemMessage: `marcar_destino_usd` line rewritten + `cambiar_servicio` line (D3.3a), via-change clause in the ambiguous-via rule (b), the `## CAMBIO DE VIA` block before `## ESTILO` (c), rule 10 sentence (d), two examples at the end (e). Prompt iterations needed: ZERO (first wording worked, see E3).
- `marcar_destino_usd` toolDescription: + "Para CAMBIAR una via ya elegida usa cambiar_servicio."
- `Contexto conversacion` query: + `riel_operacion`, `servicio_pendiente`. `Decisor`: `viaSinDefinir` ignores a known rail / pending service; notes `VIA ACTUAL DE LA OPERACION: ...` and `EL CLIENTE YA ELIGIO ...`.
- `calcular_usd`, `calcular_usd_desde_gyd`, `calcular_envio`, `calcular_inverso`: `LEFT JOIN LATERAL cerebro_registrar_via_cotizada(...)` + `$execution.id` appended to `queryReplacement` (the four SQL texts were first run as prepared statements in a rolled-back transaction: lines `calcular_usd | zelle`, `calcular_envio | cuban_card`, `calcular_inverso | cuban_card`; an empty via records nothing).
- Verified after the PUT (fetched again): every edit present, active, `versionId == activeVersionId`, connections identical to the backup except `Agente Remesas` (+1 edge) and the new `cambiar_servicio`, no credential reference changed (all `Supabase STAGING`, np3egGrAcrWkOWd4). Staging-only nodes (D3.1 drift) untouched.
- ROLLBACK COMMAND: `cd ~/cerebro-fase1/pruebas && python3 rollback-131-staging.py cerebro-staging-antes-131-20261008T142309.json` (PUTs the backup; refuses any id other than the staging bot). Only AFTER that may `ROLLBACK-231` run on the database.

## E3. Tests (no WhatsApp message was sent to anyone)
HONEST SCOPE. The staging bot's webhook replies through `crm.onlinefreedom.site` (real WhatsApp), so the live pipeline (webhook -> Snapshot -> Decisor -> agent -> send) was NOT run. Two layers were run instead:
- LLM layer: `evals/evaluar_cambio_servicio.py` (new; reuses `evaluar.py`: a TEMPORARY workflow with the staging bot's own live prompt, model and tool definitions, tools mocked, deleted in `finally`; nothing reaches the database or WhatsApp). The user message of every case is built by the REAL staging Decisor code run offline with node (`Contexto` fields set per scenario), and the mocked `cambiar_servicio` result is the REAL JSON the database returned in the scenario below. Cases in `evals/casos/casos-cambio-servicio.json` (generator `generar_casos_cambio_servicio.py`); multi-turn `carlos_multiturno.py`. 3 repetitions each.
- Database layer: scenario script (helpers of the 231 assertion, whole run in `BEGIN ... ROLLBACK`), tool calls made in the order the agent would make them. Test contact 529622896918 reset with `reset-test-contact.sql` before and after (it ends clean: 0 contacts); fixtures used other numbers and were rolled back (0 leftovers).
| # | Scenario | LLM layer (3 reps) | Database layer (real results) | Verdict |
|---|---|---|---|---|
| 1 | Carlos: cash, deposit verified, "Mejor zelle" | 3/3 called `cambiar_servicio('zelle')`, no calcular/marcar; reply "Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* (antes eran 162 USD en efectivo)" + asks Zelle name/account. Multi-turn Carlos (4 turns, real memory) 3/3 tool call at turn 4, no call at turns 1-3 | tool -> zelle, 181 USD @260, ready_to_transfer, cash recipient `reemplazado`, ONE audit row, log `changed`; late `marcar('efectivo')` -> `rechazado` naming Zelle, nothing written; coherence check: coherent | PASS |
| 1b | same, "Mejor zelle" before the verification | 3/3 | `marcar('efectivo')` FIRST, `cambiar_servicio` second: zelle, 1 audit row | PASS |
| 2 | "mejor zelle" before the operation exists | 3/3 tool (+3/3 repeat-customer variant `cs11`) | `pendiente:true`; late `marcar('efectivo')` refused ("ya elegiste Zelle..."); receipt creates the operation: zelle, 181 USD, 1 audit, pending consumed | PASS |
| 3 | zelle -> "mejor en CUP" after verification | 3/3, reply 141,300 CUP | 141,300 CUP @3, 2 audits after the second change | PASS |
| 4 | below the minimum (5,200 GYD CUP, "mejor zelle") | 3/3 states the 13,000 GYD minimum, offers to keep CUP, no hand-over | `por_debajo_del_minimo`, nothing changed, 0 audits | PASS |
| 5 | admin-locked rail | 3/3 `cambiar_servicio` + `derivar_humano`, reply "Un compañero le ayuda con ese cambio enseguida." | `bloqueado_por_humano`, rail unchanged | PASS |
| 6 | operation transferring | 3/3 tool + `derivar_humano`, same reply | `estado_no_permite` | PASS |
| 7 | "mi hermano usa zelle" | 3/3 NO tool call, "¿Quiere que su envío siga siendo en efectivo?" | (nothing to write) | PASS |
| 8 | price question "¿y por zelle cuanto seria?" | 3/3 only `calcular_usd_desde_gyd`, no change, offers "¿Quiere que se lo cambie a Zelle?" | quote with via zelle -> the end-of-turn check raises ONE alert "Revisar servicio: el bot cotizó Zelle y la operación está en Efectivo en USD"; a second identical question: same alert (`nueva:false`), 1 notification row; a quote with empty via records nothing | PASS (alert fires, as designed) |
| 9 | second change of mind (zelle -> CUP -> zelle) | 3/3 | 3 changes, 2 audits for the CUP/zelle pair, zelle again 181 USD | PASS |
| 10 | repeat customer (latest operation completed) "mejor zelle" | 6/6 (cs11, two runs) tool, reply "Listo, queda por Zelle. ¿Cuánto desea enviar?" | `pendiente:true` (gap D4.1) | PASS |
| 11 | "no quiero clasica" (CUP op) / "zelle" when already zelle | 3/3 + 3/3 no tool call | detector NULL (231 assertion) | PASS |
| 12 | phrasing variants: "cámbialo a zelle por favor", "Mejor por Zelle gracias", English "I want to switch to zelle instead", "mi hermano usa zelle, mejor hazlo por zelle tambien", "ponlo en efectivo" | all 3/3 tool with the right `servicio` | - | PASS |
| 13 | "no, zelle no, dejalo en efectivo" / "¿que es mejor, zelle o efectivo?" | 6/6 no tool call | - | PASS |
| 14 | tentative "y si mejor lo hacemos por zelle?" | 4/4 CHANGED to zelle (treated as a decision) | - | observation: arguably a question; kept (see E5 gap 2) |
Totals: 41/42 on the first batch (the one ROJO, `cs11` rep 1, was a case-spec flaw: the case forbade the quote tools while the same scenario in `cs3` permitted them; the agent made one useless `calcular_usd_desde_gyd` call next to `cambiar_servicio`; spec fixed, re-run 3/3 green), then 21/21 on the fixed + adversarial batch and 3/3 on the multi-turn runs. The agent called the tool in every scenario that needed it and in none that did not (the only deliberate-edge: the tentative question #14).
Decisor harness (offline, staging Decisor code): `riel_operacion=efectivo_usd` -> `VIA ACTUAL DE LA OPERACION: efectivo en USD...` and no "TODAVIA NO SE SABE"; `servicio_pendiente=zelle` -> `EL CLIENTE YA ELIGIO zelle...`; nothing known -> "TODAVIA NO SE SABE" as before; the pre-change Decisor emits none of the new notes.
Limits, stated plainly: the harness's tool schemas are derived by regex and do not include the `via` parameter of the quote tools (4-argument `$fromAI`), so the cs9 run could not show whether the live agent passes `via='zelle'`; the alert on a price question therefore fires only when the agent passes a via (the database part is proven). The race "Mejor zelle seconds after the receipt" (two executions in parallel) is covered at the database level in both orders (S1/S1b) but not as two concurrent n8n executions. The end-of-turn node, the new context columns and the via-recording in the live workflow ran only as SQL / offline code, not inside a live execution.

## E4. What remains for the owner's live phone test (staging, from 529622896918; run `reset-test-contact.sql` with `-v phone=529622896918` first)
1. "Voy a mandar 47100 GYD" -> bot asks currency/via. 2. "Puede ser en USD en Bayamo, granma?" -> bot quotes cash USD (162 USD). 3. send a receipt screenshot (verify the deposit in the panel as admin). 4. "Mejor zelle".
   Expect: ONE reply "Listo, queda por Zelle. Con sus *47,100 GYD* recibe *181 USD* (antes eran 162 USD en efectivo)..." asking the Zelle account holder and e-mail/phone; the operation shows Zelle / 181 USD / same status, one `automation_service_change` audit row; no "faltan los datos del efectivo"; no team alert.
5. New reset. "mejor zelle" first, then the amount and receipt -> operation is born Zelle. 6. "mi hermano usa zelle" on a cash operation -> no change. 7. "¿y por zelle cuanto seria?" -> quote only; check the CRM notification list for "Revisar servicio: el bot cotizó Zelle...". 8. "mejor en CUP" after verification -> 141,300 CUP. 9. an operation under 13,000 GYD in CUP then "mejor zelle" -> states the minimum.
   Queries after each: `remittance_operations`, `remittance_admin_audit` (`automation_service_change`), `tool_execution_log` (`cambiar_servicio`, quote lines with via), `notifications` (`coherencia_servicio`), `cerebro_destino_pendiente`.

## E5. Plan to repeat on production LATER (needs the owner's explicit go-ahead; nothing below was done)
1. Decide D4.5 first (does production get 138 / 153 before or after: the gate's markers were checked on both prompts, but `consultar_servicio` / context differences stay).
2. Database: apply 230 then the (final) 231 to `hqztotshnlzaiziwjyzh` the way `gate123-aplicar-db.py` does (`BEGIN; <file>; COMMIT;` after a forced-rollback rehearsal and the pre/post fingerprints of D2 + E1), run the assertions wrapped in rollback, keep `ROLLBACK-231` / `ROLLBACK-230` ready. The database MUST go first (the workflow calls its functions).
3. Bot: point the same gate at production: add the `produccion` branch to `gate131-cambiar-servicio-staging.py` (CER `jEzlVLCLUaJhVwzs`, credential "Supabase Account" S2CallLPSjzbVXN4 for the two new nodes, hard assert on the id), run `--seco`, diff against D3.1 (production's prompt/context differ in the "OTROS SERVICIOS" section and `consultar_servicio`; markers were measured once in both), then the PUT; read-back as in E2.
4. Rollback: PUT the saved `cerebro-produccion-antes-131-<ts>.json`; only then `ROLLBACK-231` (then 230 if wanted).
5. Notifier: no edit (D3.6). Optional hold of the notification while a message is pending (B2e) stays optional.

## E6. Decision gaps
1. Run the owner's phone test (E4) before production; the live pipeline was not exercised by an agent.
2. "y si mejor lo hacemos por zelle?" is treated as a decision (changes). Keep (the customer said "mejor") or ask first? The prompt currently says "si dudas, pregunta".
3. The end-of-turn alert depends on the live agent passing `via` to the quote tools; measure on the first live days (the alert is deliberately neutral/low-priority).
4. D4 points 2-6 unchanged (alert noise, deposit-time minimum, 138 / 153 in production, migrations 230/231 still absent from production).

## F1. Production database, migrations 230 + 231 (2026-10-08, owner "pasa a produccion")
- Backup `~/wacrm-respaldos/produccion-20261008T214130Z.dump`. Pre-check: production had the pre-230/231 definitions with
  no drift (`crm_cambiar_servicio` ee82240e…, detector 31f6d02d…, registrar c87c36be…, tool f239d898…, `cerebro_minimo_gyd`
  f709f161…), last migration 229.
- `~/cerebro-fase1/pruebas/gate132-aplicar-db.py` (helper `zz_wu5b_exec` created before, dropped after, count 0):
  `ensayo` -> every function md5, the two triggers, the three constraints and the pending table columns equal to
  staging; `GATE_BUNDLE=ida-y-vuelta ensayo` -> the four replaced functions and the three constraints back to their
  pre-230 md5s, new objects gone; `aplicar` -> `{"r":"OK"}`, recorded as `230_bot_change_service` and
  `231_agent_service_change_guards`.
- Assertions on production (rolled back): `agent-service-change-guards` and `change-operation-service` pass.
  `bot-change-service` passes cases a-l and stops at case m, which expects `crm_cambiar_servicio` to be granted to
  service_role: production never granted it (pre-existing, stricter than staging; also `cerebro_minimo_gyd`,
  `cerebro_riel_op`, `crm_calcular_monto_destino`). Not a defect of 230; the bot's credential connects as `postgres`
  (gate `quien`). The new functions carry the intended grants (bot functions: service_role; core: none).
- Read back: `cerebro_cambiar_servicio` md5 c45bff5f…, 0 pending rows, 0 coherence alerts, operations and calculator
  entries untouched by the migration.
