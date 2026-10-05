# Feature: visa extensions end to end (bot, panel, calculator, notifier)

## Objective
A customer who wants a Guyana visa extension pays 5,000 GYD by MMG and sends the receipt by WhatsApp. The deposit
lands on a VISA operation (not a remesa), the panel shows it, the admin marks it completed when the application is
uploaded, the customer is told so, and the calculator counts the 5,000 GYD.

## Problem (2026-10-04)
- The bot informs well about visas: price, payment first, requirements, the 11-month fine, the form link
  acortar.link/extension_de_visa, and the steps after the immigration PDF (054). But 0 operations have
  service_type 'visa' in production.
- The owner: the customer pays by MMG AND sends the receipt by WhatsApp. So every visa payment is filed as a remesa
  today (several 5,000 GYD "remesas" have no beneficiary), and the calculator never prices it.
- Osmany: visa extensions are the service that takes the most of his time.

## Business rules (Osmany docs/negocio/RESPUESTAS-OSMANY-servicios.md, cerebro_servicios 'visa', owner 2026-10-04)
- 5,000 GYD per extension, paid before. The customer fills the online form himself, and its last field is the
  receipt photo. The business uploads the application on the immigration site.
- The 20,000 GYD fine (11+ months without an extension) is paid at immigration, not to the business.
- Owner decisions:
  1. All 5,000 GYD is profit (no cost).
  2. A visa is completed when the application is uploaded. The customer notice: "Su aplicación de extensión de
     visa ya fue subida. Inmigración le enviará un PDF por correo; cuando llegue se lo reenviamos con los pasos a
     seguir."
- Defaults chosen by Claude (stated to the owner):
  - The bot collects no passport data (the customer fills the form). It sends the link and the price, and waits for
    the receipt.
  - Several people in one payment = one operation of N visas, N = deposit / 5,000.
  - Detection by explicit phrases (extensión de visa, inmigración, visa vencida or about to expire, the form link),
    or by the agent's tool (audio). Never by "visa" alone: customers call the Clasica card a "tarjeta Visa".

## Scope
- T1 DB:
  - cerebro_visa_en_curso and the agent tool function (open a visa);
  - deposit routing in cerebro_registrar_deposito (precedence with recarga and combo);
  - completeness (a visa needs no recipients), cerebro_minimo_gyd 5,000 per visa;
  - panel RPCs (list, manual-close picker 'visa');
  - calculator VISA line (facturado = deposit, invertido = 0);
  - the cerebro_servicios 'visa' text.
- T2 Panel and calculator UI: the visa card ("N extensiones"), the picker, VISA calculator lines.
- T3 Cerebro: the agent tool, the Decisor note while a visa is open (no card or beneficiary), the verified-deposit
  line.
- T4 Notifier: the visa verified and completed messages.
- T5 Owner test on staging. T6 Production after the go-ahead.

## TDD
Strict. SQL assertions (self-reverting DO blocks; fixtures independent of existing conversations; recheck with
every promo discarded, since staging keeps a fake promo), vitest for the app, dry run + node --check + offline
harness for the n8n code.

## Progress
- [x] T1 DB 213_visa_model (commits 75c781f, 6355e62; staging, schema_migrations 213).
  - Detection: cerebro_visa_en_curso, explicit phrases only (never "visa" alone).
  - Agent tool: crm_abrir_visa(conv, personas) opens 5,000 x N; it is service_role only and audited as
    automation_visa_registered.
  - Deposit routing: the open operation wins; otherwise recarga > combo > visa; a reseller is always a remesa.
  - Completeness: a visa needs no recipients. Minimum 5,000 per visa.
  - Panel: the visa row comes with NULL beneficiary columns; the manual-close picker accepts 'visa'.
  - Calculator: the VISA line is facturado = deposit, invertido = 0, never pending; crm_resolve_pending_entry
    refuses VISA.
  - cerebro_avisar_envios_sin_beneficiario skips visas. The visa service text says the assistant takes the order,
    and the stale resumen (4,000) is fixed.
  - Found in review, and also affecting COMBO in production (210):
    - an open combo or visa made the remesa writers drop a later remesa's typed card and phone. Prod had 0
      combo/visa ops.
    - 213 now has the resolver never pick a visa or combo as the remesa target. guardar_beneficiario_auto ignores a
      visa, and blocks for a combo only while collecting_information.
    - The shared writer never writes on a visa or combo; past collecting it opens a remesa next to it.
  - Tests:
    - visa-model RED ("case 1: ... got remesa/deposit_verification/5000"; then "case 7 ... got
      visa/collecting_information/5000" and "case 7b: a paid combo must not block a remesa"), then ALL PASS.
    - The writer's 22 neighbours pass as is and with every promo discarded. The parent re-checked visa-model,
      combo-ignores-remesa-writers, combo-model, combo-edit, partial-beneficiary-tools and recarga-numbers in both
      modes.
    - combo-model case 9 and read-rpc used 'visa' as the unlisted-service fixture; both now use 'traduccion'.
    - ROLLBACK-213 restores 17 functions (md5-checked).
