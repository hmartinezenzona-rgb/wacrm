# Zelle: multiple recipients on the Oct-19 copy

Status: IN PROGRESS (2026-10-27)

## Objective

Make the restored Oct-19 Cerebro register every Zelle recipient the customer
gives, each with its own name, account and USD amount, instead of keeping only
the last one with the whole operation amount.

## Problem

`registrar_beneficiario_zelle` on the Oct-19 copy calls
`cerebro_guardar_zelle($1,$2,$3,$4)` — the single-recipient shape. With two
accounts the agent registers the last one and the function assigns the full
destination amount (100 USD). The first account is lost.

The database already has the multi-recipient signature
(`cerebro_guardar_zelle(p_conv,p_nombre,p_cuenta,p_exec,p_op,p_tool,p_posicion,p_agregar,p_monto)`),
so no migration is needed.

## Scope

In scope:
- Replace the tool node's query, `queryReplacement` and `toolDescription` with
  the multi-recipient version that already exists in the Oct-27 workflow.
- Disable `Registrar zelle auto` so the single-block reader does not overwrite
  or duplicate what the agent registers.
- Add the multi-recipient instruction to the agent prompt.

Out of scope:
- The other readers (`Registrar beneficiario auto`, `Registrar destino auto`).
- The Decisor.
- Any database change.

## Tasks

- [x] T1 Patch the live Oct-19 workflow: tool node, Zelle reader disabled, prompt instruction.
- [x] T2 Verify versionId == activeVersionId, node count unchanged, readers state.
- [x] T3 Free the receipt and confirm the test number is clean.
- [x] T4 Owner runs the two-account test; analyse the result.

## Result (2026-10-27)

Test passed. Operation `114a3ff9` (26,000 GYD, `ready_to_transfer`) stored two
active Zelle recipients: Allan MULTICERVICE / 8132940493 / 50 USD and YLT
WHOLESALE FOODS LLC / 9544253182 / 50 USD. The chat confirmed exactly those two
accounts and amounts. One replaced row for Allan remains as version history, no
active duplicate.

Open point: `quoted_destination_amount` stayed NULL because the agent did not
call `calcular_usd_desde_gyd` in this run; the two recipients sum to 100 USD.

Cleanup: receipt `20404215436140` restored to operation `7c0920e3` and case
`7b723df9`; test operation, case, conversation, contact, session events and
dedup hash removed.

## Amount guard (migration 335, 2026-10-27)

`cerebro_guardar_zelle` only checked `monto > 0`: 50 + 60 on a 26,000 GYD
deposit (100 USD) was stored silently. Migration
`335_zelle_amounts_within_deposit` adds the missing check: once every vigente
recipient has an amount, their sum is compared with the cap (agreed GYD converted
with the Zelle tiers, falling back to the verified deposit, tightened by
`quoted_destination_amount`). Over the cap it returns `NO SE GUARDO NADA ...`
and writes nothing; a partial split below the cap stays allowed.

- Staging: dry-run / apply / assertion / rollback all OK; rollback md5 equal.
- Production: `previa` EQUAL, VEREDICTO SEGURO; applied as
  `335_zelle_amounts_within_deposit` (version 20261027215928); `verificar`
  1/1 iguales.

## Acceptance criteria

- Two Zelle recipients stored, each with its own account and amount.
- No duplicate or overwritten beneficiary from the reader.
- Chat confirmation matches the stored data.

## Checks

- `estado produccion` after the write.
- Postgres read-back of `remittance_beneficiaries` for the test operation.
