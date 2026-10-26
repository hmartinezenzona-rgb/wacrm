# Design: no service without data

Status: PROPOSAL, not implemented. Written 2026-10-26 after the Yoandrys case (a6d28009) and the
fran garcia split (68a00ea7). Owner rule: the bot verifies the deposit and waits; a service is
created only when the customer's data or words say what it is. Nothing here is deployed.

## 1. Problem

Today a service can be created from two things that are not the customer's choice:

1. **A price quote.** `cerebro_cotizar` names the service and `_cerebro_declarar_implicito` records
   the quoted amount through `_cerebro_operacion_declarada`, opening one operation per quoted channel.
   The prompt asks the bot to quote the four channels (Zelle, Clasica, Tropical, cash), so a
   comparison quote becomes a declared send. Yoandrys 2026-10-26: quoting Zelle and Clasica at 13:11
   left a Clasica operation (286,000 GYD) that the owner cancelled at 13:30.
2. **A declared service applied to data that belongs to another rail.** The card arrived at 13:34
   while Clasica was declared; `cerebro_resolver_para_guardar` opened the card operation typed as
   Clasica. The split wanted `cuban_card`, did not find it, and created a second operation
   (`e07931d9`) while the beneficiary stayed on the orphan (`f9b6ec33`).

The same family produced the false "faltan 10,000 GYD" at 13:37 (the parts note summed the holder's
own part, not the group deposit) and the delivery of a 1,100 USD Zelle with 800 + 200 USD of
recipients (14:24), which left the 100 USD recipient to arrive after the operation was closed.

## 2. Principles

1. **Verifying a deposit is independent of knowing its destination.** The receipt is read, crossed
   with the bank mail, and recorded. No service is needed for that.
2. **A service is created from the customer's data or words, never from a quote.** A Zelle account
   says Zelle; a card with a phone says "Cuban card" (family); a CLABE says Mexico; a phone with an
   explicit top-up intent says recarga. A price query says nothing.
3. **When the data does not decide, the bot asks.** It never defaults silently. A card number does
   not say CUP or USD; a phone alone does not say card or top-up.
4. **The money is never lost.** The verified deposit lives in an operation until it is assigned or
   split. An unassigned deposit is a normal state, not an error.
5. **Multi-part sends are split from the customer's allocation** ("100 to this one, 100 to this one,
   5,000 GYD to this one"), never from a guess.

## 3. Target state

### 3.1 The deposit holder

A verified deposit is recorded in an operation with **no rail**: `service_type = 'remesa'`,
`delivery_method IS NULL`, no vigente beneficiaries. This is the existing shape of a fresh operation;
what changes is that nothing types it before the customer does.

The resolver exposes it explicitly:

- `sin_via = true` when the open operation holds money, has no `delivery_method`, no beneficiary that
  implies a rail, and no group. Today `cerebro_riel_op` returning null is read as "remesa", which the
  Decisor then treats as a service. The new flag separates "not known yet" from "remesa".
- The panel shows it as **"Sin destino"** (label only, no schema enum change).

### 3.2 What assigns a service

| Evidence | Service assigned | Notes |
|---|---|---|
| Zelle account (email or US phone) | `zelle` | The account itself is the evidence |
| Card + phone, customer said CUP or nothing? | see open decision D1 | The card family is known; the currency may not be |
| Card + phone, customer said Clasica / Tropical | `clasica` / `tropical` | Explicit word required |
| CLABE / Mexican bank | `mexico` | Account type implies it |
| Phone + explicit top-up words | `recarga` | The intent is explicit, not inferred from the phone |
| Address + carnet + explicit cash words | `efectivo_usd` | Explicit intent |
| Combo / visa / saldo movil | the service | Explicit intent only |
| Explicit `declarar_servicio` / `agregar_servicio` / `cambiar_servicio` | the chosen service | The customer's choice, audited |
| `repartir_envio` with parts | each part's service | Parts come from the customer's allocation |

A quote, an objective, or an amount never assigns a service.

### 3.3 The objective without an operation

A quote or a stated amount may live at conversation level (`cerebro_ultima_cotizacion`,
`cerebro_objetivo_envio`) without opening an operation. The deposit can be compared against it. The
operation is opened when the first piece of destination data arrives or the customer chooses a
service.

## 4. Changes by component

### 4.1 `cerebro_cotizar`

- Remove the implicit declaration and the agreed-amount write. A quote records the quote and the rate
  only.
- Keep `cerebro_fijar_objetivo` only under its current commitment rules (a beneficiary, a declared
  service, or a receipt already exists). A pure comparison quote fixes no objective.

### 4.2 `_cerebro_declarar_implicito` / `cerebro_declarar_servicio`

- The implicit helper is removed from the quote path. Declarations come from explicit tools only.
- `cerebro_declarar_servicio` keeps opening an operation when an amount is agreed, because that call
  is the customer's explicit choice (or the bot's explicit act on it).

### 4.3 `cerebro_registrar_deposito` / the crossing

- Attach the deposit to the conversation's open holder without typing it. If an explicit declaration
  exists, it may type the holder; a quote-derived declaration does not exist any more.
