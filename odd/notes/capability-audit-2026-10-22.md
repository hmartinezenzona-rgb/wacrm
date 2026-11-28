# Capability audit 2026-10-22 (read-only, production SELECT only)

Scope: what customers and the operators correct in production over the last 30 days (2026-09-23 to 2026-10-23), against
the agent tools that exist on staging (migrations 265-279, notes `db-tools-progress.md`, `cerebro-269-m5.md`).
No writes, no n8n change, no WhatsApp, no push. Conversations are named by the first 8 uuid chars; customer text is
paraphrased, never quoted.

## Method and limits

1. Human corrections: `remittance_admin_audit`, rows in the last 30 days (522 rows in total). Human = `action LIKE 'human%'`
   (the actor is a UUID for 415 rows, NULL for 83, and `claude-code` / `automation:*` labels for the rest; the action prefix is
   the only clean split). Calculator rows (`human_calculator_*`, 111 rows) and `human_delivery` (179 rows, normal
   delivery marking) are excluded: they are not customer requests.
2. Customer change requests: 34 customer messages in 26 conversations matched the change-word filter. Most matches are
   pasted Zelle/recipient templates (operator copy-paste), not requests. The sample is widened to the 28 conversations that
   have a human correction in the window (union of both sets). Only the first 10 customer messages per conversation were read.
   This is a sample, not the full population, so frequencies below come from the audit and the sample is for kind mapping only.
3. Caveat: the audit records what humans changed, not what customers asked. Some corrections are internal (verification,
   manual close, deleted test rows). They are listed because they show what the bot cannot do.

## Corrections by kind (audit, 30 d, human actors)

| kind | rows | operations | example conv ids |
|---|---|---|---|
| operation status: manual close / forced or deposit verification / deleted | 25 + 15 + 14 + 13 + 12 = 79 | ~50 | 4afda26a, 9563e3df, 54d6444d, 0949c5a9, faaa62ea |
| amount of an operation (`quoted_source_amount` 7, `quoted_destination_amount` 8, `quoted` 1) | 16 | 7 | de846b30, 422f0e93, c2bb35c0, faaa62ea |
| amount of a recipient (`amount`, incl. combined) | 5 | 4 | f8b7779c, b341b43a |
| service change (`service` 7, `service_type` 6, `mexico_manual` 1) | 14 | 13 | 4afda26a, 54d6444d, b3334214, c2bb35c0, 1232671b |
| destination / destination currency (`destination` 6, `destination_currency` 4) | 10 | 9 | (see audit row ids; no customer text) |
| recipient name / type / phone / zelle account / id photo | 8 + 7 + 1 + 3 + 3 + 2 = 24 | 15 | 9e338224, a3e6b58e, a6d28009, d4bc3879, faaa62ea, fe5cf541 |
| recipient moved to another operation (`operation_id`) | 1 | 1 | 1232671b |
| deposit moved (`depositos_mmg` consumido_en / operation_id) | 3 | 3 | (admin only) |
| split / merge / admin lock (`mixed_split` 2, `admin_locked_fields` 1, `combo_costo_gyd` 1) | 4 | 4 | f8b7779c, faaa62ea, c2bb35c0 |
| cup remaining (`cup_lots`) | 2 | - | (no conversation) |
| recipients added by humans (bot did not add them) | 7 + 3 + 1 = 11 | 9 | 774cad3d, b341b43a, bce2fd6b, d9e9f333, 54d6444d |

## Request kinds from customer messages (sample, 28 conversations)

Real change requests found in the sample (paraphrased): switch the payout method (cash vs transfer vs Zelle), send a different
amount to each recipient ("X to one, Y to the other", "the rest to this card"), change the amount of a pending send, correct a
recipient account or name, recharge a different number set, cancel ("forget it"). Most others are data entry (accounts, cards,
addresses), which the existing recipient tools already handle.

## Table (requested layout)

Frequency = human corrections in the audit (30 d) for the kind; sample count = customer messages in the 28-conversation sample.
"Tool to extend" names the existing tool that owns the domain. No new tool unless no existing one owns it.

