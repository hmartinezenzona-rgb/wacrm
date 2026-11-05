# The card beneficiary tool must not open a card operation on a cash send

## Problem (production, 2026-11-05)

Conversation 1232671b: a cash USD operation e976e1fc (`delivery_method = efectivo_usd`) was open. The Decisor added
card-oriented notes ("Falta la tarjeta ... llama gestionar_beneficiario con el celular y pide la tarjeta") and the agent
called the n8n tool `gestionar_beneficiario(nombre, tarjeta = '', celular)` (execution 648684). The SQL behind the tool
created a NEW operation 16a90b56 (no delivery_method, cuban_card beneficiary) and answered "FALTA: la tarjeta", so the bot
asked the customer for a card number. The data was corrected by hand (audits 53e64ad1, e01031ea).

## Owner decision

2026-11-05: fix it only in the database tool ("haz el arreglo solo en la herramienta de la base de datos"); the Decisor
file is NOT touched (it holds another session's uncommitted changes).

## Scope

- T1 Migration 353 (staging first): in the SQL function the `gestionar_beneficiario` tool calls (find it in the n8n
  snapshots under `infra/n8n/snapshots/` and in `supabase/migrations/`; read the live body with `pg_get_functiondef`),
  when the call carries NO card and the conversation has an open (not completed/cancelled) cash operation
  (`delivery_method = 'efectivo_usd'`, or the cash rail by whatever the function uses to decide the rail):
  - do NOT create a new operation and do NOT add a cuban_card beneficiary;
  - save the given name and phone on that cash operation's live beneficiary only where they are empty (never overwrite
    a value a person or the carnet flow set), with the same audit style the cash data flow uses;
  - answer the agent in the same output format the tool uses today, saying it is a cash send, what was saved, what is
    still missing for cash (name, address, carnet photo — whichever is empty) and, explicitly, "NO pidas tarjeta: es
    entrega en efectivo".
  Every other case (a card given, no cash operation open, recharges) behaves exactly as today.
- T2 Production: previa, apply, verify after the owner's go-ahead.

## Constraints

- Do not touch `pruebas/decisor/*` or `odd/tasks/bot-brevedad.md` (another session's uncommitted files).
- No n8n changes. No real customer data in tests, fixtures or commits.
- Migration rules: staging first; ROLLBACK file; self-reverting assertion ending `ALL PASS (rolled back on purpose)`.

## TDD

Strict, on. The staging assertion is the test (RED before the migration).

## Tasks

- [ ] T1 Migration 353 on staging: no stray card operation on a cash send.
- [ ] T2 Production after the owner's go-ahead.

## Progress

- 2026-11-05 created. RDD off.
