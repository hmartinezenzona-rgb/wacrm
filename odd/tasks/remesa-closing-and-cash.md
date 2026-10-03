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
- [x] A4 Cash recipient's NAME is stored and shown (owner, 2026-10-03): the bot repeats it ("*Nombre:* Anabel Frenes
      Vera") but remittance_beneficiaries.name stays NULL (staging op 4a044782; production Bruce 972718ea also lost
      name, phone and address); the panel shows it for a cash recipient
- [x] A5 Notifier "verified" message knows cash (owner, 2026-10-03): on a manual verification the notifier's
      ready_to_transfer branch checks only Zelle (name + account) or card (card + phone), so a complete efectivo_usd
      recipient got "nos falta la tarjeta de quien recibe en Cuba" (staging op 4a044782, 02:11 UTC). For cash it must
      check phone + address + ID photo, like crm_beneficiarios_completos (188); staging and production notifiers
- [x] E1 Panel actions with icons, no reason text (owner, 2026-10-03): manual close confirms with a green check and
      cancels with an X, no reason field; the audit stores a fixed internal note ("Closed manually from the panel")
- [x] E2 Notify-customer bell (owner, 2026-10-03): every panel action that messages the customer (verify / force-verify,
      deliver, manual close) shows a bell toggle. ON by default (customer notified) EXCEPT manual close, where it is OFF
      by default; unchecked = no message. Delete never notifies (no bell). Needs the choice to reach the notifier
- [x] E3 Delete the same way (owner, 2026-10-03, on staging op 333fe846): no reason field, confirm with a check and
      cancel with an X; the audit stores a fixed internal note ("Deleted from the panel")
- [x] E5 No explanatory texts in the action forms (owner, 2026-10-03: they take room and deform the panel): closing
      control warnings and the complete-transfer helper removed — cb358a9
- [x] E6 Complete transfer confirms with X / green Check icons (owner, 2026-10-03), the varying label (Send & complete /
      Complete / Complete without screenshot) as aria-label and title; bell reused — e941a30. RED (new icon test)
      -> GREEN; container/multi tests find buttons by text or aria-label; suite 1764; tsc and eslint clean
