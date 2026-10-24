# Cerebro n8n: staging to production promotion plan (2026-10-23)

Read-only preparation. Nothing was written, activated, executed or published in n8n. Run after DB migrations 243-292 are in production.

## 1. Fresh backups (GET only, mode 600, outside the repo)

| Env | Workflow | versionId (= activeVersionId) | Nodes | Decisor md5 | Backup |
|---|---|---|---|---|---|
| staging | U52y1kSNvhgxvWeb | 218fbd5d-2c84-436d-9305-851b3279d2f5 | 132 | 4ed9c08c (matches repo) | ~/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-218fbd5d-2c84-436d-9305-851b3279d2f5-20261023-180521.json |
| production | jEzlVLCLUaJhVwzs | 5b3159b9-b8a2-49be-a8cd-018b0a899459 | 127 | 252f1489 (differs from repo) | ~/cerebro-fase1/respaldos-n8n/produccion-jEzlVLCLUaJhVwzs-5b3159b9-b8a2-49be-a8cd-018b0a899459-20261023-180523.json |

(Full paths: /home/onlinefreedom/cerebro-fase1/respaldos-n8n/.) Re-take the production backup immediately before applying; the version id above is only the state at 18:05 on 2026-10-23.

## 2. Node-by-node diff (staging vs production)

Totals: 5 nodes only in staging, 0 only in production, 127 shared. 23 shared nodes differ by content (`cerebro_n8n.py comparar`); most of the remaining ~45 "differences" are only the credential id.

### Added in staging (not in production)
| Node | Type | DB function | Wired |
|---|---|---|---|
| declarar_servicio | postgresTool | cerebro_declarar_servicio | ai_tool to Agente Remesas |
| agregar_servicio | postgresTool | cerebro_aplicar_servicio | ai_tool to Agente Remesas |
| modificar_operacion | postgresTool | cerebro_modificar_operacion | ai_tool to Agente Remesas |
| registrar_destinatario_mexico | postgresTool | cerebro_guardar_beneficiario_mexico | ai_tool to Agente Remesas |
| DeepSeek Web Search Chat Model | community lmChatDeepSeekWebSearch | none | NOT connected to anything (orphan experiment) |

Recommendation: do NOT promote the orphan DeepSeek Web Search node (needs community package `n8n-nodes-deepseek-web-search` on the production instance, does nothing). Promote the 4 tools.

### Disabled in staging (enabled in production)
Registrar beneficiario auto, Registrar destino auto, Registrar zelle auto, marcar_destino_usd. Promotion must keep them `disabled: true` (the agent tools replace them). Note the production `marcar_destino_usd` tool is currently enabled; disabling it is a behaviour change to confirm with the owner.

### Changed parameters (shared nodes)
- Decisor: jsCode 252f1489 -> 4ed9c08c (+132/-13 lines; repo file `pruebas/decisor/decisor.jscode` matches staging). Only config read: cerebro_config.
- Agente Remesas: options.systemMessage (+223/-235 lines); maxIterations 6 and enableStreaming unchanged.
- Contexto conversacion: query gains `catalogo_servicios` (cerebro_catalogo_servicios, 138), `monto_recibe_valor/moneda` (cerebro_monto_recibe, 153), `servicio_resuelto` (cerebro_resolver_servicio, 283/265+), `usd` field in the operations JSON; `deposito_ya_verificado` block moved. No environment-specific literals found in it.
- calcular_envio / calcular_inverso / calcular_usd / calcular_usd_desde_gyd: query now a thin call to `cerebro_cotizar` (243/288/289), `$fromAI` schemas reworked (moneda and via params, descriptions).
- cambiar_servicio: now `cerebro_aplicar_servicio` (was cerebro_cambiar_servicio), new service keys in $fromAI and toolDescription.
- consultar_servicio: $fromAI description (catalogue key); gestionar_beneficiario: new query (284, 8 params, queryReplacement extended); registrar_beneficiario_zelle: new query (274/285, 6 params); registrar_numeros_recarga: new query with accion agregar/quitar (276/282/289/292) and $execution.id; marcar_destino_usd: toolDescription/$fromAI (adds cup), disabled; repartir_envio: toolDescription only.
- Transcribir audio: bodyParameters `prompt` text differs (one line); model, language, URL same.
- GPT-4o vision (respaldo): staging lacks `builtInTools: {}` (cosmetic).
- DeepSeek sin pensamiento (comunidad): staging sets `model: custom, customModel: deepseek-flash`; production has none. Behavioural, needs an owner decision (see section 3).
- Validar evento: only the SECRETO line (see section 3). Everything else identical.

