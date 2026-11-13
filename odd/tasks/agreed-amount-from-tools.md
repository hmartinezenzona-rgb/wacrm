# Feature: the agreed amount is stored by the tools, not guessed from the bot's sentence

## Objective
What the bot tells the customer he must deposit is stored when the tool computes it (said = saved): the objective and the
agreed quote no longer depend on parsing the bot's reply text, and a planned split keeps its total as the objective.

## Problem / why (audit 2026-11-13 + owner tests)
- The agreed amount for CUP / Clasica / Tropical / efectivo / Mexico is stored only when trg_registrar_cotizacion ->
  cerebro_monto_cotizado recognizes the bot's sentence. In 30 days ~25-30 quote phrasings were missed ("Por Zelle son/serían
  *X GYD*", "Total a depositar: *25,400 GYD*", "En total son *25,400 GYD*", "*N CUP* por *N GYD*"). Consequences: stale quote
  (366 case), no "Cotizado" line in the panel, deposit compared with nothing or with an old quote.
- calcular_usd writes the objective only when a commitment exists and silently refuses otherwise; calcular_usd_desde_gyd,
  calcular_envio and calcular_inverso write a quote row (cerebro_ultima_cotizacion) but no agreed amount/objective.
- Owner test exec 728365 (2026-11-13): after the double-declaration hook (371) set the objective to the plan total 25,400,
  registrar_beneficiario_zelle (cerebro_guardar_zelle -> cerebro_fijar_objetivo with the Zelle recipients' sum) overwrote it
  with 13,000 ("50 USD").
- Owner principle (2026-11-13): the tools must be able to record everything the bot confirms; when in doubt, ask.

## Owner decisions
- 2026-11-13: "si" to: fix the objective overwritten under a plan now; then make the calculation tools store the agreed amount.

## Scope
In: SQL (migrations 372+, ROLLBACK, staging assertions); n8n tool-node SQL only if a tool must pass an argument it does not
pass today (report the exact node change; the parent applies it). Staging; production with go-ahead.
Out: Decisor; prompt (contradictions are a separate feature); panel.

## Constraints
- A quote is not a commitment by itself: comparison quotes (two services quoted in one turn) and price questions must not fix an
  objective the customer did not accept. Keep the existing "commitment" notion; make refusals explicit in the tool result
  ("NO se fijo: ...") so the bot can ask instead of promising.
- The text parser stays as a fallback (no behaviour loss), but a tool-written agreed amount wins over an older parsed one.
- Read LIVE production bodies and confirm they match the repo before redefining. Strict TDD: SQL assertions in rolled-back
  transactions (RED then GREEN). Related assertions stay green.
- Never touch the other session's files (pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts,
  pruebas/decisor/decisor-notas.test.ts, odd/tasks/bot-brevedad.md). No AI attribution in commits. RDD off.

## Tasks
- [ ] T1 Objective under a plan: while cerebro_reparto_planeado exists for the conversation and no deposit is applied, the
      objective stays the plan total; a recipient writer (Zelle sum) must not shrink it; assertions (exec 728365 shape)
- [ ] T2 Map + design: what each calculator writes today, what "commitment" means in cerebro_fijar_objetivo, where the panel
      "Cotizado" line and the deposit check read from (cerebro_cotizacion / cerebro_cotizacion_vigente / objetivo), and the
      smallest change that makes a tool-computed amount the stored agreed quote (e.g. calculators upsert cerebro_cotizacion with
      the GYD total they return, tagged with the execution; the turn's reply total "Total / En total" for a plan = plan total).
      STOP and report only if an owner decision is needed; otherwise continue
- [ ] T3 Implementation + assertions (single quote, re-quote, comparison of two services, plan total, refusal text)
- [ ] T4 Staging: apply, related assertions
- [ ] T5 Production (needs go-ahead)

## Acceptance criteria
- Planned split 12,400 + 13,000, then the Zelle account is saved -> objective still 25,400.
- A tool-computed quote is visible as the conversation's agreed quote without relying on the reply's wording.
- Two different services quoted in one turn -> no objective fixed; the tool result says so.

## Progress / evidence

## Next step
T1.