- [x] E7 The "N open operations ... resolve which one" block becomes a compact amber badge "⚠ N open" beside the panel
      title, full text as tooltip and aria-label (owner, 2026-10-03: heavy, takes room) — 4b3a2b5. It already
      disappears by itself with one or no open remesa (it shows only for the resolver's `ambigua`, any status; the
      owner's test chat had 4 ready_to_transfer, no incident tag). RED 2 -> GREEN; suite 1763; tsc, eslint clean
- [x] E8 Badge removed altogether and the panel titled "Operations" (owner, 2026-10-03: the badge crowded the title;
      the cards and their statuses already show it) — fdeffae; ResolverStateBanner and its keys deleted. RED 1 ->
      GREEN; suite 1761; tsc, eslint clean
- [ ] A6 Cash in the calculator: calculator_service_for_operation maps cuban_card/multiple_distribution -> CUP,
      zelle, clasica, tropical and NOTHING for efectivo_usd, so a completed cash remesa never reaches the calculator
      (staging 4a044782 closed 02:16 has no entry; production Bruce 972718ea would not either). Needs the owner's
      decision on how cash is counted (service, cost). DECIDED (admin via owner, 2026-10-03): the cost (buy) of a cash
      dollar is the same as Zelle / Clasica / Tropical, usdt_buy_gyd (240 today); only the sale price differs
      (efectivo_usd_gyd 290 vs usdt_sell_gyd 260). So: invertido = USD delivered x usdt_buy_gyd; facturado = GYD
      deposited; amount = USD at efectivo_usd_gyd. (Earlier note:) the owner asked the admin (Osmany)
      how the cost of a cash delivery is computed. Proposal on the table: new USD service EFECTIVO, amount = USD
      delivered, facturado = GYD deposited, invertido = USD x the USDT rate used for Zelle — or another cost (courier
      fee, another rate) per the admin's answer
- [ ] A7 The bot recognises an ID card (owner, 2026-10-03): Bruce's "carnet" was his 14:07 MMG-account screenshot
      ("SOLO ESTA CUENTA"). Vision (gpt-4o) has only comprobante / tarjeta+celular / cuenta Zelle / "otro", and
      'Registrar carnet efectivo' stores the FIRST "otro" image during an open cash delivery. Proposed: a vision case
      for an ID card (with name and ID number), store only that case, and repoint Bruce's photo to his 14:26 image.
      Awaiting the owner's yes
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
- 2026-10-03 02:11 UTC, staging: recreated Bruce's case on the test chat for the owner's panel review: op 4a044782 set
  to 29,000 GYD / deposit_verification, crm_calcular_monto_destino -> 100 USD calculated, crm_forzar_verificacion as
  owner -> ready_to_transfer, complete. The verified message exposed A5.
- 191 DB (2026-10-03, staging): `191_panel_notify_and_cash_name.sql` (+ ROLLBACK), commit e756b11. Column
  remittance_operations.customer_notice_muted_for (the status whose customer notice the panel switched off, written in
  the same UPDATE as the status change). p_notify on crm_verificar_deposito / crm_forzar_verificacion /
  crm_entregar_operacion (default true) and crm_cerrar_operacion_manual (default false); p_motivo optional on close and
  delete with fixed notes "Closed manually from the panel" / "Deleted from the panel"; crm_registrar_datos_entrega_efectivo
  gains p_name (kept once given, audited, in the admin notification; not required for completeness). Functions dropped
  and recreated (signature change). Assertion `panel-notify-and-cash-name.sql` (6 cases) RED (`function ... (uuid,
  unknown x4) does not exist`) -> GREEN; panel-closing-actions (blank-reason case removed), cash-delivery-data (5-arg
  signature), panel-cash-recipient, cash-delivery-rate, panel-quote, beneficiary-touches-operation ALL PASS. Comparing the
  other assertions that touch these functions against the pre-191 state (rollback inside a forced-rollback transaction):
  the same 10 fail before and after on deal fixtures retired by 172 (pre-existing); deals-free-views-and-inert-edits
  gains one expected failure — its [5a] guard says the 164 body of crm_entregar_operacion only removes lines, and 191
  adds the notify line on purpose.
- A5 + E2 notifier (2026-10-03, staging OCdJoHTkV6S0aAdk) via ~/cerebro-fase1/pruebas/gate85-notificador.py (same script
  for production): 'Leer secreto' returns address + id_photo_wamid; the verified message checks a cash recipient's phone,
  address and ID photo; `avisoClienteApagado` (customer_notice_muted_for === status) silences the customer message of
  ready_to_transfer and completed, replacing the 190 closed_manually rule; admin alerts untouched. Offline run of the
  node, 8 cases: cash complete -> "En breve le hacemos la transferencia"; cash missing address/photo -> asks for them;
  card missing phone unchanged; bell off -> nothing; manual close default -> nothing; manual close bell on -> "Listo";
  stale mute on another status -> still notifies; incident alert with mute -> admin alert still sent.
- A4 Cerebro (2026-10-03, staging U52y1kSNvhgxvWeb) via gate85-cerebro-nombre.py: tool registrar_datos_entrega_efectivo
  passes `nombre` as p_name; the agent's tool line names it (optional, saved when given). Backups in ~/cerebro-fase1/pruebas.
- A4/E1/E2/E3 app (2026-10-03): commit 3901074. Routes verify / force-verify / deliver take optional
  notify (default true) -> p_notify; close-manual notify default false; close-manual and delete take no reason. New
  NotifyToggle (Bell/BellOff, aria-pressed) in deposit review (verify + force-verify), complete transfer (single and
  multi) and the manual close; closing control = green Check / X icon buttons, no textarea; delete has no bell; cash
  recipient's name chip; the complete-transfer helper says only the screenshot goes out when the bell is off. RED 49
  failing (writer) + 1 (helper) -> GREEN; full suite 1764 passed; tsc and eslint clean. Checked off on staging code;
  owner check and production still pending. Open owner question: wording of the "verified" message instead of
  "En breve le hacemos la transferencia" (cash and possibly every method).
- Verified message without a time promise (owner, 2026-10-03): ~/cerebro-fase1/pruebas/gate85b-textos.py (after
  gate85) on staging. Cash: "Ya tenemos los datos de quien recibe. Un compañero coordinará la entrega en efectivo y le
  avisamos en cuanto quede hecha."; every other method: "Su remesa ya está en cola para transferir. Le avisamos en
  cuanto quede hecha." Offline run: cash and card complete give the new lines; missing-data asks unchanged.
  Open: the Cerebro itself still promises "en breve le hacemos la transferencia" on an automatic verification in open
  hours (Agente Remesas / Decisor) — asked the owner.
- Bot without a time promise (owner, 2026-10-03, "varíala un poco"): ~/cerebro-fase1/pruebas/gate85c-cerebro-promesa.py
  on staging U52y1kSNvhgxvWeb. Agente Remesas, automatic verification in open hours: "su remesa ya queda en cola para
  transferir y le avisamos en cuanto quede hecha" with an alternative phrasing, "en breve"/"enseguida"/any time
  forbidden; the example line follows; a cash delivery says a teammate coordinates it. Decisor, resent receipt of a
  verified remesa: same promise. Closed-hours wording unchanged. Prompt expressions (4) and the Decisor code parse OK.
  Pending: a live bot test on staging.
- REVISED wording (owner, 2026-10-03, supersedes the two entries above; staging notifier and Cerebro were restored from
  their pre-85b/85c backups — only the touched nodes differed — and the rewritten scripts applied): after a verified
  deposit neither the notifier nor the bot promises a time or repeats the recipient's data; the recipient's data is
  only echoed when the customer gives it. Form: "Su depósito de *5,000 GYD* ya fue verificado. Una vez hecha su remesa
  de *15,000 CUP* le notificamos por acá." with light variation; cash says "entregada" and "USD en efectivo"; with
  several currencies (no single amount) the amount is left out.
  - Notifier gate85b-textos.py: three phrasings picked at random, amount via {RECIBE} ('Buscar telefono' now labels
    efectivo_usd "USD en efectivo", which also reads better in "Listo, su remesa de *100 USD en efectivo* ...").
    Offline run: cash -> "Una vez entregada su remesa{RECIBE} le notificamos por acá."; card -> the hecha forms.
  - Cerebro gate85c-cerebro-promesa.py: automatic verification (open / closing / closed) = verified + "una vez hecha su
    remesa de X le notificamos por aca" (X from monto_recibe_valor/moneda), part (3) card+phone removed and forbidden;
    out-of-hours example without card data; Decisor resent-verified note the same. Expressions parse; the verified
    block evaluated with and without an amount gives the expected instruction. Pending: live bot test.
- Staging app `2a5ea2e` deployed (2026-10-03 02:59 UTC, owner go-ahead): same checks as before (staging manifest,
  114 money-path tests, 0 production refs, no .env, sha256 OK, p_notify in the server chunks, 2386 = 2386 files),
  BUILD_ID `94cyyCFRs9MFhl4dMEcBN`, `anterior` -> `69a5fca…`, `/login` 200, online, 0 unstable restarts.
- Owner test fixtures on the staging test chat (no bot chat needed), 8 operations inserted directly (no status
  transition, so no message at creation): 5,000 / 6,000 GYD deposit_verification (force-verify bell on / off);
  7,000 / 8,000 ready_to_transfer complete card (complete transfer bell on / off); 9,000 / 10,000 ready_to_transfer card
  without phone (close manually, bell default off / on); collecting_information card (delete; plus 333fe846); 29,000 GYD
  cash ready_to_transfer, complete with name Anabel Frenes Vera (name shown, 100 USD). Panel RPC returns all with the
  amounts calculated (15,000 ... 30,000 CUP; 100 USD).
- [x] E4 Force-verify like close/delete (owner, 2026-10-03, found while testing the 5,000 fixture: the force form still
  had Reason + text buttons — missed in E1/E3). DB 192 (8841220): crm_forzar_verificacion p_reason optional, fixed note
  "Verified manually from the panel"; assertion force-verify-without-reason.sql RED ("reason must be at least 5
  characters") -> GREEN, panel-notify-and-cash-name and panel-closing-actions ALL PASS. App 222da4b: force form = bell (on) +
  X + green Check, no reason; route reason optional. RED 9 failing -> GREEN; full suite 1764; tsc clean.
  The 5,000 fixture was force-verified by the owner with the bell on at 03:04 and got "En cuanto quede hecha su remesa
  de *15,000 CUP* le avisamos por aquí."
- Owner test round 2 (2026-10-03 03:03-03:17 UTC, staging): 5,500 force-verify bell on -> "Una vez hecha su remesa de
  *16,500 CUP* le notificamos por acá"; 6,000 bell off -> muted, no message; 8,000 complete transfer bell off
  (skip_proof) -> muted, no message, calculator entry; 9,000 and 10,000 manual close both sent with notify=true (the
  control starts with the bell off, so it was switched on) -> "Listo, su remesa de *27,000 / 30,000 CUP* ya fue
  completada", calculator entries; two deletes -> cancelled with "Deleted from the panel"; every audit carries the
  fixed notes. 7,000 not tested. Found A6.
- Staging app `08bce88` deployed (2026-10-03, owner go-ahead "cerremos con lo que queda"): texts removed + complete
  transfer icons; staging manifest, 114 money-path tests, 0 production refs, no .env, sha256 OK, 2386 = 2386 files,
  BUILD_ID `zMLNPv0xnL1tHbIHGAcvY`, `anterior` -> `596cf86…`, `/login` 200, online, 0 unstable restarts.
- STATE at close (2026-10-03): staging has DB 188-192, notifier gate85 + gate85b, Cerebro gate85-cerebro-nombre +
  gate85c, app 08bce88. PRODUCTION has none of it (DB at 187, app 304a0c9); staging app now 8d46b34 (BUILD_ID 4TGs_vI2mU4ppkE---KHG, anterior 08bce88). Production plan, each step with the
  owner's go-ahead: (1) DB bundle 188, 189, 190, 191, 192 in one transaction via gate84-aplicar-db.py (BUNDLE list
  updated) + assertions cash-delivery-rate, panel-cash-recipient, panel-closing-actions, panel-notify-and-cash-name,
  force-verify-without-reason in probar mode; (2) notifier gate85-notificador.py produccion then gate85b-textos.py
  produccion; (3) Cerebro gate85-cerebro-nombre.py produccion then gate85c-cerebro-promesa.py produccion; (4) app
  08bce88 (or later) with desplegar-wacrm-produccion.sh; (5) fill Bruce 972718ea amount
  (crm_calcular_monto_destino) and the owner closes Rubislandi 30c87ea5 himself. DB first: the app and the
  notifier/Cerebro read the 191/192 signatures and column. Open: A6 (cash in the calculator, waiting for the admin),
  C (resent receipt guard).
- PRODUCTION (2026-10-03 ~04:00 UTC, owner go-ahead "pasa todo a produccion"):
  - Pre-check: the 12 functions 188-192 replace have the same md5 in production as in staging before 188 (staging
    pre-188 state rebuilt by applying ROLLBACK-192..188 in a forced-rollback transaction, closed_manually rows and new
    audit actions neutralised inside it); the efectivo_usd service text matches 188's guarded replace; one account.
  - Backup ~/wacrm-respaldos/produccion-20261003T035113Z.dump (+ .sha256, .list; 200 functions, 143 table data).
  - DB: ~/cerebro-fase1/pruebas/gate86-aplicar-db.py (gate84 route, temporary zz_wu5b_exec created and dropped):
    ensayo "efectivo=290 min=29000 muted_col=1 forzar=p_operation_id uuid, p_reason text, p_notify boolean open_ops=9"
    rolled back; aplicar {"r":"ok"}, 188-192 registered (created_by gate86); probar: cash-delivery-rate,
    panel-cash-recipient, panel-closing-actions, panel-notify-and-cash-name, force-verify-without-reason ALL PASS;
    0 fixture contacts left.
  - Notifier wGud0KGR6eMqqfMQ: production's ready_to_transfer branch is NEWER than staging's (cfg.riel from
    cerebro_riel_op 173, plural "faltan", cash without beneficiary already handled), and never had the 190
    closed_manually rule; gate85-notificador.py now inserts the mute after the incident line when that rule is absent
    and skips the no-beneficiary patch when riel handles cash (first run stopped on a marker before any PUT). Applied
    gate85 + gate85b; offline run of the production node: same 9 results as staging. Drift noted: staging notifier
    lacks production's riel logic.
  - Cerebro jEzlVLCLUaJhVwzs: gate85-cerebro-nombre.py + gate85c-cerebro-promesa.py applied; expressions parse,
    Decisor parses, tool passes $4 (name).
  - App 3f20c78 built with the production env (manifest production, 32 prod / 0 staging refs, 114 money-path tests,
    sha256 OK, p_notify present) and deployed with desplegar-wacrm-produccion.sh: served cwd ~/wacrm-releases/3f20c78…,
    anterior -> 304a0c9…, BUILD_ID y-nuLGCNQ5pFHnSNfZyvS, /login 200, online. privado/master fast-forwarded to 3f20c78.
  - Bruce 972718ea: crm_calcular_monto_destino -> 100 USD calculated; still incomplete (name, phone and address were
    never stored by the old bot; ID photo present).
  Pending: owner closes Rubislandi 30c87ea5 himself; Bruce's recipient data (offered to fill from his chat); A6; C.
- Bruce completed (2026-10-03, owner go-ahead): crm_registrar_datos_entrega_efectivo(4814cdfe…, '53904458', 'Cipres 2D
  Bajos, Cerro', NULL, 'Anabel Frenes Vera') picked 972718ea (the duplicate 591262ba has no delivery method) ->
  complete, audited; its three "Entrega en efectivo lista para coordinar" notifications (one per owner/admin) marked
  read, since that delivery was already made.
- Staging matched to production (2026-10-03): app 3f20c78 (BUILD_ID rj70Jr138tLvQAH3UyP3R, anterior 8d46b34; staging
  checks as before). Note: this staging build replaced prod-build/dist's production tarball of the same commit (the
  production release lives on the server; rebuild with the production env before reusing dist). Staging notifier
  OCdJoHTkV6S0aAdk: parameters of 'Leer secreto', 'Buscar telefono', 'Filtrar cambio de etapa' and 'Enviar por WaCRM'
  copied from production (riel via cerebro_riel_op, automation_late_deposit_verification as manual, 24 h window text vs
  template), staging credentials and URL kept (backup notificador-staging-antes-igualar-*.json); the copied config query
  runs on staging (riel efectivo_usd for the cash fixture).
- A6 DB (2026-10-03, staging): `193_calculator_cash.sql` (+ ROLLBACK), commit 99c8385. Service EFECTIVO (entries CHECK),
  efectivo_usd -> EFECTIVO; calculator_feed_operation prices an EFECTIVO line with efectivo_usd_gyd as its sale rate
  (snapshotted in usdt_sell_gyd) and the shared usdt_buy_gyd; calculator_missing_rates names efectivoUsdGyd;
  crm_resolve_pending_entry accepts efectivo_usd_gyd; completed cash remesas without a live entry are fed. Assertion
  `calculator-cash.sql` (4 cases, expectations from the live rates) RED ("efectivo_usd must map to EFECTIVO, got
  <NULL>") -> GREEN. Backfill on staging: 4a044782 -> EFECTIVO 100 USD, facturado 29,000, invertido 24,000, retorno
  5,000. Calculator regressions: calculator-entries-realtime, calculator-access, calculator-entry-correction,
  feed-matrix, financial-close, feed-from-beneficiaries, resolve-pending ALL PASS; feed-mixed case 5 fails before and
  after 193 (pre-existing); delivery-feed-evidence (deal fixture) and rounding-parity (INSERT into the view tasas)
  pre-existing. App part: writer running.
- A7 (2026-10-03, staging Cerebro U52y1kSNvhgxvWeb) via ~/cerebro-fase1/pruebas/gate87-carnet.py (same script for
  production): the four vision nodes gain CASO 4 "documento de identidad" -> {"tipo":"carnet","nombre",
  "numero_identidad"} (an app screenshot is explicitly not one; catch-all becomes CASO 5); 'Snapshot final' takes
  foto_carnet_wamid from tipo carnet only and raises the non-receipt alert for it; 'Registrar carnet efectivo' uses
  foto_carnet_wamid. Snapshot code parses. Real vision check (gate87-probar-vision.py: temporary workflow with a copy
  of the staging vision node, same prompt/model/credential) on Bruce's production images: 14:07 MMG screenshot ->
  "otro"; 14:26:44 and 14:26:45 -> "carnet" with the recipient's name. Pending: live staging test; production
  (gate87 produccion) and repoint Bruce's id_photo_wamid to the 14:26:44 image, with go-ahead.
- A6 app (2026-10-03): commit dd11329. EFECTIVO in the service union, formulas, document rates (requires usdtBuyGyd +
  efectivoUsdGyd, sells at the cash rate, floor), projection (efectivo_usd -> EFECTIVO), aged-operations mapping, the
  resolve route accepts efectivo_usd_gyd, financial-close rate label "EFECTIVO buy/sell". RED 9 -> GREEN; suite 1772;
  tsc and eslint clean. No resolve UI exists in the app (pending lines only list their missing rate names), so none
  was added; the manual shorthand calculator does not know EFECTIVO (out of scope).
