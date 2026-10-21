---
name: wacrm-corregir-produccion
description: "Trigger: corregir operación, corregir datos, arreglar en producción, cliente mal registrado, calculadora mal. Correct WaCRM production data with one audited atomic SQL block via correccion-produccion.sh."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when the owner asks to correct wrong data already in production: an operation, a beneficiary, a calculator line, a manual close, a CUP lot balance. Schema changes are NOT corrections: they go through `wacrm-migraciones`.

## Hard Rules

- Investigate first with `wacrm-investigar-conversacion`. State the facts and the exact change to the owner, then wait for an explicit go-ahead. Earlier approvals do not carry over.
- One correction = one file = one atomic `DO $$ ... $$;` block (template: `assets/plantilla-correccion.sql`).
- The block re-checks the expected current state first; on mismatch it RAISEs, so nothing is applied.
- The block sets `set_config('wacrm.origin','admin',true)` and `set_config('wacrm.actor','claude-code:owner-request',true)`.
- Every changed row gets a `remittance_admin_audit` row: action `human_correction` (or `human_manual_close` for a manual close), actor `claude-code:owner-request`, reason with the owner's words and date, `before`/`after` jsonb.
- Completed calculator lines are append-only: follow `references/correcciones.md`, never UPDATE their figures in place.
- Never message the customer unless the owner asks.
- Never schema changes, DROP, TRUNCATE. The script refuses them.
- Run only `infra/db/correccion-produccion.sh <file.sql> --confirmar`, and only after the go-ahead. Never print or pass the token.
- Do not guess ids: take them from the investigation output.

## Decision Gates

| Situation | Action |
|---|---|
| Owner has not confirmed the exact change | Stop; show facts and change; wait |
| Re-check RAISEs (state changed) | Stop; re-investigate; do not force |
| API error from the script | Stop; report the message; do not retry blindly |
| Amount/basis of a completed calculator line | Void + `calculator_feed_operation` (reference) |
| CUP lot balance | `crm_ajustar_saldo_cup` first; direct lot UPDATE only as last resort, audited |

## Execution Steps

1. Investigate (`wacrm-investigar-conversacion`); list ids, current values, audit history.
2. Write the change file from the template to a scratch file outside the repo; fill re-check values and new values.
3. Report facts + exact change to the owner; wait for go-ahead.
4. `infra/db/correccion-produccion.sh <file.sql> --confirmar`.
5. Read back with the verification query in the template; compare with the intended values.
6. Record in engram (ids and values only, no customer text).

## Output Contract

Return: change summary (ids, before -> after), script result line, verification query result, audit row ids, and any refused check. Never include the token or customer messages.

## References

- `references/correcciones.md`: recipes and production facts (void+refeed, destination, silent close, mixed send, CUP lots, system-saved sources).
- `assets/plantilla-correccion.sql`: the commented atomic DO template.
