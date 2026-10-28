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
