# Mixed send (CUP + Zelle + recarga)

Status: IN PROGRESS (2026-10-27)

## Objective

The bot must split one verified deposit across several services (CUP, Zelle,
recarga, ...) and keep the chat coherent while it happens.

## Problem

On the 2026-10-27 23:23 test the recipients and amounts were stored correctly
(two CUP cards 19,500 CUP each, Zelle 50 USD), but:

- `repartir_envio` was never called. The whole 26,000 GYD stayed on the Zelle
  operation and the CUP operation stayed at 0 GYD / `collecting_information`,
  with no mixed group.
- The Decisor context contradicted itself: "EL DEPOSITO YA ESTA HECHO" next to
  "su deposito TODAVIA NO HA LLEGADO", because the open send was chosen as the
  most recent operation (the empty CUP one). The agent ended asking the customer
  to deposit again.

## Fix (live in production, versionId ec8f3af0, Decisor 747db79b)

1. `Historial contacto`, `abierto` CTE: choose the open operation by state
   priority (`ready_to_transfer` > `incident` > `deposit_verification` >
   amount > 0 > empty), then by date. Verified on the failing conversation:
   before it picked the CUP operation (0 GYD); after it picks the Zelle
   operation (26,000 GYD, `ready_to_transfer`).
2. `Decisor`, `g82NotaReparto`: when the reparto also carries Zelle, the note
   now says `registrar_reparto_multiple` only stores the CUP cards and does not
   split the deposit, and instructs the agent to call `repartir_envio` with all
   parts in GYD (e.g. `cup 13000, zelle 13000`).

## Pending

- Retest the mixed send with the corrected Decisor (30 s window, receipt
  `20404215436140` freed, test number wiped).

## Mix migration 337 (2026-10-28)

The 00:08 test called `repartir_envio` correctly, but the split created a
second CUP operation: `registrar_reparto_multiple` leaves `delivery_method`
NULL, so `cerebro_riel_op()` resolved the card-reparto operation's rail from
its first beneficiary (`multiple_distribution`) and `_repartir_envio_core` did
not recognise it as the `cuban_card` part. The cards stayed on the 0-GYD
operation.

`337_reparto_reusa_multiple_distribution` makes the split reuse an operation
whose rail is `multiple_distribution` for the `cuban_card` part.

- Staging: dry-run / apply / assertion / rollback OK.
- Production: `previa` EQUAL, VEREDICTO SEGURO; applied as
  `337_reparto_reusa_multiple_distribution` (version 20261028001748);
  `verificar` 1/1 iguales.

## Destination total per part (migration 338, 2026-10-28)

After 337 the mixed send stored two grouped operations of 13,000 GYD each and
the cards on the funded CUP operation, but that operation's
`quoted_destination_amount` and `destination_currency` stayed empty.

`338_reparto_destino_parte`: when every vigente recipient of a part has an
amount and they share one currency, the split writes their sum as the part's
destination (never over an admin lock). The CUP part now shows **39,000 CUP**;
the Zelle part keeps its 50 USD.

- Staging: dry-run / apply / assertion / rollback OK.
- Production: `previa` EQUAL, VEREDICTO SEGURO; applied as
  `338_reparto_destino_parte` (version 20261028003839); `verificar` 1/1.

## Recarga in a mixed send (2026-10-28)

The recarga test left the CUP operation with 15,000 CUP and no card: the agent
registered the recarga number before the split, and `crm_registrar_numeros_recarga`
converted the funded CUP operation to recarga, retiring the card; the split then
created a new CUP operation without it.

Two fixes:

1. Prompt: in a mixed send, call `repartir_envio` FIRST, then register each
   service's data (`versionId` `9633b9c1`).
2. `339_recarga_no_retira_otro_servicio`: a funded operation that already has a
   vigente recipient of another service is not converted to recarga; the recarga
   becomes its own part. A plain funded operation still converts as before.

- Staging: dry-run / apply / assertion / rollback OK.
- Production: `previa` EQUAL, VEREDICTO SEGURO; applied as
  `339_recarga_no_retira_otro_servicio` (version 20261028005847); `verificar` 1/1.

