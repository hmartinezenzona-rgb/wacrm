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
- [x] T3 Production after the owner's go-ahead.

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
- cerebro_recarga_anotada_para(conv) (commit ad892de) returns 'DD/MM' when the open recharge was taken ahead of a
  confirmed promo. Assertion RED ("function does not exist"), then ALL PASS. All 5 recharge/promo assertions pass.
- Cerebro staging: gate104 (~/cerebro-fase1/pruebas/gate104-recarga-anotada.py; backup
  cerebro-staging-antes-104-20261004T115608.json).
  - 'Contexto conversacion' carries recarga_anotada_para.
  - 'Ultima cotizacion' says the recharge can be booked ahead of a confirmed promo (it used to say "HOY NO hay
    recargas").
  - The Decisor's verified state for a booked recharge says "se hace el DD/MM", plus a note that forbids "hoy /
    enseguida / en breve / en minutos / en cuanto abramos".
  - The agent's verified-deposit line for a booked recharge says "su recarga queda anotada para el DD/MM".
  - Checks: the Decisor and the agent expressions parse (node --check). Both SQL queries ran on staging: Ultima
    cotizacion gives "HOY NO se hacen recargas todavia: la proxima promocion de Etecsa empieza el 08/10 ...". The
    published version equals the active one.
- Waiting for the owner's re-test: ask by audio, give the number, optionally pay.
- T2 PASSED (owner re-test, 2026-10-04 17:58–18:02Z, fake promo 8–11 Oct):
  - Audio question -> "Sí hacemos recargas a Cuba, aunque hoy todavía no se pueden hacer. La próxima promoción de
    Etecsa empieza el 08/10 ... Si la quiere, la dejamos anotada desde ya. ¿Me pasa el número de Cuba a recargar?"
  - Audio + "53821203" -> "Anotado. Su recarga para el *53821203* queda para el 08/10 ... Puede pagar ahora o ese día,
    como prefiera."
  - Panel: recharge a6e2612a, collecting_information, beneficiary 53821203; cerebro_recarga_anotada_para = '08/10'.
  - Greeting "Buenas tardes" at 13:58 Guyana time (the customer did not greet with a day part).
  - Seen, not changed: the recharge opened on the first audio, a mere question (204's tool rule "llamala EN CUANTO
    entiendas que quiere RECARGAS"). A customer who only asks leaves an empty recharge open in the panel. The paid
    path (deposit verified on a booked recharge) was not exercised.
- T3 PRODUCTION (owner go-ahead 2026-10-04 "si, pásalo a producción"):
  - DB backup ~/wacrm-respaldos/produccion-20261004T180553Z.dump (sha256 be766117bed6e876...; 2132 list entries).
  - Pre-check: crm_registrar_numeros_recarga b3a6b11d..., cerebro_servicio_get 9a9dc7fe..., cerebro_recarga_anotada_para
    absent. Temp helper zz_wu5b_exec created.
  - ~/cerebro-fase1/pruebas/gate105-aplicar-db.py: ensayo md5s equal to staging (382750b1... / 7aedef56... /
    6ceb1015...); aplicar OK (schema_migrations 20261004180855 207_recharge_only_with_live_promo).
  - probar: recharge-only-with-live-promo, recarga-by-audio, recarga-before-deposit, recarga-numbers and promo-notice
    are all ALL PASS (rolled back; no leftover test contacts or promos).
  - Helper dropped. cerebro_recarga_anotada_para ACL: service_role only.
  - Cerebro prod jEzlVLCLUaJhVwzs: gate104 produccion (backup cerebro-produccion-antes-104-20261004T121037.json). The
    dry run's Decisor and agent expressions parse; published (versionId == activeVersionId); ctx, cotiz, decisor and
    agente markers present.
  - Production has no promo today (proxima 0, vigente 0): the bot says there is no confirmed promo and offers an
    operator; no recharge opens.
  - Pending: the first real recharge chat in production after the change.