### Connections
Only 4 new source entries (the 4 tools, each ai_tool to Agente Remesas). No other connection differs, none removed.

## 3. Environment-specific: keep the PRODUCTION value

| Item | Staging value (do not copy) | Production value (keep) | Nodes |
|---|---|---|---|
| Postgres credential | np3egGrAcrWkOWd4 "Supabase STAGING" | S2CallLPSjzbVXN4 "Supabase Account" | 50 shared nodes + the 4 new tools (set prod id on every postgres/postgresTool node) |
| WaCRM HTTP credential | iHWfJCYmlenmliPM "WaCRM API STAGING" | p8EN42saerBDHZwI "WaCRM API" | Responder por WaCRM, Avisar espera al cliente, Confirmar al admin |
| WaCRM URL | https://crm.onlinefreedom.site/api/v1/messages | https://wacrm.onlinefreedom.site/api/v1/messages | same 3 nodes (parameters.url) |
| DeepSeek (native) | f0K27ImOFO3QdL34 "DeepSeek account" | ol8nMUZZQYBILen2 "Osmany CRM" | DeepSeek sin pensamiento |
| DeepSeek community | 2joB4BwDAiyuSMcC "deekpseek comunidad" | cNiZzNwlP0IrAIh1 "osmany_chat" | DeepSeek sin pensamiento (comunidad), DeepSeek vision (principal) |
| Webhook path | staging-wacrm-cerebro-green-v1 | wacrm-cerebro-green-v1 | Webhook WaCRM |
| webhookId | e0f1cb8e-... | 60fa64bc-b9f1-4520-9e77-e8bb1492022a | Webhook WaCRM; also Espera extra and Esperar ventana have different webhookIds (keep production's) |
| Execute Workflow target (outbox sender) | WmcobAufVNWURbKc | K4ijL3NzmY1VX7XI | Despertar al enviador (parameters.workflowId.value) |
| Error workflow (settings.errorWorkflow) | 1Elx6fZ3z5vQI3dj | g3UgayrNlXBXZgnr | workflow settings |
| Webhook shared secret | hardcoded 64-hex literal in Validar evento jsCode (SECURITY: a literal secret in staging JSON; never paste it) | `$env.CEREBRO_WEBHOOK_SECRET` | Validar evento: keep production's jsCode verbatim |
| DeepSeek model override | customModel deepseek-flash | none (credential default) | decide with owner; default = keep production (no override) |

Identical in both (safe as is): httpHeaderAuth 0hYs94cen78qvqqb (Meta token), openAiApi BHpcqLjEuUJbQ0eB and XHZZXkggzLsseE6Z, openRouterApi deP1ePjKBIaqkx5h.
The task brief's repartos ids Yu0uskQhydWgNFEy (staging) / 5YseDUEC5IAaiofF (production) do NOT appear anywhere in either workflow JSON; the only Execute Workflow node is "Despertar al enviador" (ids above). "Notifier ids": none found as node parameters; the error workflow ids above are the only notifier-like references. Other staging markers: the word "staging" appears only in comments (Medir el turno, both envs) and credential names. No pinData, no staticData, no tags in either. Workflow `active: true` in both.

## 4. Promotion plan

Tooling gap: `cerebro_n8n.py` has no command that builds or applies a whole-workflow promotion. `publicar-decisor` only writes the Decisor; `restaurar` can restore a full backup (PUT name/nodes/connections/settings). Adding/changing tool nodes has "no helper command" (SKILL.md). Therefore the promotion needs a NEW small script (or a reviewed one-off) built on the same functions; it is not mechanical with the existing commands. Suggested `infra/n8n/promover_cerebro.py` (pure transform + the existing guarded PUT, with unit tests in `infra/n8n/tests`).

Transform (production backup as base, so every env value stays production by construction):
1. Start from the production backup JSON. For each node in staging that also exists in production: take the staging `parameters`, `disabled`, `notes`, position; but keep production `id`, `credentials`, `webhookId`, and re-apply the env overrides table above (url x3, workflowId, webhook path, Validar evento jsCode, DeepSeek community model block).
2. For the 4 new tools: deep-copy the staging node, new uuid4 ids, replace `credentials.postgres` with `{id: S2CallLPSjzbVXN4, name: Supabase Account}`, add ai_tool connections to Agente Remesas. Skip DeepSeek Web Search Chat Model.
3. Keep production `settings` (errorWorkflow g3UgayrNlXBXZgnr). Carry over staging `disabled: true` for the 4 nodes.
4. Safety asserts in the script: no `np3egGrAcrWkOWd4`, `iHWfJCYmlenmliPM`, `crm.onlinefreedom`, `staging-wacrm`, `WmcobAufVNWURbKc` or 64-hex literal anywhere in the output; every postgres credential id is the production one; node count = 127 + 4 = 131; Decisor md5 = 4ed9c08c; dry-run mode prints a node-level diff against production and writes only to the scratchpad.

Steps (each production write needs the owner's explicit go-ahead; never execute the workflow):
1. Confirm migrations 243-292 are applied in production (section 5 functions exist).
2. `python3 infra/n8n/cerebro_n8n.py estado produccion` (note versionId and `--esperado`), then `respaldo produccion` (rollback file).
3. Build + dry-run: `python3 infra/n8n/promover_cerebro.py --dry-run` (new script), review the diff with the owner.
4. Owner go-ahead, then apply with the expected-version guard (refuse if live versionId does not start with the value from step 2); PUT only name/nodes/connections/settings.
5. Verify: `estado produccion`: versionId == activeVersionId, nodes 131, Decisor md5 4ed9c08c, repo match yes. If activeVersionId lags: POST `/api/v1/workflows/jEzlVLCLUaJhVwzs/deactivate`, wait 2 s, POST `/activate` (brief bot stop; owner go-ahead), re-run `estado`. Run `comparar` and confirm only the env-specific rows differ. Confirm the new tools in a later real execution, not by running the workflow.
6. Rollback: `python3 infra/n8n/cerebro_n8n.py restaurar produccion /home/onlinefreedom/cerebro-fase1/respaldos-n8n/<backup taken in step 2> --esperado <live versionId prefix after apply>` (it backs up the live state first and verifies).

## 5. DB functions needed in production (must exist after 243-292)

| Node | Function(s) | Defined in |
|---|---|---|
| declarar_servicio | cerebro_declarar_servicio | 265, 273, 278, 283, 288 |
| agregar_servicio, cambiar_servicio | cerebro_aplicar_servicio | 266, 273, 279, 283, 286, 288 |
| modificar_operacion | cerebro_modificar_operacion | 281, 287, 288 |
| registrar_destinatario_mexico | cerebro_guardar_beneficiario_mexico | 271, 275, 288, 290 |
| calcular_* (4) | cerebro_cotizar | 243, 288, 289 |
| gestionar_beneficiario | cerebro_guardar_beneficiario (8-arg signature) | 284 (latest 288) |
| registrar_beneficiario_zelle | cerebro_guardar_zelle (extended signature) | 274, 285 (latest 288) |
| registrar_numeros_recarga | crm_registrar_numeros_recarga (accion, p_abrir) | 276, 282, 283, 289, 292 |
| Contexto conversacion | cerebro_catalogo_servicios (138), cerebro_monto_recibe (153), cerebro_resolver_servicio (265+) | 138, 153, 265, 273, 277, 279, 283, 288 |

Migration 269 has no SQL (n8n-only, per prod-readiness note). Check each function's signature (arg count) in production before applying; the new queries pass more args than the old ones (e.g. cerebro_guardar_beneficiario now 8, queryReplacement extended), so the workflow applied before the migrations would break those tools. Order: migrations first, then workflow.
