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
- [x] T2 Deposit target: an open operation that holds no money and is older than the completion window is not eligible in `cerebro_registrar_deposito` (`v_ex`). The rail-fit half (deposit below the rail minimum) was tried and dropped: it broke `split-deposit-minimums` case 1 (3,000 then 10,000 on Zelle); a first partial deposit must reach its recipient-first op. `deposit-reuses-recipient-first-operation.sql` unchanged and passing.
- [x] T3 Recarga intent: when the batch text asks for a recarga (`cerebro_texto_pide_recarga`) and carries Cuban mobiles, declare `recarga` and register ALL numbers; never write a `cuban_card` from a bare mobile when several mobiles are present. `Snapshot final` exposes the full `celulares` array.
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
- T2 (migration 391, staging only): new assertion `deposit-skips-stale-or-misfit-operation.sql`. RED on staging without 391 (assertion run alone through psql_staging): 4 expectation(s) failed (A stale zelle op took 12400, A2 stale op took 29000, B, E stale op won over a fresh one). Rule: in the `v_ex` lookup, an operation with no money (same definition as the 232 guard: no unlocked quoted amount, no receipt row, nothing deposited, not incident, amount not locked) is eligible only when `created_at` is inside `completar_ventana_horas`. First version also excluded rails whose minimum (`cerebro_minimo_gyd`) is above the deposit; `relacionadas` showed it breaks `split-deposit-minimums` case 1 and `deal-free-money-rules` (partial deposit below the Zelle minimum), so it was dropped and case B now asserts the partial deposit still attaches. GREEN: `staging-migracion.sh aplicar 391 ... cerebro_registrar_deposito` -> dry-run OK, apply OK, assertion OK, rollback OK (md5 equal to the 293 body on the first run; on the re-run the previous state was the first 391 version, so the md5 comparison reported the expected mismatch).
- T2 related assertions: `staging-migracion.sh relacionadas 391 'deposit|deposito|anchor|saldo|mixed|reparto|recarga|zelle|objetivo' '' --ya-aplicada ROLLBACK-391`: 202 run, 199 SAME, 3 DIFF. DIFFs: deposit-skips-stale-or-misfit-operation (RED to GREEN, expected), delivery-feed-evidence (same fixture setup error on both, only uuids differ), contexto-envio-mixto (base fails 1d, mig passes; same base failure seen in T1, not caused by 391).
- T2 commit: f69095bb.
- T2 decision (owner, 2026-11-24): keep only the age rule; no rail-minimum fit rule.
- 2026-11-24 T3 (migration 392, staging only): new assertion `recarga-text-intent.sql` (cases A-K). RED on staging without 392 (assertion alone through psql_staging): 10 expectation(s) failed (7-argument call: function does not exist; A2 only `cuban_card:55599180` was left, A3 no declaration; B/G/I no recarga numbers). GREEN: `staging-migracion.sh aplicar` -> dry-run OK, apply OK, assertion OK, rollback OK (md5 equal to previous), ACL `{postgres=X/postgres}` kept. Design: `cerebro_guardar_beneficiario_auto` gets a 7th argument `p_texto_lote` (DEFAULT NULL, the 6-argument call keeps working; the old overload is dropped). Batch asks recarga (`cerebro_texto_pide_recarga`) + Cuban mobiles + no card + promo + no open recarga: declare recarga and register ALL mobiles via `crm_registrar_numeros_recarga`; a single open unfunded remesa with phone-only recipients is converted with `_cambiar_servicio_core` (no second operation); nothing open and bot paused: only the declaration is kept (no operation opened, T1); other open operations: usual rules. More than one distinct mobile and no card never writes a cuban_card. The 268 branch also reads the batch text. `Snapshot final` already exposes `celulares` (array) and `texto_completo`, so it was NOT changed (no vendored node code, no vitest).
- T3 n8n staging (`Registrar beneficiario auto`: query `$7`, queryReplacement adds `Snapshot final.texto_completo`): backup `/home/onlinefreedom/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-a280b39c-be21-47e4-accb-9f0e9b153db6-20261124-135622.json`; versionId a280b39c -> f0c0051d, activeVersionId f0c0051d (equal), 133 nodes. Workflow never executed.
- T3 related assertions: `relacionadas 392 'recarga|beneficiar|declar|servicio|capture|reparto|zelle' '' --ya-aplicada ROLLBACK-392`: 196 run, 193 SAME, 3 DIFF: recarga-text-intent (RED to GREEN, expected), contexto-envio-mixto (base fails 1d, mig passes; same pre-existing base failure as T1/T2), delivery-feed-evidence (same fixture setup error on both, only uuids differ). recarga-negated-mention, recarga-numbers, partial-beneficiary-auto: SAME.
- T3 note: `crm_registrar_numeros_recarga` itself still opens a recarga op while paused when called by the agent tool or the 268 branch (not guarded by T1); only the new branch checks the pause.

## Open questions

- `crm_registrar_numeros_recarga` still opens a recarga op while paused when reached through the agent tool or the 268 branch (only the new 392 branch honours the pause). Symmetric T1 guard pending owner decision.

## Next step

T4 (production rollout; n8n node change `Registrar beneficiario auto` needs the same edit on production after owner go-ahead).