| request kind | frequency (30 d) | example conv ids | agent tool today | gap | tool to extend (or new general tool) \| capability to add \| DB rules |
|---|---|---|---|---|---|
| change amount of a pending send (before or after deposit) | 16 operation + 5 recipient = 21 | de846b30, 422f0e93, c2bb35c0, faaa62ea | none for amount (`calcular_usd` only quotes; no write on an existing operation) | the bot cannot change `quoted_source_amount` / `quoted_destination_amount` | **new general tool `modificar_operacion`** (it owns amount, cancel and move; no existing tool owns operation edits) \| `accion=monto` with `monto`, optional `op` \| amount > 0; status not completed/cancelled; if a deposit is verified and the new amount exceeds it, do not write, state the gap; quote recalculated with the same rate |
| cancel a send before deposit ("forget it", "no lo quiero") | 13 deleted + 25 manual close (subset) | 0949c5a9, 4098601d, 21c32058 (msg only) | none | no cancel path; humans delete or close in the panel | `modificar_operacion`, `accion=cancelar` \| refuses after any verified deposit or completed/delivered status; releases recipients and deposit to the conversation; writes audit row with actor `agent:...` |
| change payout service (cash / transfer / Zelle / Mexico / recarga) | 14 (service + service_type + mexico_manual) | 1232671b, 4afda26a, 54d6444d, b3334214, c2bb35c0 | `cambiar_servicio`, `marcar_destino_usd`, `declarar_servicio` | service-blind resolver: with two operations open it re-types the wrong one (staging note, gap 6) | extend `cambiar_servicio` with service-aware target (250 rule) and absorb `marcar_destino_usd` into it \| the target is the operation whose service matches the request; never the Mexico/recarga operation when the request is a cash/Zelle change \| service must be in the allowed list; recipients re-typed to the new rail or the request is refused |
| send different amounts to each recipient ("X to A, Y to B", "rest to this card") | 3 (beneficiary amount) + 2 (mixed_split) = 5 | f8b7779c, faaa62ea, b341b43a | `repartir_envio` (after deposit), `registrar_beneficiario_zelle` (several recipients, 274) | no per-recipient amount before deposit; `repartir_envio` refuses before deposit (gap 3, migration 277 planned) | extend `repartir_envio` with a before-deposit mode and `monto` per recipient \| sums must equal the operation total in the same currency \| deposit may be partial, the rest is asked, never invented |
| correct recipient name / Zelle account / phone / card | 8 + 2 + 1 + 1 + 3 (photo) = 15 | 9e338224, a3e6b58e, a6d28009, d4bc3879, fe5cf541 | `gestionar_beneficiario`, `registrar_beneficiario_zelle` (replace or by position) | covered in part: replace-by-account works; a second recipient with an unknown account is refused until `agregar` is used (274) | extend `gestionar_beneficiario` and `registrar_beneficiario_zelle` (no new tool) \| `posicion`, `agregar`, `corregir` already exist \| account normalised; name stored as typed; one active recipient per slot |
| move a recipient to another operation | 1 (operation_id) | 1232671b | none | the bot cannot move a recipient between operations (service-blind target) | `gestionar_beneficiario` with `op_destino` \| source and target share the conversation; never move a recipient already paid |
| move a deposit to another operation | 3 (depositos_mmg consumido_en / operation_id) | admin only | none | by design this is money matching; the bot should not do it | keep human-only; flag as owner decision (see Questions) |
| split or merge operations (two sends into one deposit, or one into two) | 4 (mixed_split, admin_locked_fields, combo cost) | f8b7779c, faaa62ea, c2bb35c0 | `repartir_envio` (after deposit) | no merge; split before deposit refused (277) | extend `repartir_envio` (split) and `modificar_operacion` `accion=unir` (merge) \| same customer, same conversation, both operations open, no delivery yet \| mixed_group_id set; deposit total unchanged |
| recharge number set changed (remove or add numbers) | 10 (recarga_numbers automation) + sample | e4ecff7b, bce2fd6b | `registrar_numeros_recarga` (add, dedupe) | no remove path; the customer says "all except the crossed-out one" | extend `registrar_numeros_recarga` with `accion=quitar` \| only on an open recarga; no delivered number removed |
| deposit mismatch: "rest to this card" / deposited more or less | 7 (sample) | 68a00ea7, c4606f95, 9563e3df | none | the bot asks, but no tool writes the chosen split | extend `repartir_envio` (see split row) \| sums checked against the verified deposit amount |

Verification and close rows (status changes by humans, 79 rows) are operator work, not customer asks. They are not gaps
for the bot and are excluded from the toolset decision.

