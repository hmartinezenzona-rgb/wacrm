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
- [x] T1 Measure current behaviour on both environments (assertion + rolled-back production runs)
- [~] T2-T4 (migration 187, gate 84) DROPPED: not needed, see the finding below

## Acceptance
- CUP single card, quote 5,000 GYD, deposit 7,000 -> ready_to_transfer, 7,000, destination 21,000 CUP. MET today.
- CUP quote 10,000, 6,000 -> waits; +4,000 -> complete. MET today.

## Progress / evidence
- 2026-10-02 FINDING (corrects my two earlier explanations to the owner): both environments ALREADY follow the
  owner's option 1. Measured with rolled-back runs on production (deal path) and the staging assertion
  `supabase/staging/assertions/cup-excess-equivalent.sql` (deal-free path, run after deal-free-money-rules.sql):
  CUP quote 5,000 + deposit 7,000 -> verificado, ready_to_transfer, 7,000, 21,000 CUP, no objetivo kept; CUP quote
  10,000 + 6,000 -> verificado_incompleto, waits; + 4,000 -> ready; 6,000 + 6,000 -> verificado, ready, 12,000; Zelle
  quote 13,000 + 15,000 -> ready (also equivalent). The ONLY "deposito de mas" Incidencia: a target fixed BEFORE the
  deposit by calcular_usd (cerebro_fijar_objetivo) -> 15,000 on 13,000 -> verificado_de_mas / incident (case 4).
  Why: 171's cerebro_objetivo_minimo keeps a target only when the money does not cover it ("Covered and nothing open
  to correct: nothing to do") and raises an open one with the total. The assertion now pins this (4 cases ALL PASS).
- Consequence for the panel follow-up (show the quote before the deposit): it must NOT fix a CUP target the
  calcular_usd way (that would create the Incidencia path for CUP); read the quote for display instead.
