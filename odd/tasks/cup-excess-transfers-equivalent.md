# A CUP remesa paid above the quote transfers the equivalent

Objective: when a single-card CUP remesa receives MORE than the quoted target, the deposit counts as complete and the
equivalent is transferred (no Incidencia), and the bot tells the customer so. When it receives LESS, the bot says how
much is missing and waits for the rest (unchanged). USD rails, repartos and recargas keep today's behaviour.

Owner decision (2026-10-02): option 1, "si llega mas se transfiere el equivalente"; less -> say what is missing, wait.

Current behaviour (verified on production): since migration 171 (production 2026-10-01 17:11 UTC) the bot's quote is
the remesa target for every rail (cerebro_objetivo_minimo: greatest(service minimum, latest quote)).
cerebro_cruzar_depositos turns saldo < 0 into 'verificado_de_mas' and the Incidencia stage; crm_verificar_deposito
(panel) calls it. The saldo comes from cerebro_saldo_envio (production, deal) / cerebro_saldo_operacion (staging,
operation); the p_simular branch recomputes `v_saldo := v_obj - v_dep;`.

Design (migration 187, one file for both environments, body-independent):
- `cerebro_excedente_es_equivalente(id)`: true when the operation (by id or deal_id) rail is `cuban_card`.
- The saldo function(s) present are renamed `*_bruto` and wrapped: a negative saldo becomes 0 when the helper is true
  (so every reader — deposit check, panel review, alerts, the bot — sees the remesa as covered). Same signature and ACL.
- The p_simular line in cerebro_cruzar_depositos gets the same clamp (textual patch of the live body, anchor checked).
- Decisor (gate 84): a verified deposit above the target -> the existing MONTO DISTINTO AL COTIZADO note ("se le
  transfiere el equivalente de lo depositado").
Not changed: USD rails (de mas -> Incidencia), repartos (excess split unclear), recargas, unknown rail.

Scope: staging first, production with the owner's go-ahead. Related: the panel showing the quote before the deposit is a
separate follow-up (`remesa/quote-not-applied-to-operation`).
TDD: on. Runners: self-reverting SQL assertions (staging deal-free helpers of deal-free-money-rules.sql; production
deal helpers of split-deposit-minimums.sql), Decisor bank (gate84).

## Tasks
- [ ] T1 Assertions (staging + production style): CUP above quote -> ready_to_transfer, destination = equivalent;
      CUP below -> waits then completes; Zelle above -> incident. RED on staging
- [ ] T2 Migration 187 + rollback; GREEN in a rolled-back transaction; apply to staging; regressions
- [ ] T3 Decisor gate 84: verified above target -> "se transfiere el equivalente"; bank RED/GREEN; staging deploy
- [ ] T4 Production (go-ahead): RED, GREEN rolled back, apply, regressions, gate 84

## Acceptance
- CUP single card, quote 5,000 GYD, deposit 7,000 -> ready_to_transfer, quoted_source_amount 7,000, destination
  recalculated from 7,000; no incident.
- Zelle quote 13,000, deposit 15,000 -> incident (unchanged).
- split-deposit-minimums, requested-amount-target, deal-free-money-rules still pass.

## Progress / evidence
