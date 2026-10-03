# Cash USD delivery end to end, remesa closing actions, resent receipts

Origin: owner review 2026-10-02 of two production cases after the WU5b cutover.
- Bruce (conv 4814cdfe, op 972718ea): cash USD delivery, 29,000 GYD verified, but the panel shows no amount to receive
  (should be 100 USD at 290 GYD/USD). Then the same receipt resent and misread (28,000, ref 20321203276682, year 2023)
  opened a second operation 591262ba in incident `sin_correo`.
- Rubislandi (5926338345): deposit verified and transferred by the owner, but the customer never sent the phone; the
  operation cannot be completed and keeps the warning. Two open operations: 30c87ea5 (2026-09-29, 5,000 GYD, no
  beneficiary) and 807357da (2026-10-02, 5,000 GYD, card + phone).

Owner decisions (2026-10-02): order A -> B+D -> C. Rubislandi is closed by the owner himself with the new action, in
silent mode. Cash delivery must be reviewed carefully before building it.

## A. Cash USD delivery (efectivo_usd) — findings
- The bot marks it: cerebro_marcar_destino_usd (deal-free, 163/WU5b) maps "efectivo" to delivery_method efectivo_usd.
- 150/151: recipient data on an `efectivo_usd` beneficiary row (phone, address, id_photo_wamid) via
  crm_registrar_datos_entrega_efectivo; owners/admins notified ('entrega_efectivo_lista') when the three are known.
- Gaps: the 290 GYD/USD rate lives only in cerebro_servicios.hechos text (bot-facing), not in data; crm_calcular_monto_destino
  has no efectivo branch (destination stays NULL); crm_beneficiarios_completos requires card + phone for every non-Zelle
  beneficiary, so a cash delivery can never be delivered; the app has no code for efectivo (no address / ID photo shown).
  Bruce's operation is the first efectivo_usd operation ever in production.

## B+D. Panel closing actions (planned)
- B: delete a remesa (trash icon) = soft delete: status cancelled + audited reason, hidden from the panel; owner/admin;
  not allowed when completed or with a verified deposit.
- D: "Cerrar manualmente" on a verified remesa: completes it even with incomplete beneficiary data (e.g. no phone), feeds
  the calculator, new delivery_mode so the notifier sends nothing to the customer; owner/admin, reason audited. Add
  beneficiary from the panel without a phone.

## C. Resent receipt misread (planned)
- A receipt with an impossible date (other year / future) or with no MMG email and the same time and near amount as an
  already verified receipt of the conversation is treated as a resend, not a new operation.

## Tasks
- [x] A0 Owner decisions (2026-10-02): the cash rate changes and must be set in ONE place that every user reads; the
      minimum stays 100 USD (its GYD value follows the rate).
- [x] A1 DB: migration 188 (cash rate in the calculator, received amount, completeness, minimum, live service text)
- [ ] A2 App: the Calculator rates form edits the cash rate; the panel shows a cash recipient (address, phone, ID photo,
      "Recibe X USD en efectivo") — needs crm_operaciones_de_conversacion to return address / id_photo_wamid
- [ ] A3 Production (188 + app) with go-ahead; fill Bruce's operation (972718ea) amount
- [ ] B+D panel actions (plan, TDD, staging, owner check, production)
- [ ] C resent receipt guard

## Progress / evidence
- A finding (corrects what I told the owner): rates are NOT set by WhatsApp any more. `tasas` became a VIEW over
  calculator_rate_versions at the cutover (120); the Cerebro admin command `tasa <moneda> <valor>` (node "Liberar chat")
  still INSERTs into it and would fail. Rates are set in the app's Calculator page (crm_set_calculator_rates).
- A1 (2026-10-02, staging): `188_cash_delivery_rate.sql` (+ ROLLBACK). calculator_rate_versions.efectivo_usd_gyd (one
  new version per account seeds 290 with the current rates); crm_set_calculator_rates accepts it;
  crm_tasa_vigente('efectivo') reads it from the calculator; the view `tasas` is deliberately NOT changed (first draft
  added an 'efectivo' row: consultar_tasas, cerebro_ejecutar_tool_dsml and the admin rate list print every row as
  "1 <MONEDA> = x CUP", so the bot would have said "1 EFECTIVO = 290 CUP"; caught by tasas-derives case 2, reverted
  on staging); cerebro_minimo_efectivo_gyd() = minimo_usd_efectivo (100, new config) x rate, used by cerebro_minimo_gyd;
  crm_calcular_monto_destino: efectivo_usd -> floor(GYD / rate) USD calculated; crm_beneficiarios_completos: cash =
  phone + address + ID photo; the efectivo_usd service text carries {tasa_efectivo}/{minimo_efectivo_gyd}/{tasa_usd},
  filled live by cerebro_servicio_get. Assertion `cash-delivery-rate.sql` (5 cases: rate 290 and view still gyd/usd,
  minimum 29,000, 29,000 GYD -> 100 USD, setting 300 once -> 300/30,000/96 USD/text updated/CUP rate untouched,
  completeness) RED (`tasa efectivo must read 290, got NULL`) -> GREEN in a rolled-back transaction, applied to
  staging, ALL PASS; also GREEN on the production copy (wacrm-ensayo-wu5b, rolled back). Regressions after: rate-versions,
  tasas-derives, calculator-access, deal-free-money-rules, cup-excess-equivalent ALL PASS. destination-amount.sql fails
  BEFORE and after (it INSERTs into the view tasas: stale since 120, unrelated).
