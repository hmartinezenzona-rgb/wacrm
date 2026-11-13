# Feature: a mixed send is registered when the customer declares two services, even with data missing

## Objective
When the customer asks for two services in one request (e.g. 2 recargas + 50 USD Zelle) and the bot registers one and quotes
the other, the planned split (cerebro_reparto_planeado + one operation per part with its agreed amount) exists from that
turn, so the panel shows the mixed send waiting for the deposit. It must not depend on the model remembering to call
repartir_envio.

## Problem / why (2026-11-13, owner test conv 2ca2cf79, exec 727547, no-Decisor test mode)
- One message: "2 recargas a <2 numbers> y también un zelle de 50 USD" (no Zelle account yet). Tools in that execution:
  registrar_numeros_recarga (op recarga, agreed 12,400, 2 numbers), consultar_servicio, calcular_usd (13,000 GYD, zelle).
  repartir_envio was NOT called: no plan, no Zelle operation. The panel showed one loose recarga operation; the Zelle the
  customer asked for was recorded nowhere. Reply text was right (total 25,400, asks the Zelle name and account).
- 369/370 (production 2026-11-13) show a plan as one mixed send, but only when a plan exists.
- Unknown: whether the production Decisor notes make the model call repartir_envio in this shape (test ran without them).

## Owner decisions
- 2026-11-13: "si, arréglalo así": the plan is created as soon as the customer declares two services with their amounts, in
  the database, not depending on the bot using the tool.

## Scope
In: SQL (migration 371+, ROLLBACK, staging assertions). Staging; production with go-ahead.
Out: Decisor, prompt, panel (369/370 already render a plan), n8n nodes unless a tool node must pass an extra argument
(then report, do not edit n8n).

## Constraints
- A price question is not a declaration: never plan from a quote alone when the customer did not ask for both (see T1).
- No mixed_group_id before the deposit (369 decision); parts get agreed amounts (not money); deposit behaviour unchanged.
- Read LIVE production bodies first and confirm they match the repo before redefining. Strict TDD: SQL assertions in rolled-back
  transactions, RED then GREEN. Related assertions stay green.
- Never touch the other session's files (pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts,
  pruebas/decisor/decisor-notas.test.ts, odd/tasks/bot-brevedad.md). No AI attribution in commits. RDD off.

## Tasks
- [ ] T1 Map and design (STOP and report before writing SQL): what each tool call leaves in the database in that turn
      (registrar_numeros_recarga, calcular_usd / calcular_envio -> cerebro_registrar_cotizacion / cerebro_ultima_cotizacion,
      consultar_servicio, "servicio declarado" state and its trigger, execution id available to each function), which
      deterministic signal means "two services declared" vs "price question", how a wrong plan is undone (customer drops a
      part, deposits only one part), and the proposed trigger point with its false-positive cases
- [ ] T2 Implementation + assertions (exec 727547 shape; price-question negative; second service data arriving later; drop a part)
- [ ] T3 Staging: apply, related assertions
- [ ] T4 Production (needs go-ahead)

## Acceptance criteria
- "2 recargas + Zelle 50 USD" in one request, Zelle account missing -> plan recarga 12,400 + zelle 13,000 (total 25,400) and the
  two part operations exist after that turn.
- "recarga a X; ¿cuánto sale un zelle de 50?" (question only) -> no plan.
- Existing split/plan/deposit assertions green.

## Progress / evidence

## Next step
T1.
