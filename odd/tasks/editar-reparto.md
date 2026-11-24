# Edit a multi-recipient split in one step ("Editar reparto")

Status: in progress · Branch: feat/port-chat-operations-calculator · Worktree: wacrm-worktrees/mejora-legacy · 2026-11-24

## Objective

Let an operator correct a badly captured multiple transfer (an operation whose payment is split among several recipients) in one atomic, audited save from the operation card.

## Problem

Requested by the owner (feature #1 of 2026-11-24, asked by Osmany). Today the panel only edits shares one by one (`crm_corregir_beneficiario`, `crm_agregar_beneficiario`, `crm_quitar_beneficiario`):

1. Nothing checks that the shares add up to the operation total; an edited share silently desyncs from `quoted_destination_amount`.
2. Changing N amounts takes N saves; the split is inconsistent in between.
3. A split cannot be built from scratch (`multiple_distribution` is excluded from `ADDABLE_BENEFICIARY_TYPES`, `beneficiary-add-control.tsx:43`).

## Scope

- One RPC that replaces all current card shares of an operation atomically (keep / edit / add / remove), with the sum check, audit and the `beneficiaries` admin lock.
- One API route and an "Editar reparto" form on the operation card: all shares in a table, add/remove rows, live sum vs total, save once.
- Open operations; closed operations for owner/admin (same rule as migration 383).

Out of scope (later): re-splitting closed mixed groups, feeding the calculator after a closed edit, CUP <-> USD change with several shares.

## Rules (decided)

- Save only when the sum of the share amounts equals the operation's destination total exactly; otherwise refuse with the difference. The total itself is corrected first with the existing operation correction form.
- Replaced rows are retired (`reemplazado`), never updated in place; new rows `source='admin_correction'`, `amount_origin='manual'` (same as 383).

## TDD

Mode: strict, on (global CLAUDE.md). Runners: SQL assertions via `infra/db/staging-migracion.sh` (`supabase/staging/assertions/`); panel `npx vitest run src/components/inbox/operations` and `npx tsc --noEmit`.

## Tasks

- [x] T1 SQL: `crm_editar_reparto(p_operation_id, p_partes jsonb)` atomic replace with sum check, closed-op role rule, audit, lock. Migration + ROLLBACK + assertion on staging.
- [ ] T2 API route `POST /api/remittance-operations/[operationId]/reparto` + route test.
- [ ] T3 UI "Editar reparto" form on the operation card + vitest.
- [ ] T4 Staging browser check (wacrm-probar-staging) with PRUEBA fixtures and cleanup.
- [ ] T5 Production: migration (previa/aplicar/verificar) and panel publish, each with owner go-ahead.

## Acceptance criteria

- Editing 3 shares and adding 1 saves in one request; the audit shows before/after; shares sum to the total.
- A sum mismatch is refused with a clear message and nothing changes.
- Agent role cannot edit a closed operation; owner/admin can.

## Delivery

Forecast ~800-1000 authored lines over the tasks (above the ~400 heuristic). The project publishes from this branch (no PR flow); work-unit commits per task.

## Progress

- 2026-11-24: mapped current editing (panel-fully-editable 377-384). Scope approved by owner.
- 2026-11-24 T1: migration 394_crm_editar_reparto (+ ROLLBACK-394, assertion `supabase/staging/assertions/edit-split.sql`). RED: assertion without the migration failed `function crm_editar_reparto(uuid, jsonb) does not exist` (42883). GREEN: `staging-migracion.sh aplicar` dry-run/apply/assertion/rollback all OK (rollback md5 equal), ACL `postgres, authenticated`. `relacionadas 'beneficiar|reparto|closed|correct|recipient' --ya-aplicada ROLLBACK-394`: 190 assertions, 188 SAME, 2 DIFF: edit-split (expected, base lacks the function) and delivery (same fixture error on both sides, only a short deal id differs). Zelle excluded (not a card rail); non-card recipients on the operation are refused. Commit: see git log (feat(operations): add crm_editar_reparto).
- 2026-11-24 T1 amendment (394 amended in place, not in production): after the sum check the operation's `quoted_destination_origin` becomes 'manual' and `admin_locked_fields.quoted_destination_amount` is set, so a later share touch cannot clear the validated total; audit before/after are now objects `{shares, quoted_destination_amount, quoted_destination_origin}`. RED: new case 5 failed against the applied 394 (origin stayed 'calculated', no lock). GREEN: assertion ALL PASS with the amended file; `aplicar` dry-run/apply/assertion OK; rollback step FAIL on md5 only because staging already held the previous 394 body (the rollback drops the function; the pre-migration md5 was the old function, not absence), not a defect of the rollback. `relacionadas`: 190, 188 SAME, 2 DIFF (edit-split expected, delivery-feed-evidence known fixture noise). `authenticated` only, no service_role (owner decision).

## Next step

T2 (API route).
