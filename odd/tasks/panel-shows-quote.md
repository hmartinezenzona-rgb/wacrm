# The operations panel shows the bot's current quote

Objective: before any deposit, the client panel shows what the bot quoted for the remesa ("Cotizado: 5,000 GYD ->
15,000 CUP"), so an operation opened from beneficiary data no longer looks like 0 GYD with nothing asked.

Why (owner, 2026-10-02, after the staging retest of gate 83): the remesa opened with the card shows 0 GYD although the
bot already quoted. `quoted_source_amount` is the DEPOSITED amount (cerebro_registrar_deposito overwrites it with the
total), so the quote cannot go there. Fixing a CUP target the calcular_usd way would create the "deposito de mas"
Incidencia the owner does not want (Engram `remesa/deposit-above-quote-behaviour`). So the panel READS the quote.

Source: `cerebro_cotizacion` (171, both environments): the latest quote per conversation (gyd + the bot's text),
written by a trigger on the bot's messages; valid like `cerebro_cotizacion_vigente` (cotizacion_ventana_horas, after the
last closed remesa). The destination ("*15,000 CUP*", "*100 USD*") is read from that text. `cerebro_ultima_cotizacion`
exists only on staging, so it is not used.

Design: migration 187 `crm_cotizacion_de_conversacion(p_conversation_id)` -> (gyd, destino_monto, destino_moneda,
cotizado_en), SECURITY DEFINER, same 42501 authorization as crm_operaciones_de_conversacion (viewer), read-only. The
API route GET /api/remittance-operations returns it as `quote`; the panel shows it on the open operation.
Scope: staging first, production with go-ahead (DB + app deploy). TDD on: SQL assertion (self-reverting) + vitest.

## Tasks
- [ ] T1 Assertion + migration 187 (+ rollback): RED, GREEN, staging
- [ ] T2 App: route returns `quote`, types, panel line "Cotizado: X GYD -> Y CUP" on the open operation; vitest RED/GREEN
- [ ] T3 Staging deploy (DB + app), owner check; then production with go-ahead

## Acceptance
- A conversation where the bot said "Para que lleguen *15,000 CUP* necesita depositar *5,000 GYD*" -> the panel shows
  5,000 GYD -> 15,000 CUP before any deposit; no target, status or amount on the operation changes.
- A quote older than the window, or from before the last closed remesa, is not shown.

## Progress / evidence
