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