- A deposit with no destination stays `sin_via`; the bot confirms it and asks.

### 4.4 The beneficiary writers

- `cerebro_guardar_zelle`: target or open a `zelle` operation; if the only open operation is an
  unclassified holder, type it `zelle` as part of the write.
- `cerebro_guardar_beneficiario`: target or open the card operation according to the explicit words
  (CUP / Clasica / Tropical); with no currency word, see D1.
- The split (`_repartir_envio_core`) is the only path that assigns several services to one deposit.

### 4.5 The resolver

- Add `sin_via` (3.1). Keep `deposito_grupo_gyd` (327) and `reparto_pendiente` (325).
- Do not derive a default rail from the absence of data.

### 4.6 The Decisor

- When the holder is `sin_via`: confirm the deposit and ask one open question ("¿A dónde quiere que
  se envíe?"). Never name a channel as if it were chosen.
- When a part is assigned and money remains: state the remainder and ask.
- Keep the mandatory `repartir_envio` (325) and the general guard (326).
- Keep the Zelle delivery gate (328).

### 4.7 The prompt

- Replace the "quote the four channels with `calcular_usd`" example with "ask which channel; quote
  only the one the customer is considering or ask for the price of each without declaring". The tool
  no longer declares, but the example should stop teaching the wrong habit.
- Add: "un comprobante sin destino se confirma y se pregunta; no se asume la via".

## 5. Worked flows

### 5.1 Deposit, then nothing

Receipt verified → holder with the money, `sin_via` → "Su deposito de X GYD quedo verificado. ¿A
donde quiere que se envie?" No operation is typed. No Clasica, no Zelle.

### 5.2 Deposit, then the customer allocates three parts

"100 a esta cuenta Zelle, 100 a esta otra y 5,000 GYD a esta tarjeta":

1. Zelle account 1 → a `zelle` part for 100 USD (26,000 GYD if the rate is 260).
2. Zelle account 2 → a second Zelle recipient on the same part or a second part, per the customer's
   words.
3. Card + phone → the card part for 5,000 GYD (15,000 CUP).
4. When the parts are known and sum the deposit, `repartir_envio` groups them. If only some are
   known, the rest stays `sin_via` and the bot asks for it. Nothing is typed in advance.

### 5.3 Deposit and one Zelle account

Zelle account → the holder is typed `zelle`; if the deposit covers the amount asked, the operation is
ready. If it exceeds it, the remainder stays unassigned and the bot asks.

### 5.4 Card without currency

Card + phone, no word about CUP or USD → ask. D1 decides whether the default is CUP or always ask.

### 5.5 Phone alone

A phone alone does not say card or top-up → ask. D2.

## 6. Invariants and edge cases

- A price quote never creates or types an operation.
- A deposit is never rejected for lacking a destination; it is held.
- A delivery (status completed) requires the recipient amounts of a Zelle operation to add up (328).
- The completion notice never fires for an operation whose service is unknown.
- Existing typed operations are unchanged; no backfill.
- Corrections remain audited; no silent overrides.

## 7. Phases

- **Phase 0 (done):** 325 (reparto_pendiente), 326 (sin_dinero), 327 (group deposit, comparison
  quotes), 328 (Zelle delivery gate).
- **Phase 1:** quotes stop declaring and opening operations; prompt example updated; eval battery
  subset for quotes.
- **Phase 2:** deposits land `sin_via`; resolver flag; Decisor asks; panel label.
- **Phase 3:** writers type from data; split from allocation; ambiguity questions.
- **Phase 4:** measurement: eval battery cases for the five flows, staging fixtures, corpus
  post-deploy (quotes per send, phantom operations, unassigned deposits).

## 8. Acceptance criteria

- A deposit alone produces a verified holder with `sin_via` and no typed operation.
- Quoting four channels leaves exactly one operation (or none) and no declaration from the quotes.
- A Zelle account types the part `zelle`; a card with an explicit CUP word types it `cuban_card`.
- A multi-part allocation splits only when the parts sum the deposit; the remainder stays `sin_via`.
- No operation is completed with unassigned money in a Zelle (328).
- The corpus shows zero phantom operations per comparison quote after Phase 1.

## 9. Open decisions for the owner

- **D1. Card without a currency word:** always ask CUP / Clasica / Tropical, or default to CUP and
  name it in the confirmation? The rule says ask; the current product defaults to CUP.
- **D2. Phone alone:** always ask whether it is a top-up or a card phone, or infer from the nearby
  words when they are explicit ("recargame").
- **D3. The panel label** for an unclassified holder: "Sin destino" vs "Remesa sin destino" vs
  "Deposito verificado".
- **D4. The 100 USD Suri record** on the completed `e4c2a15b`: leave it, or add the third recipient
  with an audited correction.

## 10. Non-goals

- Changing the panel's transaction flow or the calculator.
- Backfilling historical operations.
- Replacing `repartir_envio` or the planned-split mechanism.
- Making the bot ask about every field; the deposit confirmation stays immediate.
