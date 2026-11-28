# WU5a — rewire the legacy `deals` writers on the STAGING twin

Workflow: `[STAGING] Cerebro v2 — LEGACY OPTIMIZED V1` — **`U52y1kSNvhgxvWeb` only**.
Production `jEzlVLCLUaJhVwzs` was never requested, read, or written.
Full report: `/home/onlinefreedom/wacrm-worktrees/.briefs/WU5a-report.md`.
Snapshots (large, kept out of the repo): `agent-shared/reports/wu5a-staging-workflow-{before,after}.json`.

## Change

Only `parameters.query` of the six nodes below changed. `queryReplacement` (the bind mechanism)
is byte-identical before/after; `connections`, `settings`, node order and `active` unchanged.

| node | new query |
|---|---|
| `Registrar beneficiario auto` | `SELECT * FROM cerebro_registrar_beneficiario_auto($1::uuid, $2::text, $3::text, $4::text);` |
| `Registrar zelle auto` | `SELECT * FROM cerebro_registrar_zelle_auto($1::uuid, $2::text, $3::text, $4::text);` |
| `gestionar_beneficiario` | `SELECT * FROM cerebro_gestionar_beneficiario($1::uuid, $2::text, $3::text, $4::text, $5::text);` |
| `registrar_beneficiario_zelle` | `SELECT * FROM cerebro_registrar_beneficiario_zelle($1::uuid, $2::text, $3::text, $4::text);` |
| `registrar_reparto_multiple` | `SELECT * FROM cerebro_registrar_reparto_multiple($1..$11::text);` |
| `marcar_destino_usd` | `SELECT * FROM cerebro_marcar_destino_usd($1::uuid, $2::text, $3::text);` |

`Registrar deposito auto` was left untouched: it already called the deal-free
`cerebro_registrar_deposito($1..$6)`. The brief's "seven nodes" premise holds for six.

## Pre-flight answers (brief §3)

1. **Binding** — all six use `parameters.options.queryReplacement` (array of bind params), never SQL
   interpolation. Every staging signature is already in the node's `$1..$n` order; no reordering.
2. **Consumers** — no expression anywhere in the workflow reads any of the six nodes' output
   (`$('<node>')` returns NONE for all six). The returned `id` changes meaning
   (`deals.id` → `remittance_operations.id`) and nothing expression-reads it. Contrast:
   `Cruzar deposito con MMG` does read `$('Registrar deposito auto').first().json.id`, which is why
   that node keeps its `SELECT deal_id AS id` alias and was not rewired.
3. **Idempotency** — key = last bind param = `$execution.id`, hashed inside the function exactly as
   the old node SQL did (`tool_execution_log.idempotency_key`, UNIQUE, `ON CONFLICT DO NOTHING`).

## Verification

- Confirm-GET matches the intended body exactly; server `versionId`
  `06d3e4bf-dc17-4926-8e01-c4397f31e93d` (was `cbbd5642-ff82-465f-9f77-4aee44f664d7`).
- Static: all seven functions live on staging, none of their bodies touches `deals`.
- **End-to-end** (real webhook message, executions 294201 / 294209):
  - `Registrar beneficiario auto` → `envio nuevo creado con beneficiario auto`, `cuban_card`
    `9224123456789012` / `55512345`.
  - `Registrar zelle auto` → `envio nuevo creado`, `zelle` `Maria Lopez` /
    `maria.lopez@gmail.com`.
- **Direct node execution only** (the four `ai_tool`-only nodes have no inbound `main` edge):
  `gestionar_beneficiario` → `envio nuevo creado`; `registrar_beneficiario_zelle` →
  `envio nuevo creado`; `registrar_reparto_multiple` → `envio nuevo creado con reparto`;
  `marcar_destino_usd` → `envio nuevo creado, entrega en USD por Clasica`.
- **`deals` proof:** 35 before every run, 35 after every run, per-path `deals_this_conv = 0`.

## Accepted divergence — user-visible

`marcar_destino_usd` when the rail was already typed: old text
`destino marcado: entrega en USD por Clasica`, new text
`sin cambios: ese destino ya estaba marcado`. Reproduced live on staging; DB state identical
(`delivery_method` unchanged). Not fixed. This is the only user-visible divergence in the feature.

## Not verified

- End-to-end for the four `ai_tool`-only nodes (impossible deterministically).
- The `…ACTUALIZADO…` (update) branches of both auto nodes; both end-to-end turns hit the create branch.
- The `ambigua` / human-handoff branch of any node.
