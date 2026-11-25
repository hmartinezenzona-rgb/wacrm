# Reseller chats without the Admin tag: silence outside receipts

Status: in progress · Branch: feat/port-chat-operations-calculator · Worktree: wacrm-worktrees/mejora-legacy · 2026-11-25

## Objective

Let the three reseller contacts work without the `Admin` tag: a receipt is handled by the
deterministic reseller route, and anything else from a reseller gets NO customer script.

## Problem

After the 398 cutover no reseller could reach the reseller route. Verified in production
(n8n execution 846913, conversation d1838d87): `Contexto conversacion` returned
`es_revendedor=true` AND `es_admin=true`; `rutaRevendedorDeposito` bails on `ctx.es_admin`, and
`cerebro_registrar_deposito_si_cliente` checks the admin tag first and returns
`(NULL,'verificacion_admin',false,false)`. All three reseller contacts carry both tags.

Owner decision (2026-11-25): remove the `Admin` tag from the three contacts, and make a tagged
reseller get only what a reseller needs — never the customer script.

## Scope

- Decisor: after the guards and the admin branch, a reseller turn with no receipt returns
  `silencio` with motive `mensaje de revendedor sin comprobante`.
- Production data: remove the `Admin` tag from contacts 0f7ff89d, 3f2c9f90, f5b89f66 (audited).
- Out of scope: a deterministic "cuánto llevo" reply for resellers; no SQL change needed (the
  wrapper's admin precedence stays as designed for genuinely admin-tagged contacts).

## Constraints

- Strict TDD: vitest RED before the Decisor edit, GREEN after; update the md5 pin in
  `pruebas/decisor/correr.ts`.
- Staging first; production n8n publish only with an explicit go-ahead.
- Publish the Decisor BEFORE removing the tags, so no reseller falls into the customer model
  in the window between the two changes.
- Tag removal goes through `infra/db/correccion-produccion.sh` in one atomic audited block.

## TDD

Mode: strict, on (global CLAUDE.md). Runner: `npx vitest run pruebas/decisor`.

## Tasks

- [x] T1 Decisor: silence for a reseller turn without a receipt + tests (RED then GREEN) + md5 pin.
- [x] T2 Publish the Decisor to staging and verify md5/versionId.
- [x] T3 Production: publish the Decisor (owner go-ahead) and remove the Admin tag from the three resellers, audited.
- [ ] T4 Verify in production: a reseller's non-receipt message silences, a receipt creates a claim and sums.

## Acceptance criteria

- `npx vitest run pruebas/decisor` green; the new case asserts silence and its motive.
- A reseller with a receipt still gets the deterministic reseller text.
- No reseller contact keeps the Admin tag; the audit rows exist.
- The next real reseller receipt creates `reseller_deposits` and raises his total.

## Delivery

Forecast ~120 authored lines (code + tests + data block). Below the 400 heuristic.

## Progress

- 2026-11-25: production diagnosis (execution 846913) and owner decision recorded.
- 2026-11-25 T1 (cb041cb7): RED `npx vitest run pruebas/decisor/decisor-revendedor.test.ts` 1 failed
  (reseller without receipt returned `agente`), GREEN 33 passed; full `npx vitest run pruebas/decisor`
  271 passed. Decisor md5 df39af34 -> d6cf190e1403583607fbeb395850a393; pin updated.
- 2026-11-25 T2: staging backup not needed for a code-only publish; `publicar-decisor staging
  --esperado df39af34` -> versionId dd120b4f-8403-49c1-8cfa-5986a4cee186, activeVersionId equal,
  133 nodes, md5 d6cf190e, repo_md5_match yes. Workflow never executed.
- 2026-11-25 T3 (owner go-ahead): production backup
  `cerebro-fase1/respaldos-n8n/produccion-jEzlVLCLUaJhVwzs-67395da1-...-20261125-102847.json`;
  `publicar-decisor produccion --esperado df39af34` -> versionId
  f05eabd8-55bb-4410-9877-b06fc65394d8, activeVersionId equal, 126 nodes, md5 d6cf190e, repo match.
  Tag removal via `correccion-produccion.sh` (atomic block): 3 contact_tags rows deleted and 3
  `human_correction` audit rows written (e33c1c3a, f81e8ad1, f1edfcd3). Verified: Emilio and Brayan
  keep only Revendedor, Osmany Services keeps Nuevo + Revendedor; Admin tag usage drops 6 -> 3.
- T4 pending: needs a real reseller receipt in production (claim + total) and a non-receipt message
  (silence, no customer reply).

## Next step

T1.
