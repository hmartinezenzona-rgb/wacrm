# S5b cases: Cerebro staging WITHOUT the automatic readers (PRUEBA scripts)

Send each script, in order, from a PRUEBA contact to the STAGING WhatsApp number (fixtures: `wacrm-probar-staging`; the owner sends, the
workflow is never run from here). All data below is made up. Deposits are MMG receipts: attach a test receipt for the stated amount.
Expected = what must be true in the database and in the bot's answers, checked with `wacrm-investigar-conversacion` (read-only).
Readers off: Registrar beneficiario auto, Registrar zelle auto, Registrar destino auto. Deposit registration stays automatic.

## K - Katiuska (recarga after a phone-only remesa; incident 1232671b)
1. "Hola, quiero hacer una recarga a Cuba" -> expect declarar_servicio('recarga') (audit/declared row), bot asks the number.
2. "55599180" -> registrar_numeros_recarga (p_abrir, actor agent:registrar_numeros_recarga); ONE recarga operation.
3. Receipt 6,200 GYD (the live promo price) -> deposit attaches to the recarga; no remesa created, no second empty recarga.
Pass: exactly one open operation, service recarga, number saved, deposit on it.

## C - Clarita (faaa62ea: Zelle names overwritten by the reader)
1. "Quiero enviar 100 USD por Zelle a dos personas" -> declarar zelle; asks name + account of each.
2. "Maria Lopez maria@example.com" -> registrar_beneficiario_zelle (name and account exactly as typed).
3. "La segunda: Juan Perez 5551234567" -> registrar_beneficiario_zelle again (second recipient position).
4. "Se ve bien" -> NO tool call that stores it as a name.
Pass: two Zelle recipients with the typed names; no 'Se ve bien'.

## M - Marlene (4afda26a: one 71,200 deposit for Mexico + cash + card; the bot took 150 USD)
1. "Voy a mandar 150 dolares a Mexico, 100 en efectivo a Cuba y 15 mil por transferencia a Cuba" -> declarar mexico, quote via=mexico,
   asks CLABE+banco+titular (or Coppel/BBVA), cash data, card data.
2. CLABE 012345678901234567, "Mercado Pago", "Ana Perez" -> registrar_destinatario_mexico (mexico_cuenta).
3. Cash and card data -> registrar_datos_entrega_efectivo / gestionar_beneficiario; split with repartir_envio when the customer confirms.
4. Receipt 71,200 GYD -> the bank verifies LESS than the agreed total: expect "DEPOSITO DISTINTO DE LO ACORDADO" behaviour: the bot asks which part
   changes ("Su depósito de 71,200 cuadra con 100 USD a México, no con 150; ¿confirma?") and never says "se transfiere el equivalente".
Pass: Mexico recipient stored (clabe, bank, holder), parts reconcile by a question, no payout promise before the answer.
(The reconcile note needs the parts as a mixed group with `usd` per part; if the split is not a group, record that gap.)

## F - f8b7779c (Clasica 18,200 + recarga 6,200 on ONE deposit of 24,400)
1. "Quiero enviar 70 USD por Clasica y ademas una recarga" -> declarar clasica; agregar_servicio('recarga').
2. Clasica data (card 9205123456789012, phone 53821203) -> gestionar_beneficiario; recarga number 55599180 -> registrar_numeros_recarga.
3. Receipt 24,400 GYD -> expect the "deposited more than said" note with the split question; customer confirms "18200 y 6200" ->
   repartir_envio("clasica 18200, recarga 6200").
Pass: one mixed group, two operations (clasica 18,200 / recarga 6,200), each with its data.

## Re-enable the readers
`python3 pruebas/herramientas_269/aplicar_staging.py --esperado <live versionId prefix> --lectores on` (nodes enabled again, prompt section removed), or
`python3 infra/n8n/cerebro_n8n.py restaurar staging <backup before S5b> --esperado <live versionId prefix>`.
