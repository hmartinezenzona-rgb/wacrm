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

## B+D. Panel closing actions
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
- [x] A2 App: the Calculator rates form edits the cash rate; the panel shows a cash recipient (address, phone, ID photo,
      "100 USD cash") — DB 189 (c69d39d), app 6564fa0
- [ ] A3 Production (188 + app) with go-ahead; fill Bruce's operation (972718ea) amount
- [x] B+D-1 DB: migration 190 (manual silent close, soft delete, card without phone) — 0099e34, staging
- [x] B+D-2 Staging notifier skips delivery_mode closed_manually
- [x] B+D-3 App: trash icon, "Close manually", optional phone in the add form — 96884d3
- [ ] B+D-4 Staging deploy + owner check, then production (190 + notifier + app) with go-ahead
- [ ] A4 Cash recipient's NAME is stored and shown (owner, 2026-10-03): the bot repeats it ("*Nombre:* Anabel Frenes
      Vera") but remittance_beneficiaries.name stays NULL (staging op 4a044782; production Bruce 972718ea also lost
      name, phone and address); the panel shows it for a cash recipient
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
- A2 DB (2026-10-02, staging): `189_panel_cash_recipient.sql` (+ ROLLBACK): crm_operaciones_de_conversacion appends
  beneficiary_address, beneficiary_id_photo_wamid, beneficiary_id_photo_url (media_url of that message in the same
  conversation); DROP + CREATE, grants as before; columns appended so the current app keeps working. Assertion
  `panel-cash-recipient.sql` (address, photo wamid + URL, 100 USD from 188, complete) RED (`v_r has no field
  beneficiary_address`) -> GREEN rolled back -> applied to staging, ALL PASS; read-rpc and panel-quote ALL PASS.
  history-readiness fails in its fixture (a deal no longer creates an operation since 172): pre-existing.
- A2 app (2026-10-02): commit 6564fa0. Calculator field "Tasa efectivo USD (GYD por dólar)" (route accepts and selects
  efectivo_usd_gyd); the panel card shows a cash recipient's kind, phone, address and a "View ID" link (media_url is a
  public storage URL), or "ID photo missing". RED 12 failing -> GREEN; full suite 1684 passed; tsc clean.
- B+D-1 (2026-10-02, staging): `190_panel_closing_actions.sql` (+ ROLLBACK). delivery_mode CHECK + closed_manually;
  audit actions + human_manual_close, human_operation_deleted; crm_agregar_beneficiario phone optional (validated when
  given; the remesa stays incomplete so a normal delivery still needs it); crm_cerrar_operacion_manual (owner/admin,
  reason, only ready_to_transfer/transferring -> completed closed_manually, calculator feed); crm_eliminar_operacion
  (owner/admin, reason, refused for completed/cancelled/ready_to_transfer/transferring or a consumed non-voided MMG
  deposit -> cancelled). Assertion `panel-closing-actions.sql` (6 cases) RED (`phone must be 8 to 15 digits`) ->
  GREEN on staging; panel-cash-recipient, cash-delivery-rate, panel-quote, beneficiary-touches-operation ALL PASS.
- B+D-2 (2026-10-02): staging notifier OCdJoHTkV6S0aAdk node "Filtrar cambio de etapa": in the completed branch
  `if (rec.delivery_mode === 'closed_manually') return [];` (the trigger sends to_jsonb(NEW), so the field is there).
  Backup ~/cerebro-fase1/pruebas/notificador-staging-antes-190.json. Offline run of the node: closed_manually -> [],
  proof_sent -> "Listo, su remesa ... completada". Production notifier wGud0KGR6eMqqfMQ: same edit pending (B+D-4).
- B+D-3 (2026-10-02): commit 96884d3. POST routes close-manual and delete (admin role, beta flag, reason 1-500,
  rpcErrorResponse mapping); commands cerrarOperacionManual / eliminarOperacion; inline confirmation with required
  reason (close warns the customer is not notified); trash only when not completed/cancelled/ready_to_transfer/
  transferring, Close manually only on ready_to_transfer/transferring, both owner/admin; history label "Closed
  manually"; add-beneficiary phone optional for cards. RED 51 failing -> GREEN; full suite 1741 passed; tsc clean.
- B+D-4 staging (2026-10-03 01:29 UTC, owner go-ahead): app `69a5fca` built in prod-build (Node 20 docker, staging
  build env; NEXT_PUBLIC identical to the server's): manifest staging / kolppplawzdsjfydwejr, 114 money-path tests
  passed, 0 production refs / 32 staging refs, no .env, sha256 OK, close RPC present in the server chunks. Uploaded
  (2386 files = 2386), BUILD_ID `leVxLTPARti0VuIXc4fog` checked before relinking; served cwd `~/wacrm-releases/69a5fca…`,
  `anterior` -> `ac45d47…` (rollback: relink + `pm2 restart wacrm-staging --update-env`); `/login` 200 and the domain
  serves the new BUILD_ID; online, 0 unstable restarts. Pending: owner's check, then production (188, 189, 190,
  production notifier edit, app) with go-ahead.
- B+D-4 owner check on staging (2026-10-03 01:38-01:43 UTC), test number 529622896918:
  - Delete: op f45a353c collecting_information -> cancelled, audit human_operation_deleted with the reason, notifier
    ran with 0 messages.
  - Manual close: op 5368d741, forced verification -> ready_to_transfer ("ya fue verificado" sent), then Close
    manually -> completed / closed_manually, audit human_manual_close, calculator entry at 01:43:05, notifier ran with
    0 messages (no "Listo, su remesa").
  - Side finding (staging only): the incident alert at 01:40:31 failed ('to' must be E.164) because the staging
    contact tagged `admin` was the test number, and reset-test-contact deletes it with its tags. Production has 3 admin
    contacts with valid phones. Not changed.
- A owner check on staging (2026-10-03 01:54-01:57 UTC, test number): bot quoted 100 USD = 29,000 GYD (rate 290);
  automation_cash_delivery_data_registered stored phone 53904458 + address, then the ID photo -> complete; panel row
  carries phone, address and photo URL; crm_cotizacion_de_conversacion = 29,000 GYD -> 100 USD. The name was NOT
  stored (-> A4). No deposit was sent, so the operation amount (and "100 USD cash") is still empty, as designed.
