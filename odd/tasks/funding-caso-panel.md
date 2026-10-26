# Phase 4a: funding case in the panel

Status: IN PROGRESS (2026-10-26). Objective: the operator can see the funding case of the open
conversation — verified, assigned and available GYD, the linked deposits, the allocations and the
incident note — and can resolve an incident after fixing the data. This is the first increment of
phase 4; bot wording, the staging simulator and brevity follow.

## Why

Phase 3 now blocks a delivery when the case is in incident, but neither the panel nor the bot shows
why. An operator sees a failed delivery and no place to fix it. The case is the money's home; the
panel must show it.

## Scope

In scope:
- `funding_caso_panel(p_conversation)` (SECURITY DEFINER, membership `viewer`): the active case (or
  the latest closed one) with its amounts, deposits and allocations.
- `funding_caso_resolver_panel(p_case)` (SECURITY DEFINER, membership `agent`): clears the incident
  and runs `funding_reconciliar` again.
- `GET /api/funding-case?conversationId=` and `POST /api/funding-case/{caseId}/resolve`.
- `FundingCaseBlock` in the contact sidebar, with a status badge, the three amounts, the deposits, the
  allocations and the resolve button. Spanish/English messages.
- SQL assertion + component test.

Out of scope (next increments): assigning/releasing/refunding from the panel, the bot's conflict
message, the webhook simulator, and the conversational brevity work.

## Rules

- The RPCs are the only new data path; they check `is_account_member` themselves, so a direct RPC
  call cannot bypass the route.
- The panel is read-only except for resolving an incident. It does not create allocations or edit
  deposits.
- A resolver clears the incident only for the case; the next reconciliation re-evaluates the data. If
  the conflict persists, the case returns to incident.
- The block renders only when a case exists; no empty panel.

## Tasks

- [x] T1. SQL assertion `funding-caso-panel.sql` with RED on the staging base.
- [x] T2. Migration 332 with the two panel RPCs, grants and comments.
- [x] T3. Staging cycle.
- [x] T4. API routes and the `FundingCaseBlock` component; component test.
- [x] T5. `npm run test`, `npm run typecheck`, `npm run lint` (or the repo's equivalents).
- [ ] T6. Production `previa 332`; report; wait for the go-ahead.
- [ ] T7. Apply 332 and publish the panel (load `wacrm-publicar-panel`); update docs/memory.

## Verification

- SQL: `infra/db/staging-migracion.sh aplicar supabase/migrations/332_funding_caso_panel.sql
  supabase/staging/assertions/funding-caso-panel.sql
  supabase/migrations/ROLLBACK-332-funding-caso-panel.sql
  funding_caso_panel,funding_caso_resolver_panel`
- UI: `npm run test -- src/components/inbox/operations/funding-case-block.test.tsx` (or the vitest
  filter the repo uses) + `npm run typecheck`.
- Production: `previa` → approval → `aplicar` → `verificar`; panel publish follows its own skill.

## Decisions

- The panel reads through API routes with the caller's session, matching the operations panel.
- The case block lives in the contact sidebar next to the operations panel; it is conversation-level,
  so a mixed group shows one block, not one per operation.
- `viewer` can read; `agent` can resolve. The RPC repeats both checks.

## Evidence

- T1 (2026-10-26): RED on the staging base: `function funding_caso_panel(uuid) does not exist`.
- T3 (2026-10-26): `dry-run OK`, `apply OK`, `assertion OK`, `rollback OK (md5 igual al previo)`.
  Functions: `funding_caso_panel d08f566137b1`, `funding_caso_resolver_panel b0cab90e913a`,
  both granted to `authenticated` and `service_role`.
- T4/T5 (2026-10-26): `funding-case-block.test.tsx` 2/2 passed; `npm run typecheck` clean;
  `messages-parity` 4/4 passed; eslint on the new files reports only the two pre-existing warnings in
  `contact-sidebar.tsx` (unused `User` import and an unused eslint-disable directive).
