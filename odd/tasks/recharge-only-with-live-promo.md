# Feature: no recharge is opened or asked for before the promo starts

## Objective
When a customer asks about recharges and no ETECSA promo is running today, the bot gives the date and price of the
next promo (or offers an operator), and does not ask for the Cuban number or open a recharge operation.

## Problem (owner test on staging, 2026-10-04)
The fake promo ran 8–11 Oct. The customer asked by audio on the 4th; the bot announced the promo and then asked
"¿Me pasa el número de Cuba a recargar?". Causes:
- The agent's tool registrar_numeros_recarga calls crm_registrar_numeros_recarga(conv, text, p_abrir => true) (204),
  which opens a recharge operation with no promo check. Staging op b5a6d565 (collecting_information) was opened on the
  4th. An open recharge makes cerebro_recarga_en_curso true, and then the Decisor orders "Falta el NUMERO a
  recargar: pideselo". Production runs the same code (md5s equal), so any recharge question there opens one too.
- cerebro_servicio_get's upcoming-promo text says "HOY NO SE PUEDE APLICAR TODAVIA" but never forbids asking for
  the number.
The "Buenos días" in the same reply was not a bug: the customer said "Buenos días" and the Decisor rule mirrors the
customer's greeting. That is reported to the owner and not changed here.

## Scope (owner, 2026-10-04: "corrige los dos detalles del bot")
- T1 DB `207_recharge_only_with_live_promo.sql` (+ ROLLBACK): crm_registrar_numeros_recarga opens a new recharge
  only while a promo is running (cerebro_promo_vigente). Otherwise it opens nothing, saves nothing, and returns what
  to tell the customer: the next promo's date and price, or "no promo, offer an operator". An already-open recharge
  keeps working as before. cerebro_servicio_get's upcoming text forbids asking for the number before the start date.
  Assertion `supabase/staging/assertions/recharge-only-with-live-promo.sql`: RED, then GREEN on staging.
- T2 Staging: cancel the stray op b5a6d565, reset the test contact, owner re-test by audio.
- T3 Production after the owner's go-ahead.

## TDD
Strict. SQL assertion (self-reverting DO block ending in RAISE EXCEPTION 'ALL PASS').

## Progress
- [x] T1 (commit 5ef4971): the assertion was RED on staging ("case 1: got guardados 1 numero(s) de recarga nuevos").
  207 was applied to staging (schema_migrations 207 / 207_recharge_only_with_live_promo): ALL PASS. The ROLLBACK is
  pg_get_functiondef of both functions before 207 (md5 b3a6b11d... / 9a9dc7fe..., equal on staging and production).
  Updated older assertions:
  - recarga-by-audio and recarga-before-deposit assumed a recharge opens with no promo; they now set up one running
    promo.
  - promo-notice now discards leftover promos first: staging's fake 8–11 Oct promo was winning "next promo".
  All five pass on staging: recarga-by-audio, recarga-before-deposit, recarga-numbers, promo-notice,
  recharge-only-with-live-promo.
- T2 setup: the test contact was reset, which also removed stray op b5a6d565. The fake promo b4f92aa4 (8–11 Oct) is
  still confirmed. Waiting for the owner's re-test by audio.
- Owner amendment, 2026-10-04: "muchas veces el admin toma los datos antes de que la promo este activa" and payment
  "muchas veces paga en ese momento, otras no". 207 was amended (not yet in production):
  - With a confirmed upcoming promo, the recharge opens with the numbers. The reply says it is booked for the start
    date, that payment can be now or that day (never demanded now), and never "today" or "in minutes".
  - With no promo running and none confirmed ahead, nothing opens and the bot offers an operator.
  - cerebro_servicio_get's upcoming text says the recharge can be booked now on those terms; "No cobres recargas
    hasta esa fecha" is gone.
  - RED: "case 1: got NO HAY PROMOCION VIGENTE HOY..." Amended 207 re-applied to staging; ALL PASS.
- The fixtures stopped depending on existing conversations. Staging had zero after the test-contact reset, so
  recarga-by-audio, recarga-before-deposit and recarga-numbers failed on contacts.user_id.
  - Those three take the user and account from whatsapp_config + profiles.
  - recharge-only-with-live-promo creates its own conversation.
  - All 5 recharge/promo assertions pass on staging.
  - Known: calculator-recarga (not touched) still reads `FROM conversations LIMIT 1` and fails on staging while it has
    no conversations ("account_id is required").
