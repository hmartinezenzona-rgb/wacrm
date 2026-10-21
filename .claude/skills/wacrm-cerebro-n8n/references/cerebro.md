# Cerebro n8n reference

## Environments

| Env | Workflow id | Notes |
|---|---|---|
| staging | `U52y1kSNvhgxvWeb` | Shares production's WhatsApp token. Never execute it. |
| produccion | `jEzlVLCLUaJhVwzs` | Owner go-ahead before every write. |

Base URL `https://automatizaciones-n8n.ttjgax.easypanel.host`. Key in `~/.n8n-api-key`, sent as header `X-N8N-API-KEY`.
Backups default to `~/cerebro-fase1/respaldos-n8n/<env>-<workflowId>-<versionId>-<timestamp>.json` (mode 600, outside the repo).

## Tool: `infra/n8n/cerebro_n8n.py`

Env overrides (tests): `CEREBRO_N8N_BASE`, `CEREBRO_N8N_BACKUPS`, `CEREBRO_DECISOR_FILE`.

- `respaldo <env>`: GET and save a backup.
- `estado <env>`: versionId, activeVersionId, active, node count, Decisor md5 (8 chars), repo match.
- `comparar`: nodes only in one env, and nodes whose parameters differ (Code: jsCode md5, Postgres: query md5, others: parameters md5). Many nodes differ by design (ids, paths); the interesting ones are Decisor and Contexto conversacion.
- `publicar-decisor <env> --esperado <md5 prefix>`: refuses if the live Decisor md5 does not start with the prefix (min 4 chars); backup, PUT only name/nodes/connections/settings, then verifies versionId == activeVersionId, Decisor md5 == repo file, node count unchanged.
- `restaurar <env> <backup.json> --esperado <versionId prefix>`: refuses a backup of another workflow id or a live versionId mismatch; backs up the live state first; verifies after.

## Node names

`Decisor` (Code, source `pruebas/decisor/decisor.jscode`), `Contexto conversacion` (Postgres; staging has extra fields), `Agente Remesas` (the agent; tools attach to it), `DeepSeek sin pensamiento (comunidad)` (model), tool nodes such as `cambiar_servicio`, `consultar_servicio`, `repartir_envio`.

## Tool node pattern

A Postgres tool node wired `ai_tool` -> `Agente Remesas`:

- `parameters.query`: `SELECT cerebro_x($1::uuid, $2::text, $3::text) AS resultado;`
- `parameters.options.queryReplacement`: `={{ [$('Decisor').item.json.conversation_id, $fromAI('partes', 'description', 'string'), $execution.id] }}`
- `parameters.toolDescription`: tells the model when to call it and when not to.
- `credentials`: inherited from the node it was cloned from.

## Clone recipe

1. `respaldo <env>`; GET the workflow.
2. Pick the existing tool node of THAT environment (for example `cambiar_servicio`); `copy.deepcopy`.
3. New `id` (uuid4), new `name`, position shifted by 160 in y, override `query`, `toolDescription`, `options.queryReplacement`, `notes`.
4. Assert the credential equals the source node's.
5. `connections[name] = {"ai_tool": [[{"node": "Agente Remesas", "type": "ai_tool", "index": 0}]]}`.
6. PUT only name/nodes/connections/settings; GET and verify versionId == activeVersionId and the node set.

Reference scripts from 2026-10-19/20 (S4b, S6, production S4b+S6) followed this recipe.

## Decisor harness

`npx vitest run pruebas/decisor`; `pruebas/decisor/correr.ts` pins `DECISOR_MD5_ESPERADO`. The `.jscode` extension keeps formatters away; never reformat it.

## Prompt deploy and evals

Prompts go through `~/cerebro-fase1/pruebas/evals/desplegar_prompt.py --candidato <file> --etiqueta <tag>` (writes a ROLLBACK first). Run the gold battery first: `python3 evaluar.py --prompt <file>` in `~/cerebro-fase1/pruebas/evals/`. Parameter-only changes apply at once; structure changes do not.

## versionId / activeVersionId trap

After a structural change (nodes or connections) n8n can keep running the in-memory version, so `activeVersionId` stays on the old one. Fix:
`POST /api/v1/workflows/{id}/deactivate`, wait 2 s, `POST /api/v1/workflows/{id}/activate`, then re-run `estado`. On production this briefly stops the bot: owner go-ahead first. Confirm new nodes appear in a later execution, not only that the output looks right.
