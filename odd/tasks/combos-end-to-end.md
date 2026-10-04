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
- [x] T1 DB `208_combo_model.sql` (+ ROLLBACK, assertion combo-model.sql): beneficiary type and columns, open/save
      function, completeness, deposit routing, panel RPCs, cost field, calculator COMBO feed, service text. Apply to
      staging; neighbour assertions re-run.
- [x] T2 Panel UI + calculator UI (vitest), staging app deploy.
- [x] T3 Cerebro gate106 (staging): agent tool registrar_combo, Decisor notes, verified line.
- [x] T4 Notifier: combo completion message (staging).
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
- T1b (commit 39796eb, staging): 209_combo_deposit_and_calculator.
  - Deposit routing:
    - cerebro_combo_en_curso: an open combo, or typed `combos?` / "(mandar|enviar|...) comida"; the bare "comida" is
      not used, so "comida de mi mama" stays a remesa.
    - cerebro_registrar_deposito: the OPEN operation wins; combo only when a combo is open and no recarga is; with
      text only, recarga wins as today.
    - cerebro_riel_op, cerebro_minimo_gyd (25,000 per recipient), cerebro_objetivo_minimo and
      cerebro_recruzar_depositos_tardios know 'combo'.
  - Calculator:
    - the service is COMBO, in GYD: facturado = the verified deposit (quoted_source_amount), invertido =
      combo_costo_gyd, retorno = the difference;
    - with no cost the line is verified_pending with missing_inputs {comboCosto};
    - crm_set_combo_costo feeds a completed combo; re-setting voids and revives the same row, never a duplicate.
  - Tests:
    - combo-deposit-calculator.sql: RED ("case 1: ... got combo/collecting_information/30000;
      remesa/deposit_verification/30000"), then ALL PASS (re-checked by the parent, with combo-model and
      calculator-recarga).
    - The writer re-ran 20 neighbours, all ALL PASS.
    - Pre-existing failures, also failing without 209 (stale deal-based fixtures): deposit-review,
      verify-deposit-status-drift, split-deposit-minimums.
  - For T2: crm_resolve_pending_entry would ask for USDT rates on a COMBO line. The UI must not offer "resolve rates"
    for COMBO; it points to the combo cost field instead.
- T2 (commits 2ffbde7 panel, 3dfd20c cost field + API, 9430c22 calculator view):
  - The combo card shows recipients with all their fields, the add form (25,000 hint, not blocking), the
    manual-close picker 'combo', and the owner/admin cost field (also on History cards).
  - The cost API is POST /api/remittance-operations/{id}/combo-cost with body {costGyd|null}.
  - The calculator shows "Falta el costo del combo: anótalo en el panel de la conversación" and never offers rate
    resolution for COMBO.
  - Writer's checks: RED observed first for every new test; typecheck clean; lint shows only the pre-existing
    notifications/page.tsx error (re-checked by the parent); npm test 149 files / 1873 tests passed.
  - Not built: editing or moving a combo recipient. crm_corregir_beneficiario and crm_reasignar_beneficiario only copy
    the legacy columns and would drop address, reference and contact_phone, so both buttons are hidden on combo cards
    (follow-up). The panel labels are English, like the rest of the panel (en.json is the only locale).
