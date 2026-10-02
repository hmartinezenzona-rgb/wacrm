# Destination amounts are inverse quotes; a lone card opens the remesa

Objective: when the customer says how much the beneficiary RECEIVES in a destination currency ("15 mil CUP",
"30 mil pesos cubanos", "100 USD por Zelle", "50 dolares en la Clasica/Tropical"), the bot quotes the deposit
(inverse calculation), whatever the verb (enviar, mandar, recibir); and a card given alone is saved at once with
`gestionar_beneficiario`, which opens the remesa, asking for what is missing.

Problem (owner's production test 2026-10-02 13:03 UTC, exec 304592, conv 40e6ab76): voice "quiero enviar 15 mil
CUP a esta tarjeta" + the card. The bot answered "Por 15,000 GYD llegan 45,000 CUP" and saved nothing.
- The agent prompt (since 2026-08-12, "prompt tanda 2B") says: "Frase con 'enviar' ... + monto, con moneda de
  destino YA dicha (CUP) -> calcular_envio(monto, gyd)"; the model's stored reasoning cites it. The Decisor's
  DIRECCION DEL CALCULO note only knows "que le llegue" / "cuanto llega" phrasings.
- Gate 79 (2026-10-01) made the tools accept partial data, but the Decisor `datosAMedias` note still says "falta
  un dato, y hasta que no esten los dos NO se registra nada"; the model did not call gestionar_beneficiario.
- Latency (92 s in one DeepSeek call) is out of scope here (timeout + retry is a follow-up).
Engram: `production/test-2026-10-02-cup-as-gyd`.

Owner rules (2026-10-02): an amount the customer wants RECEIVED in a currency (CUP, or USD by Zelle, Clasica,
Tropical...) is an inverse calculation; a card plus the amount must already create the remesa.
Tools: CUP -> `calcular_inverso(cup_deseado, gyd)`; USD Zelle/Clasica/Tropical -> `calcular_usd(usd)` (also sets
the target); cash USD has no calculator (other rate, human) -> stated as received, no calculation.

Scope: Decisor (new deterministic note; DIRECCION DEL CALCULO yields to it; datosAMedias note rewritten) and the
agent prompt (calculation rules), staging Cerebro first, then production with the owner's go-ahead.
Constraints: strict TDD; Decisor bank (193 cases) unchanged except the intended notes; real replay of the owner's
burst with DeepSeek on a temporary agent with neutral write tools; drift-checked PUT with rollback snapshot.
TDD: on (user global config). Runners: node Decisor bank; python replay harness (gate76/77 helpers).

## Tasks
- [x] T1 Decisor: MONTO DE DESTINO note (CUP / USD rail / cash USD), DIRECCION DEL CALCULO yields; bank RED/GREEN
- [x] T2 Decisor: datosAMedias note tells the model to save what it has now (card -> gestionar_beneficiario,
      Zelle -> registrar_beneficiario_zelle; a lone phone only for a remesa, not a recarga); bank RED/GREEN
- [x] T3 Prompt: the 'enviar + monto + CUP' rule limited to GYD/bare amounts; new line for destination amounts
- [x] T4 Real replay of exec 304592's burst (base vs candidate, 3 reps): candidate calls calcular_inverso(15000)
      and gestionar_beneficiario(card), says "Para que lleguen 15,000 CUP necesita depositar 5,000 GYD"
- [ ] T5 Deploy staging, owner retest on staging; then production with go-ahead

## Acceptance
- "quiero enviar 15 mil CUP" -> deposit 5,000 GYD quoted; "100 USD por Zelle" -> calcular_usd(100).
- A written card alone -> gestionar_beneficiario called in the same turn; remesa open with the card.
- Bank: no other Decisor case changes.

## Progress / evidence
- T1-T3 (2026-10-02): `~/cerebro-fase1/pruebas/gate83-destino.py` (construir|desplegar [prod]), block
  `gate83-decisor-bloque.js` (MONTO DE DESTINO before DIRECCION DEL CALCULO, which yields when a destination amount is
  found; skipped for a reparto and a recarga), datosAMedias note rewritten (card -> gestionar_beneficiario now; Zelle ->
  registrar_beneficiario_zelle; lone phone only for a remesa; a customer waiting for a third party is not asked again),
  prompt: destination-amount line + the 'enviar + monto' rule limited to GYD/bare amounts. Bank `gate83-banco.js`: 14 new
  cases (exec 304592's real inputs, CUP, "30 000 cup", "cuanto le llega si mando 15000 cup", USD Zelle/Clasica/no rail,
  cash USD, bare, GYD, recarga, card alone, card while waiting, lone phone): 11 RED on the live Decisor, 14/14 GREEN; the 3
  negative guards passed before and after. 193 bank cases: 186 identical, 7 differ only in the datosAMedias note (checked
  one by one), 0 broken. Production and staging candidate Decisors byte-identical.
- T4 (2026-10-02, `gate83-replay.py 3`, DeepSeek, temporary agents, neutral write tools): live prompt + live Decisor 0/3
  (calcular_envio(15000 gyd) 3/3, "Por 15,000 GYD llegan 45,000 CUP", card saved 1/3, 78-172 s); candidate 3/3
  (calcular_inverso(15000, gyd) + gestionar_beneficiario(card) 3/3, "Para que lleguen 15,000 CUP necesita depositar
  5,000 GYD", 15-53 s). Memory rows deleted (32, 0 left); production fingerprint identical.
- T5 staging (2026-10-02): drift-checked PUT, only `Decisor` and `Agente Remesas` changed, byte-verified; active version
  ec691647-9593-411b-9b8f-4180a12eab7d; rollback `ROLLBACK-83-staging-20261002-073245.json`. Staging test number reset.
  Pending: owner's retest on staging, then production with go-ahead (`construir prod`, `G83=prod node gate83-banco.js`,
  `desplegar prod`).
