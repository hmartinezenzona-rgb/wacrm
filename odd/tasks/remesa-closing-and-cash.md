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
- [ ] A0 Owner decisions on cash delivery (rate source, what the panel must show, completeness rule)
- [ ] A1..An (after A0)
- [ ] B+D panel actions (plan, TDD, staging, owner check, production)
- [ ] C resent receipt guard

## Progress / evidence
