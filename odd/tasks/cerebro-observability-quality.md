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
- [ ] T2 — Record DeepSeek usage (prompt/completion/cache-hit tokens) in the turn telemetry.
  - n8n drops the model's tokenUsage from the Agent output (n8n issue #26302); it exists only in
    the sub-node's execution data (prod sample: promptTokens 43,844 per call). No in-flow node
    can read it → out-of-band collector reading finished executions via the n8n API and filling
    `cerebro_telemetria_turno` by execution_id. Cache-hit tokens are not exposed by LangChain.
- [x] T3 — Scope G3 to paragraphs where the USD route is in play.
  - G3 fires only if `tarjeta_generica` AND the USD route is in play (Snapshot `datos_zelle`, or
    usd/dólar(es)/zelle/clásica/tropical in the customer's batch text or in the reply).
    `tarjeta_generica` is still measured as before.
  - Bench `pruebas/banco-semantica-g3.js`: current 5/7 (the 2 CUP false alarms) → 7/7.
  - T1+T3 deployed to STAGING 2026-09-26: rollback `~/cerebro-fase1/ROLLBACK-cerebro-staging-antes-observabilidad.json`
    (versionId 09e9577a…), live 79293fff-f4f0-4bb3-90a7-a5a1ff2d2610 == candidate; only
    "Medir el turno" and "Medir la semantica del turno" differ, connections/settings equal.
  - Pending: live check with the test contact.
- [ ] T4 — Accounts in one place (design + decision: 9 nodes incl. deposit registration).

## Checks
TDD strict: node benches over the real Code-node source (`~/cerebro-fase1/pruebas`), RED before
GREEN; staging put + verify identical; live check with the test contact.

## Progress
- 2026-09-26: document created after exploration.
