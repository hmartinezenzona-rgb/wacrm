# Feature: no new operations for a deposit already used, and no Zelle account taken from history

## Objective
1. The split tool (repartir_envio) never opens operations for a deposit that a send completed within the window already
   consumed; it hands the case to a person instead.
2. A Zelle account is written to a send only when the customer sent it for this send, or explicitly asked for the same
   account as before.

## Problem / why (2026-11-12)
- Conv d9e9f333: one 25,400 GYD deposit (2 recargas + 50 USD Zelle) consumed by op 0d1ca519 (recarga, completed by the
  admin 19:13 UTC). 20:26 exec 720756 called repartir_envio "zelle 13000, recarga 12400"; with no open holder,
  cerebro_repartir_envio took the PLAN path (_cerebro_reparto_planear(..., true, ...)) and opened f8de92c9 (zelle) and
  845f1d6a (recarga 12,400, duplicate of the delivered recargas). Exec 720768 repeated the call. The bot then said the
  deposit did not appear. The plan path never consults the 360 guard (cerebro_guardia_envio_nuevo /
  _cerebro_completada_reciente) nor deposits consumed by a recent completed op.
- Conv 1727ef31 op 6977cd51: batch 1 (exec 721005, "Pásame 58 zelle a la cuenta") ran before the account arrived; the
  model called registrar_beneficiario_zelle with the previous send's account (op bd213536 recipient) although the context
  said nobody was known. Exec 721014 added the real account with agregar=true -> two vigente Zelle recipients.
  cerebro_guardar_zelle accepts any account. Data corrected by the owner's request (audit e2fa4f8b, 698709b2, 2b20fb20).

## Owner decisions
- 2026-11-12: "si, corrígela y luego arregla los dos".

## Scope
In: SQL migration 367 (+ ROLLBACK, staging assertions); staging; production with go-ahead.
Out: Decisor, prompt, panel, n8n nodes; the data of d9e9f333 (separate owner decision).

## Constraints
- Strict TDD: SQL assertions in rolled-back transactions; RED before GREEN; synthetic fixtures with the real shapes.
- Read LIVE production bodies first and confirm they match the repo before redefining.
- Staging first; production only with the owner's explicit go-ahead.
- Never touch pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts, pruebas/decisor/decisor-notas.test.ts,
  odd/tasks/bot-brevedad.md. No AI attribution in commits. RDD off.

## Tasks
- [ ] T1 Split guard: cerebro_repartir_envio plan path refuses (no operations, no plan) when a completed op within
      envio_completado_ventana_horas holds a consumed deposit that covers the parts' total; hands off to a person
      (cerebro_registrar_derivacion, like the ambiguous case) and tells the bot not to say the deposit is missing;
      a split with no recent consumed deposit still plans as today; assertions (d9e9f333 shape)
- [ ] T2 Zelle history guard: cerebro_guardar_zelle refuses an account for a send when it does not appear in a customer
      message after the conversation's last completed/cancelled op and the customer did not ask for the same account
      ("misma cuenta", "la de siempre", "la anterior", "igual que la otra"...); the refusal tells the bot to ask which
      account; assertions (1727ef31 shape, legitimate new account, explicit "la misma")
- [ ] T3 Staging: apply 367, related assertions
- [ ] T4 Production (needs go-ahead)

## Acceptance criteria
- Deposit used by a send completed 1 h ago + split call -> no operation created, case handed to a person.
- Zelle send with no account in the new messages -> the old account is not saved; the bot asks.
- Customer says "a la misma cuenta" -> the previous account is saved.
- Existing split and Zelle assertions stay green.

## Progress / evidence
- 2026-11-12: root causes (read-only production: tool_execution_log, executions 720756/720768/721005/721014,
  remittance_beneficiaries, remittance_admin_audit).

## Next step
T1.