## Resulting toolset (small list)

1. `gestionar_beneficiario` (extended: `op_destino`, correction by name or type).
2. `registrar_beneficiario_zelle` (already extended: several recipients; keep).
3. `registrar_numeros_recarga` (extended: `quitar`).
4. `cambiar_servicio` (extended: service-aware target; absorbs `marcar_destino_usd`).
5. `repartir_envio` (extended: before-deposit mode, per-recipient amount, split).
6. `modificar_operacion` (NEW, general: `monto`, `cancelar`, `unir`; one tool for the operation domain).
7. `calcular_usd`, `declarar_servicio`, `registrar_destinatario_mexico`, `registrar_datos_entrega_efectivo`, `agregar_servicio`: unchanged.

Merge or remove:
- Merge `marcar_destino_usd` into `cambiar_servicio` (same domain, same resolver problem).
- `registrar_destinatario_combo` and `registrar_destinatario_mexico` stay separate: different rails with their own validation.
- No deposit-move tool (human only).

## Questions for the owner

1. Should the bot be allowed to cancel an operation before the deposit, or only the operator (cancel is a money-side action)?
2. Should moving a deposit between operations stay human-only? (Recommended: yes.)

## Real-shaped test cases (made-up names and numbers)

Same structure as `odd/notes/cerebro-s5b-casos.md`. Send from a PRUEBA contact to the STAGING number; readers off.

## A - Alba (amount change before deposit)
1. "Quiero enviar 100 USD por Zelle a Ruben Ortiz" -> declarar zelle; asks account.
2. "Cuenta ruben.ortiz@example.com" -> registrar_beneficiario_zelle.
3. "Mejor que sean 150, no 100" -> modificar_operacion accion=monto monto=150 (operation has no deposit yet).
Pass: one open operation, quoted_source_amount 150, recipient unchanged, audit row actor agent.

## B - Bruno (cancel before deposit)
1. "Quiero enviar 60 USD por transferencia a Lucia Mora" -> declarar clasica; asks data.
2. "Cuenta 9000 1111 2222 3333, celular 5551 0000" -> gestionar_beneficiario.
3. "Ya no, olvidalo, cancela el envio" -> modificar_operacion accion=cancelar.
Pass: operation cancelled, cancelled_at set, no deposit touched, no WhatsApp to a third party.

## C - Carmen (two recipients, amounts per recipient before deposit)
1. "Voy a mandar 300 USD por Zelle a dos personas" -> declarar zelle.
2. "Pedro Vidal pedro@example.com" -> registrar_beneficiario_zelle (position 1).
3. "Y Sofia Rivas sofia@example.com, 200 a ella y 100 a Pedro" -> registrar_beneficiario_zelle agregar=true monto=200; registrar_beneficiario_zelle monto=100 posicion=1.
Pass: two Zelle recipients with amounts 200 and 100; sum 300 equals the operation total.

## D - Dario (service change, transfer to cash)
1. "Quiero mandar 80 USD por transferencia a Elena Paz" -> declarar clasica; asks data.
2. "Cuenta 4000 2000 3000 4000" -> gestionar_beneficiario.
3. "Mejor en efectivo en la Habana, no por transferencia" -> cambiar_servicio servicio=efectivo_usd (target: the clasica operation; no Mexico or recarga operation open).
Pass: operation service efectivo_usd, recipient re-typed to cash, other operations untouched.

## E - Esteban (remove a recharge number)
1. "Quiero recargar tres numeros a Cuba" -> declarar recarga.
2. "55501111, 55502222, 55503333" -> registrar_numeros_recarga.
3. "Quita el 55502222, ya no" -> registrar_numeros_recarga accion=quitar numero=55502222.
Pass: recarga open, numbers 55501111 and 55503333 remain, 55502222 removed, no delivered number changed.

## F - Fabiola (correct recipient name)
1. "Quiero enviar 90 USD por Zelle a Marta Gil" -> declarar zelle.
2. "Cuenta marta.gil@example.com, nombre Marta Gil" -> registrar_beneficiario_zelle.
3. "No, el nombre es Marta Gil Vega, no Marta Gil" -> registrar_beneficiario_zelle corregir (same account, name changed).
Pass: one Zelle recipient, name "Marta Gil Vega", account unchanged.
