# Pause without reason expires after 5 minutes

Branch `feat/port-chat-operations-calculator`, worktree `mejora-legacy`.

## Objective

A bot pause with no handoff reason (the panel's pause / "take over" toggle) expires after
`pausa_humana_caduca_minutos` (5) without human activity, exactly like the `agent_replied` pause.
Owner request 2026-11-20; it reverses the owner decision of 2026-09-06 ("the manual pause never expires").

## Problem

`cerebro_caducar_pausa_humana` (cron `caducar-pausas-humanas` every minute, and the Decisor's
"Contexto conversacion") only releases `ai_handoff_reason = 'agent_replied'`. A pause with NULL reason
stays forever. On 2026-11-20, 13 production conversations were paused with NULL reason, some since September.

## Scope

- Keep never-expiring: any non-NULL reason other than `agent_replied` (`abuso`, `solicitud_cliente`, bot
  derivations) and the bot-derivation assignment (profile 377b0c8c).
- The panel pause sets `ai_handoff_at = now()` (it set nothing), so the 5 minutes count from the click and
  the cron does not release a fresh pause on its next tick.
- Functions: `cerebro_caducar_pausa_humana`, `cerebro_caducar_pausas_humanas`, `cerebro_humano_atendiendo`.

## Constraints

- Order in production: app first (harmless alone), then migration 385.
- On apply, the 11 old NULL-reason pauses without assignment are released at once (bot answers the next
  customer message there); the 2 with a bot derivation stay silent through the assignment.
- TDD: strict, vitest for the app, self-reverting SQL assertion for the migration.

## Tasks

- [ ] T1 Panel pause stamps `ai_handoff_at` (route `src/app/api/ai/autoreply/[conversationId]/route.ts` + test).
- [ ] T2 Migration 385 + ROLLBACK + assertion; staging cycle all OK.
- [ ] T3 Publish the panel (owner go-ahead).
- [ ] T4 Apply 385 in production (owner go-ahead), `verificar` n/n.

## Checks

- `npx vitest run src/app/api/ai/autoreply`, `npx tsc --noEmit`.
- `infra/db/staging-migracion.sh aplicar ...`, `relacionadas`, `produccion-migracion.sh previa/aplicar/verificar`.

## Progress

(empty)
