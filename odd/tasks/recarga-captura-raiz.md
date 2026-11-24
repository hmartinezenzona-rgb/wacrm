# Recarga captured as remesa on a stale operation (root-cause fix)

Status: in progress · Branch: feat/port-chat-operations-calculator · Worktree: wacrm-worktrees/mejora-legacy · 2026-11-24

## Objective

Stop the capture pipeline from (1) opening a new operation when the customer only corrects data of an already-closed send, (2) attaching a new deposit to a stale or service-incompatible operation, and (3) recording a "recarga + several Cuban mobiles" message as a single `cuban_card` recipient.

## Problem

Production case 2026-11-24, conversation d55cd36b, operation 2d47fe87 (corrected by hand the same day; audit rows `human_correction` 16:08 UTC). Second case of the same class after conversation 1232671b (2026-10-22). Evidence from n8n executions 830297, 838255, 838309.

1. `cerebro_guardar_zelle` -> `cerebro_escribir_bloque_beneficiario` opened a remesa (`recipient_writer`) for a Zelle number correction. `cerebro_guardia_envio_nuevo` only protects sends completed within `envio_completado_ventana_horas` (6 h, `360:38`); the closed send was ~53 h old. In capture mode (bot paused, `ruta=agente, captura=true`) the agent tool can still open operations.
2. `cerebro_registrar_deposito` (`293`, `v_ex` branch) picks the newest open unfunded operation with no age or service-fit check; a 12400 GYD deposit (2 x recarga) joined an unfunded Zelle-rail operation (minimum 13000).
3. No deterministic path registers recharge numbers: `cerebro_guardar_beneficiario_auto` (`268`) needs an open recarga op or a declared service; `cerebro_texto_pide_recarga` (`248`) is informational only. `Snapshot final` keeps only `celulares[0]` (line 104), so the second number is always lost.

## Why

Wrong operations and recipients in production need manual correction and risk paying the wrong rail.

## Scope

- Supabase migrations (390+) with ROLLBACK and self-reverting assertions, staging first.
- n8n Cerebro nodes `Snapshot final` and `Registrar beneficiario auto` (staging first, production after owner go-ahead).
- No panel changes. No customer messaging.

## Constraints

- Strict TDD: assertion RED on staging before the fix, GREEN after.
- Production writes (migrations and n8n) only with an explicit owner go-ahead per step.
- Never execute the staging or production n8n workflow.

## TDD

Mode: strict, on. Source: global CLAUDE.md ("Strict TDD Mode: enabled"). Runner: `infra/db/staging-migracion.sh aplicar <mig> <assertion> <rollback> <fns>` (assertions in `supabase/staging/assertions/`, ending `ALL PASS (rolled back on purpose)`); `npx vitest run pruebas/...` for vendored node code.

## Tasks

- [x] T1 Writer never opens an operation to hold data that matches a recipient of a closed send of the conversation (no time window), and never opens one in capture / paused mode. Functions: `cerebro_guardia_envio_nuevo`, `cerebro_escribir_bloque_beneficiario`.
- [ ] T2 Deposit target: an open operation that holds no money and is older than the completion window, or whose rail does not fit the deposit amount (`cerebro_servicio_por_monto`), is not eligible in `cerebro_registrar_deposito` (`v_ex`). Review `deposit-reuses-recipient-first-operation.sql`.
- [ ] T3 Recarga intent: when the batch text asks for a recarga (`cerebro_texto_pide_recarga`) and carries Cuban mobiles, declare `recarga` and register ALL numbers; never write a `cuban_card` from a bare mobile when several mobiles are present. `Snapshot final` exposes the full `celulares` array.
- [ ] T4 Production rollout: `previa`, owner go-ahead, `aplicar`, `verificar`; n8n nodes after go-ahead.

## Acceptance criteria

- Replaying the three d55cd36b situations on staging assertions: no op opened on the correction, deposit not attached to the stale op, two recarga recipients registered.
- Existing related assertions stay green (`staging-migracion.sh relacionadas`).

## Progress

- 2026-11-24: production data corrected (op 2d47fe87 -> recarga x2). Root cause mapped. Owner approved the three fixes.
- 2026-11-24 T1 (migration 390, staging only): new assertion `capture-closed-send-guard.sql`. RED on staging without 390 (assertion run alone through psql_staging): 11 expectation(s) failed (1a-1f closed-send corrections opened a send, 5a-5d paused opened a send, 6b visa+paused opened a remesa). GREEN: `staging-migracion.sh aplicar 390 ... cerebro_guardia_envio_nuevo,cerebro_escribir_bloque_beneficiario` -> dry-run OK, apply OK, assertion OK, rollback OK (md5 equal to previous). Design: `_cerebro_conversacion_pausada` reads `conversations.ai_autoreply_disabled` (the Decisor's `bot_pausado`); guard refuses when paused and rule A is window-free over completed and cancelled sends; rule B stays windowed; the writer raises instead of creating an op while paused.
- T1 related assertions: `staging-migracion.sh relacionadas 390 'ghost|zelle|capture|beneficiar|guard|reparto|recarga|card' '' --ya-aplicada ROLLBACK-390`: 217 run, 213 SAME, 4 DIFF; ghost-operations-guard, zelle-history-guard, silent-capture, partial-beneficiary-auto all end ALL PASS. DIFFs: capture-closed-send-guard (RED to GREEN, expected), ghost-operations-guard (base now fails only on updated case 3d, see below), contexto-envio-mixto (base failed 1d, mig passes), delivery-feed-evidence (same fixture error on both, only uuids differ).
- T1 commit: aab3f38a.
- T1 assertion change: ghost-operations-guard case 3d encoded the old windowed rule A (same account as a send completed 7 h ago opened a new op); it now expects the refusal, which is the new required behaviour.

## Next step

T2.
