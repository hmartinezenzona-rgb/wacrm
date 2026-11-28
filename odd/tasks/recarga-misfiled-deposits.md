# Feature: a deposit is filed as a recharge only when a recharge is possible

## Objective
A customer who mentioned a recharge and then pays for something else (a Zelle, a cash delivery, a remesa) gets that
deposit filed as what it is, not as a recharge.

## Problem (found 2026-10-04, read-only, production)
- Op 89f6df7e (conv d9e9f333, Yilian, 2026-10-02 17:39):
  - She asked "Tiene promocion de recarga de telefono" and the bot said there was no confirmed promo.
  - 24 minutes later she sent a receipt, "320 Zelle" and the Zelle account of Liudis Aguilar Rojas. The deposit
    (83,200 GYD) was filed as service_type 'recarga' with delivery_method zelle.
  - The bot confirmed the Zelle correctly and the admin sent it at 18:18, but the op is still 'ready_to_transfer' as a
    recharge and never reached the calculator.
- Op 12510beb (conv f8b7779c, Yusmila, 2026-09-23 19:52):
  - Cash delivery of 50 USD in La Habana negotiated with the admin; later she asked "para recargar un telefono en
    Cuba" (no promo).
  - Her 15,500 GYD deposit was filed as a recharge and the bot asked for "el numero de telefono cubano a recargar".
    The op is still 'ready_to_transfer'.
- 5 more closed ops typed 'recarga' look misfiled (8a1752f8 cuban_card 5,000; 63ebe914; 8c60dea0 1,000; e6f4bc83
  14,400, a Zelle in the chat; 9769c783 12,520).
- Cause: the typed-text rule (cerebro_recarga_en_curso, and its inline copy in the Cerebro's 'Contexto conversacion',
  079) only needed "recarga|etecsa|cubacel" in the last 24 h and no pending card: no promo check, no Zelle check.
  207 gated only OPENING a recharge, not filing a deposit as one.

## Scope
- T1 DB `211_recarga_needs_promo.sql` (+ ROLLBACK): the typed-text rule also needs a promo running or confirmed ahead,
  and no Zelle (typed or pending). An open recharge still counts. Assertion recarga-needs-promo.sql.
- T2 Cerebro gate109: 'Contexto conversacion' reads cerebro_recarga_en_curso(v.id) instead of its inline copy.
- T3 Production after the owner's go-ahead.
- T4 Data fix of the two open ops, only with the owner's confirmation of what each one was.

## Progress
- T1 (staging):
  - RED: "case 1: a recharge in progress with no promo", re-checked against the pre-211 body in one transaction.
  - 211 applied (schema_migrations 211); recarga-needs-promo ALL PASS.
  - The neighbours pass both with staging as is and with every promo discarded (production has none): recarga-model,
    recarga-numbers, recarga-before-deposit, recarga-by-audio, recharge-only-with-live-promo, calculator-recarga,
    panel-recarga, the combo-* suites, promo-notice, deposit-path-without-deals, deal-free-money-rules,
    cash-phone-not-a-card.
  - recarga-numbers and combo-deposit-calculator assumed a typed recharge with no promo; they now set up a running
    promo (as 207 did for recarga-by-audio and recarga-before-deposit). They were found by re-running with every promo
    discarded, since staging still has the fake 8–11 Oct promo.
- T2 (staging): gate109 (~/cerebro-fase1/pruebas/gate109-recarga-una-regla.py; old block saved as
  gate109-bloque-viejo.sql; backup cerebro-staging-antes-109-*). The edited Contexto SQL runs on staging; published.
- T3 PRODUCTION (owner go-ahead 2026-10-04 "si, pásalo a producción"):
  - Backup produccion-20261004T224959Z.dump (sha256 61e318a965bb053b...; 2144 list entries).
  - Pre-check: cerebro_recarga_en_curso md5 d0f16653 (the rollback body).
  - Temp helper. gate110-aplicar-db.py: ensayo md5 4146aaff equal to staging; aplicar OK (schema_migrations
    20261004225256 211_recarga_needs_promo).
  - probar in production (no promo there), all passing: recarga-needs-promo, recarga-model, recarga-numbers,
    recarga-before-deposit, recarga-by-audio, recharge-only-with-live-promo, calculator-recarga, panel-recarga, the
    combo-* suites, promo-notice, deposit-path-without-deals, deal-free-money-rules, cash-phone-not-a-card,
    partial-beneficiary-tools.
  - Helper dropped; no leftovers.
  - gate109 produccion published (backup cerebro-produccion-antes-109-20261004T170019.json).
  - Yilian's conversation still reads "recarga en curso" because her misfiled op 89f6df7e is still OPEN as a recarga
    (the open-op rule, 204). T4 fixes that.
- T4a DATA FIX op 89f6df7e (owner go-ahead 2026-10-04 "sí, corrígela así"), production:
  - One DO block acting as the owner (jwt sub ca797265), guarded on the expected state (recarga /
    ready_to_transfer / 83,200 / zelle).
  - The zelle beneficiary's name 'Si Liudis Aguilar Rojas' became 'Liudis Aguilar Rojas', with amount 320 USD. The
    operation became service_type remesa, destination 320 USD, with a human_correction audit row.
  - Then crm_cerrar_operacion_manual(p_notify false): completed, closed_manually, muted.
  - A dry run (forced exception) showed the same result first.
  - After: calculator ZELLE completed, facturado 83,200, invertido 76,800, retorno 6,400 (20 GYD/USD, as the other
    Zelle lines). cerebro_recarga_en_curso(Yilian) = false. No message to the customer (0 messages, 0 outbox rows
    after 23:06Z).
- T4b op 12510beb (Yusmila, 15,500 GYD, 2026-09-23): LEFT AS IS by the owner (2026-10-04): "revisé el chat y no veo
  nada, no mandó más nada, solo el depósito; un admin le preguntó y no respondió, déjalo así por ahora". It stays
  ready_to_transfer as a recarga until the customer writes back. Since 211, her conversation only counts as a
  recharge in progress because this op is open.
- T5 the 5 closed ops typed 'recarga' (owner, 2026-10-05: "arregla el 1"). Each chat was read first:
  - 8a1752f8 (Miguel, 08-15, 5,000): "quiero recargar la tarjeta", but gave a card and a phone, so it was a CUP card
    remesa -> FIXED to service_type remesa.
  - e6f4bc83 (Rubislandi, 09-19, 14,400): had asked about recharges, then paid "55 dólares a ese zelle" -> FIXED to
    remesa, zelle, 55 USD.
  - 8c60dea0 (Zulemys, 09-08, 1,000): a real recharge on an offer the admin confirmed. Left.
  - 9769c783 (Zuleika, 09-21, 12,520): two real recharges (2 x 6,200) during the 21–26 Sep promo; she says "es la
    promoción de ETECSA". Left.
  - 63ebe914 (Marlene, 09-07, 5,000): a cancelled recharge attempt. Left.
  - The fix was one guarded DO block (expected state checked); a dry run (forced exception) came first. Each op got a
    human_correction audit row.
  - No calculator line was created: both predate the calculator (2026-09-28), like every remesa of those dates.