- Parent review fix (commit after 9430c22): crm_resolve_pending_entry refuses COMBO lines (22023), added to 209 with
  its rollback. combo-deposit-calculator case 8b was RED ("refused for another reason: still missing required
  rate(s)"), then ALL PASS. resolve-pending (10 expectations) and calculator-cash still pass.
- [x] T3 Cerebro gate106 on staging (~/cerebro-fase1/pruebas/gate106-cerebro-combo.py; backup
  cerebro-staging-antes-106-20261004T132309.json):
  - tool registrar_destinatario_combo (amount digits only, so "30.000" = 30000);
  - Contexto combo_en_curso and combo_completo;
  - Decisor combo note, falta, sabeDestino, viaSinDefinir, deposit-state wording, no remesa-amount parsing in combo
    messages;
  - the agent's tool line and verified line ("una persona del equipo le llama para elegir los productos...").
  - Checks: node --check on the Decisor, agent expressions and tool replacement; the Contexto SQL and the tool SQL ran
    on staging.
- [x] T4 Notifier gate107 on staging (gate107-notificador-combo.py; backup notificador-staging-antes-107-*.json):
  - Leer secreto adds reference, contact_phone and amount.
  - ready_to_transfer: the combo "falta" list, or the call line.
  - completed: "Listo, su combo ya fue enviado. Suele llegar en X a Y días" by the province in the address, or
    "entre 3 y 15 días, según la provincia" when mixed or unknown.
  - Offline harness (scratchpad harness107.js): all combo cases are right, and the remesa and recarga messages are
    unchanged. Outside the 24 h window the Meta template remesa_completada is still the fallback, as for recarga.
- Staging app deployed: release 1499140, BUILD_ID lO3gSzKXhTtAVTLM9B6V3, served by crm.onlinefreedom.site;
  anterior -> 2b9306a; 0 production refs in the bundle. The prod-build worktree was restored to 30f4d75. The test
  contact was reset. Waiting for the owner's T5 test.
- T5 owner test, round 1 (2026-10-04 19:48Z), FAILED at step 1:
  - The customer said by audio "quiero enviar dos combos, uno de 30 mil y otro de 25 mil". The agent called
    registrar_destinatario_combo twice (30000, then 25000, no name or phone) and replied "Anoté sus dos combos".
  - The DB kept ONE recipient of 25,000: with neither name nor phone the function updated the latest recipient.
  - Fix:
    - 208 amended: crm_registrar_destinatario_combo gets `p_numero integer DEFAULT NULL`, the combo's 1-based number
      in the order the customer said them. It picks the recipient at that position, or creates one. The signature
      changes, so the ROLLBACK drops the 8-arg function.
    - combo-model case 12 was RED ("function ... (..., integer, integer) does not exist"), then ALL PASS;
      combo-deposit-calculator still ALL PASS. Applied to staging (old 7-arg function dropped).
    - Cerebro gate106b (~/cerebro-fase1/pruebas/gate106b-combo-numero.py; backup
      cerebro-staging-antes-106b-20261004T135931.json): the tool passes $8 numero, and the agent's tool line and
      the Decisor note say to always send the combo's number. node --check passes on the tool replacement and the
      Decisor; the tool SQL ran on staging.
    - The test contact was reset for round 2.
- T5 owner test, round 2 (2026-10-04 21:30–21:41Z), FAILED: "es repetitivo, me pidió teléfonos que ya tiene".
  - Data: the typed phones 53458767, 53821069 and 53845687 went through the typed-number auto registration
    (cerebro_guardar_beneficiario_auto -> cerebro_escribir_bloque_beneficiario). Each became a 'cuban_card'
    generation on the combo and turned the combo recipients 'reemplazado' (11 rows, one vigente cuban_card).
  - The bot also asked one field at a time, saved the shared address and the single contact phone on combo 1 only,
    and asked for them again.
  - Fix DB 210_combo_ignores_remesa_writers (+ ROLLBACK, staging, schema_migrations 210):
    - guardar_beneficiario_auto writes nothing while a combo is open;
    - the shared writer never writes on a combo and never opens a remesa next to an open combo.
    - Assertion combo-ignores-remesa-writers.sql: RED ("cuban_card:-:vigente,combo:Juan Perez:reemplazado,..."),
      then ALL PASS.
  - Neighbours (beneficiary, reparto, cash, recarga, combo, zelle): run on staging before and after 210 in one
    transaction, with identical results. Passing: add-beneficiary, beneficiario-parcial-reset,
    beneficiary-touches-operation, the calculator-* and cash-* suites (except cash-delivery-activation), panel-*,
    partial-beneficiary-tools, the recarga-* suite, recharge-only-with-live-promo, reparto-tool-usd-rail,
    deal-free-money-rules, feed-from-beneficiaries, the three combo-* suites.
  - Pre-existing failures, identical without 210 (stale fixtures on a staging with no conversations or deals;
    follow-up): beneficiary-proofs, cash-delivery-activation, deal-free-beneficiary-writers,
    deal-free-panel-verification, partial-beneficiary-auto, reparto-auto, reparto-destino-node-adapters,
    reparto-guards, reparto-keeps-zelle, reparto-usd-card-rail, zelle-confirmed-name, zelle-remainder-amount.
    beneficiary-matcher and zelle-holder-name print no result line.
  - Cerebro gate106c (backup cerebro-staging-antes-106c-*.json):
    - ask for ALL missing data of ALL combos in ONE message;
    - a datum the customer says is shared is saved on EACH combo (one call per number);
    - never ask again for something the tool does not list as missing.
    - The Decisor passes node --check.
  - The test contact was reset for round 3.
