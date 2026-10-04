# Feature: food combos end to end (bot, panel, calculator)

## Objective
A customer orders one or more food combos for Cuba in WhatsApp. The bot opens a combo operation, collects each
recipient's data and amount, and files the MMG payment on the combo. The panel shows the combo with its data. The
admin enters the combo's cost and marks it completed when it is sent; the customer gets a "your combo was sent"
notice, and the calculator shows its profit.

## Problem (2026-10-04)
- Combos are informational only: cerebro_servicios 'combos' says the bot "NO gestiona todavia el pago" and hands off.
  A combo receipt would be filed as a remesa.
- Production has 0 combo operations (590 remesa, 23 recarga); 9 conversations mentioned combos in the last 30 days.
  On 2026-09-05 a customer with the money ready was handed to a person.
- The calculator has no COMBO service (combos fall in the manual DIRECTO bucket), and no combo has ever reached it.
- remittance_operations.service_type already allows 'combo' (046).

## Business rules (Osmany, docs/negocio/RESPUESTAS-OSMANY-servicios.md, and the owner, 2026-10-04)
- Minimum 25,000 GYD per combo. Made to order from stock, not a closed catalog
  (https://bit.ly/combosmuestra is only a sample). Same price for all Cuba, delivery included.
- Paid fully in advance by MMG; the products are chosen later, in a call with staff.
- Recipient data: full name, phone, address (as complete as possible), a reference for how to get there, and a second
  contact phone.
- Delivery times: Habana/Artemisa/Mayabeque 3–5 days; Pinar del Rio/Matanzas 5–7; Cienfuegos/Villa Clara 7–10; the
  rest 10–15.
- Owner decisions:
  1. The calculator profit uses a cost the admin enters by hand; the line stays pending until then.
  2. The bot collects everything, as with recharges: amount, payment, and the five recipient fields.
  3. Several combos go in ONE operation with several recipients, as with recharges.
  4. The bot asks how much is for each recipient and checks that each combo reaches 25,000 GYD.
  5. A combo is completed when it is sent. The customer notice says it was sent and the delivery time for the
     province.
- Defaults chosen by Claude (stated to the owner, open to change):
  - The cost is entered in GYD, one total per operation, in a new panel field.
  - The calculator service is COMBO: facturado = the deposit, invertido = the entered cost.
  - The deposit goes to the combo the same way it goes to a recharge: the customer talked about a combo, or a combo
    is already open.

## Scope
- DB (staging first):
  - combo beneficiary type and fields: per-recipient amount, reference, second contact phone;
  - open/save tool function for the agent; completeness rule; deposit routing;
  - panel RPCs (list, add recipient, manual close picker);
  - cost field; calculator COMBO feed (pending until cost);
  - cerebro_servicios 'combos' text without "NO gestiona el pago".
- Panel UI: the combo card with its fields, the add-recipient form, the service picker, the cost entry.
- Calculator: the COMBO service in rates/types where needed.
- Cerebro (n8n, gate script): the agent tool; Decisor notes while a combo is open; the verified-deposit line.
- Notifier (n8n): the completion message for a combo.
- Production after the owner's go-ahead.

## TDD
Strict (global CLAUDE.md). DB: SQL assertions (self-reverting DO block ending in RAISE EXCEPTION 'ALL PASS'). App:
vitest (`npm test`). Cerebro/notifier: dry run + `node --check` of the edited code + an offline run of the edited
logic where feasible.

## Tasks
- [ ] T1 DB `208_combo_model.sql` (+ ROLLBACK, assertion combo-model.sql): beneficiary type and columns, open/save
      function, completeness, deposit routing, panel RPCs, cost field, calculator COMBO feed, service text. Apply to
      staging; neighbour assertions re-run.
- [ ] T2 Panel UI + calculator UI (vitest), staging app deploy.
- [ ] T3 Cerebro gate106 (staging): agent tool registrar_combo, Decisor notes, verified line.
- [ ] T4 Notifier: combo completion message (staging).
- [ ] T5 Owner test on staging.
- [ ] T6 Production after the go-ahead.

## Delivery
Work-unit commits on feat/port-chat-operations-calculator (the branch the deployments are built from). The forecast
is well over ~400 authored lines; per the existing practice on this branch, each task is a reviewable work unit and
production goes per task after the owner's test.

## Progress
- T1a (commit b7b721d, staging): 208_combo_model.
  - Data model:
    - remittance_beneficiaries gets 'combo' type, `reference` and `contact_phone`; name, phone, address and amount
      (GYD) reuse the existing columns.
    - remittance_operations.combo_costo_gyd.
  - Bot function crm_registrar_destinatario_combo(conv, nombre, telefono, direccion, referencia, telefono_contacto,
    monto_gyd) (service_role): opens or updates the combo, partial data allowed, panel lock respected,
    quoted_source_amount = sum, Spanish "FALTA ... / minimo 25,000 / Datos completos. Total a pagar" replies.
  - Completeness rule in crm_beneficiarios_completos.
  - Panel:
    - crm_operaciones_de_conversacion lists combos and adds beneficiary_reference, beneficiary_contact_phone and
      operation_combo_costo_gyd (dropped and recreated with the same ACL);
    - crm_agregar_beneficiario accepts combos;
    - the crm_cerrar_operacion_manual picker accepts 'combo';
    - crm_set_combo_costo(op, costo) is new (owner/admin).
  - cerebro_servicios 'combos': new hechos and notas, requiere_humano false.
  - Tests:
    - combo-model.sql: RED ("function crm_registrar_destinatario_combo ... does not exist"), then ALL PASS
      (re-checked by the parent).
    - Neighbours ALL PASS: panel-recarga, recarga-model, recarga-numbers, recarga-before-deposit, recarga-by-audio,
      recharge-only-with-live-promo, manual-close-service, panel-closing-actions, panel-cash-recipient,
      add-beneficiary, cash-delivery-data, read-rpc.
    - read-rpc's fixture used 'combo' as an example of an unlisted service; it is now 'visa'.
  - Gap until T1b: a combo deposit is still filed as a remesa, and closing a combo feeds no calculator line.
