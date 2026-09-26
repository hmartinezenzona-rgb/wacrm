# Cerebro observability and quality (staging first)

## Objective
Improve the Cerebro without changing how it answers customers: make its silences and model
cost measurable, stop a quality rule from raising false alarms, and prepare account data to
live in one place. Staging first (`[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1`, n8n
`U52y1kSNvhgxvWeb`); production later, by the user's decision.

## Evidence (production analysis 2026-09-26, Engram `cerebro/analysis-2026-09-26`)
- 53% of turns are `ruta = 'silencio'`; sampled ones are superseded burst runs (the bot answered
  within ~1 min), but `extra.hold_reason` is empty on all 513, so real holds are invisible.
- `prompt_tokens`, `completion_tokens`, `cache_hit_tokens` are NULL on every turn: DeepSeek cost
  and cache use are unmeasured.
- `G3_GENERIC_CARD_AMBIGUITY` fires 39×/week on "tarjeta" without cubana/clásica/tropical, but
  the agent prompt tells it to ask for "la tarjeta y el celular" in the CUP flow: false alarms.
- Account numbers/titulares (6762167, 6990225, Osmany Pozo, Osmany Services) are hardcoded in 9
  nodes: agent prompt, 4 vision prompts, Parsear vision, Registrar deposito auto, Historial
  contacto, Transcribir audio.

## Constraints
- The staging Cerebro shares production's WhatsApp and AI credentials: an end-to-end turn sends a
  REAL WhatsApp. Live checks only with the staging test contact (conversation 5f69dde1).
- No change to what the bot says: T1–T3 only touch telemetry/audit code.
- Test the real node code extracted from the workflow JSON (existing bench practice), rollback
  snapshot before every put.

## Tasks
- [x] T1 — Record why a turn is silent in the turn telemetry.
  - `extra.motivo_silencio` (new key; the existing `hold_reason` belongs to the presentation
    compiler): rafaga_otro_proceso, evento_duplicado, replay, sin_lote, bot_pausado,
    chat_oculto, chat_asignado, humano_reciente, mensaje_admin, decisor:<motivo>,
    limite_abuso, valla_propiedad, modelo_skip; null when the turn answered. Derived with
    `$(node).isExecuted` + the Decisor's own `motivo`. `cerebro_telemetria_registrar` stores
    `extra` whole (checked).
  - Bench `~/cerebro-fase1/pruebas/banco-medir-turno.js` (real node code): RED 0/14 → GREEN
    14/14; every other telemetry field identical to the old code in 3 scenarios.
- [x] T2 — Record DeepSeek usage (prompt/completion/cache-hit tokens) in the turn telemetry.
  - n8n drops the model's tokenUsage from the Agent output (n8n issue #26302); it exists only in
    the sub-node's execution data (prod sample: promptTokens 43,844 per call). No in-flow node
    can read it → out-of-band collector reading finished executions via the n8n API and filling
    `cerebro_telemetria_turno` by execution_id. Cache-hit tokens are not exposed by LangChain.
  - User chose option 1 (2026-09-26): collector inside n8n. Credential `n8n API (recolector de
    tokens)` (httpHeaderAuth X-N8N-API-KEY, id Fo37JUBboJiO8pGa; the key was never printed).
  - Workflow `[STAGING] Cerebro - Recolector de tokens` (n8n j1SrhNxDe2SZhVbE, active): every 10
    min GET /api/v1/executions?workflowId=U52y1kSNvhgxvWeb&status=success&includeData=true&limit=25
    → "Extraer tokens" (sums ai_languageModel tokenUsage per execution) → UPDATE
    cerebro_telemetria_turno ... WHERE execution_id=$1 AND prompt_tokens IS NULL (idempotent).
    saveDataSuccessExecution=none (it downloads heavy execution data); errors are kept.
    Source: `~/cerebro-fase1/candidato-workflow-recolector-tokens-staging.json`.
  - Bench `~/cerebro-fase1/pruebas/banco-recolector-tokens.js` over REAL staging executions
    (244580: 1 call, 17,653/12 tokens; 244579: burst turn, no model): RED 3/5 → GREEN 5/5.
    SQL tested on staging rolled back: fills once, a second run updates 0 rows.
  - VERIFIED LIVE 2026-09-26: the first run filled 244580 (1 call, 17,653 / 12 tokens) and 244499
    (1 call, 16,792 / 43). An old turn (163440, 2026-09-16) stays null: the collector only reads the
    latest 25 successful executions (enough for production's ~7 per 10 min; older execution data
    may also be pruned by n8n). Only new turns get tokens; no backfill.
- [x] T3 — Scope G3 to paragraphs where the USD route is in play.
  - G3 fires only if `tarjeta_generica` AND the USD route is in play (Snapshot `datos_zelle`, or
    usd/dólar(es)/zelle/clásica/tropical in the customer's batch text or in the reply).
    `tarjeta_generica` is still measured as before.
  - Bench `pruebas/banco-semantica-g3.js`: current 5/7 (the 2 CUP false alarms) → 7/7.
  - T1+T3 deployed to STAGING 2026-09-26: rollback `~/cerebro-fase1/ROLLBACK-cerebro-staging-antes-observabilidad.json`
    (versionId 09e9577a…), live 79293fff-f4f0-4bb3-90a7-a5a1ff2d2610 == candidate; only
    "Medir el turno" and "Medir la semantica del turno" differ, connections/settings equal.
  - Live check 2026-09-26 11:54 UTC (burst "Hola / Buenod / Dias" from the test contact):
    two superseded turns = `rafaga_otro_proceso` ✓, one reply, no G3 ✓ — but the answering
    turn wrongly got `sin_lote`: "Cerrar lote" runs at the end of EVERY processed batch.
    Fix (TDD): 2 real-case bench cases RED → answered turns get null first, `sin_lote` only
    when the Decisor did not run → 16/16. Redeployed: live dfa833b2-3b2c-4387-9bca-c9532116bfc9
    == candidate. Second live burst 12:08 UTC ("Hola buenos días / Q / Tal estas"): 244578 and
    244579 `rafaga_otro_proceso`, 244580 answered with motivo_silencio null ✓, no G3 ✓.
    T1 and T3 verified live on staging.
- [ ] T4 — Accounts in one place (design + decision: 9 nodes incl. deposit registration).

## Checks
TDD strict: node benches over the real Code-node source (`~/cerebro-fase1/pruebas`), RED before
GREEN; staging put + verify identical; live check with the test contact.

## Progress
- 2026-09-26: document created after exploration.
- 2026-09-26: user decided production AFTER the cutover; runbook `~/cerebro-fase1/PASOS-cerebro-observabilidad-produccion.md`, prod candidates ready.