A temporary `promo_etecsa` row (PRUEBA TECNICA RECARGA 2026-10-28, 600–1,250 CUP,
x5, 6,200 GYD) is active only for the test day and must be removed when the tests
finish.

## Any probable service mix (migration 340, 2026-10-28)

Staging check: `cup + clasica + tropical + saldo` creates four grouped
operations with the right amounts and destinations. Gap found: a card reparto
saved on ONE operation with recipients of different rails (Clasica + Tropical,
or Clasica + CUP) left the second rail's recipient on the first rail's
operation, and the new operation had none.

`340_reparto_destinatarios_por_via`: after the split, the rail-typed card rows
(`multiple_distribution` -> `cuban_card`, `clasica`, `tropical`) move to the
group member of their rail; duplicates on the target are dropped; both
destinations are recomputed from the remaining recipients (releasing only the
split's own automation lock, never a human's).

Probable mixes now covered at the split level: remesa CUP, Zelle, Clasica,
Tropical, recarga, combo, efectivo USD, saldo movil. Saldo still needs an
end-to-end test of its recipient tool. Visas stay out: Odessa brings visa
documents (LC PDFs translated to English) and an operator handles them.

- Staging: dry-run / apply / assertion / rollback OK.
- Production: `previa` EQUAL, VEREDICTO SEGURO; applied as
  `340_reparto_destinatarios_por_via` (version 20261028012401); `verificar` 1/1.

## One service, several recipients, any mix (341 + 342, 2026-10-28)

- `341_servicio_por_monto`: the amount, not the word, separates a recarga from
  a saldo movil (`cerebro_servicio_por_monto`: recarga word + a saldo multiple
  below the recarga minimum -> saldo; the reverse for a recarga multiple). Used
  by `cerebro_cambiar_servicio` and `crm_registrar_numeros_recarga`. A card,
  Zelle, cash or Mexico recipient keeps the word: a 5,000 GYD CUP remesa is
  never read as five saldo packages. A saldo's package count is the max number
  of phones. Applied `20261028015852`, `verificar` 3/3.
- `342_efectivo_multiples`: `crm_registrar_datos_entrega_efectivo` takes an
  optional `p_posicion` and `p_monto`; one cash recipient per position (default
  1 = old behaviour), each with its own USD amount and completeness notice. The
  old 5-arg overload is dropped so 5-arg callers use the new defaults. Applied
  `20261028020155`; the file verifier reports 0/0 because of the overload drop,
  checked directly in production: 7-arg signature, ACL owner+service_role.
- The workflow (`77594df6`, 128 nodes) adds `registrar_destinatario_mexico`
  (cloned from the Oct-27 copy, production credential) and gives the cash tool
  `numero`/`monto`; the prompt documents both.

Data may arrive in any order: every tool accepts partial data and one call per
recipient, the split reuses or creates each service's operation, 339 stops a
recarga from retiring another service's recipient, and 340 moves each card row
to its own rail after the split.

## Cleanup before the next tests (2026-10-28)

- The temporary promo (`50f83081`, PRUEBA TECNICA RECARGA) is `descartada`;
  `promo_etecsa` has no promotion active today in Guyana.
- Receipt `20404215436140` is back with its owner: `consumido_en`
  2026-10-26 21:34:21.557545, operation `7c0920e3`, `case_deposits` link to
  `7b723df9`, `linked_by = automation:cruce_deposito`.
- Receipt `10400059469195` (1,000 GYD) stays FREE for the saldo movil test, and
  its image hash (`COMP-5589561ba49133cee02f`) was deleted so the image counts
  as new instead of a silent resend. After the tests: restore the deposit
  (`recibido_en` 2026-09-08 19:07:24, `consumido_en` 2026-09-08 19:09:02.041989)
  and reinsert the hash row with its original values (kept in the audit row).
- The test number has no contact, conversations, messages, session events or
  hashes left. Recarga prices (500 -> 5,200; 600 -> 6,200) are untouched.
