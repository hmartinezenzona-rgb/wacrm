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
- [x] T1 Objective under a plan: while cerebro_reparto_planeado exists for the conversation and no deposit is applied, the
      objective stays the plan total; a recipient writer (Zelle sum) must not shrink it; assertions (exec 728365 shape)
- [x] T2 Map + design: what each calculator writes today, what "commitment" means in cerebro_fijar_objetivo, where the panel
      "Cotizado" line and the deposit check read from (cerebro_cotizacion / cerebro_cotizacion_vigente / objetivo), and the
      smallest change that makes a tool-computed amount the stored agreed quote (e.g. calculators upsert cerebro_cotizacion with
      the GYD total they return, tagged with the execution; the turn's reply total "Total / En total" for a plan = plan total).
      STOP and report only if an owner decision is needed; otherwise continue
- [x] T3 Implementation + assertions (single quote, re-quote, comparison of two services, plan total, refusal text)
- [x] T4 Staging: apply, related assertions
- [ ] T5 Production (needs go-ahead)

## Acceptance criteria
- Planned split 12,400 + 13,000, then the Zelle account is saved -> objective still 25,400.
- A tool-computed quote is visible as the conversation's agreed quote without relying on the reply's wording.
- Two different services quoted in one turn -> no objective fixed; the tool result says so.

## Progress / evidence
- T1 (migration 372, cerebro_fijar_objetivo): live prod body read 2026-11-13 equals repo 278 (no diff). Design: the single writer
  cerebro_fijar_objetivo refuses any amount other than cerebro_reparto_planeado.total_gyd while the plan row exists (the row lives until the
  deposit is applied or the plan is dropped, 277/280/281); the plan total itself is accepted (371 hook). Refusal text: "NO se fijo: hay un
  reparto planeado de X GYD ...". Covers cerebro_guardar_zelle and every other caller (calcular_usd, cerebro_cotizar, 283/293 writers).
  Assertion objetivo-bajo-reparto.sql: RED on staging before the migration (case 1 expected 25400, got 13000 = exec 728365), GREEN after
  (staging-migracion aplicar: dry-run/apply/assertion/rollback OK, md5 equal). Related (pattern objetivo|cotiza|quote|reparto|plan|zelle|deposit|declar,
  --ya-aplicada): TOTAL 206, SAME 204, DIFF 2 (objetivo-bajo-reparto = RED->GREEN as intended; delivery-feed-evidence = same error text, only the
  deal uuid differs, pre-existing fixture failure). Note: planear (_cerebro_reparto_planear) does not itself fix the objective; the 371 hook does.

## Next step
T5 production (previa 372+373, then aplicar with the owner's go-ahead; n8n node change is optional).
- T4 staging: 372 and 373 applied on staging (aplicar OK, md5 equal on rollback). relacionadas with pattern
  objetivo|cotiza|quote|reparto|plan|zelle|deposit|declar and --ya-aplicada: 372 -> TOTAL 206, SAME 204, DIFF 2; 373 -> TOTAL 207, SAME 205, DIFF 2.
  DIFFs explained: objetivo-bajo-reparto (372) and tool-quote-is-agreed-quote (373) are the new assertions going RED -> GREEN; delivery-feed-evidence
  fails identically on base and with the migration ("no operation created for deal", only the deal uuid differs; pre-existing). No existing
  assertion was changed.

## T2 map and design (2026-11-13)
Today (live bodies read 2026-11-13): each calculator node calls cerebro_registrar_cotizacion (-> cerebro_ultima_cotizacion, per currency, evidence only),
cerebro_registrar_via_cotizada (-> tool_execution_log, evidence for the coherence net) and, calcular_usd only, cerebro_fijar_objetivo (commitment
needed, result column hidden from the model). The AGREED quote store is cerebro_cotizacion (one row per conversation, gyd + texto), written only by the
text trigger; read by cerebro_cotizacion_vigente (6 h window, newer than the last closed send) -> cerebro_objetivo_minimo / cerebro_aplicar_cotizacion
and by the panel line crm_cotizacion_de_conversacion (187, which parses '*N CUP|USD*' from texto).
Design (373, no n8n edit): cerebro_registrar_via_cotizada (called by all four nodes and cerebro_cotizar with the execution, via and GYD origin) now also
calls _cerebro_cotizacion_acordar, which upserts cerebro_cotizacion (new column ejecucion) with the GYD the tool computed (plan total while a plan
exists), a texto the panel line parses, then cerebro_aplicar_cotizacion like the trigger. Two services quoted in one execution (>= 2 distinct vias)
is a comparison: the quote of that execution is removed and so is an objective fixed in the turn for one of those amounts (not under a plan). No via or
no GYD origin: nothing stored. The text parser is untouched (fallback; newest write wins). No owner decision was needed.
Not done on purpose: the tool RESULT cannot carry "NO se fijo" because the nodes return fixed columns and calcular_usd discards cerebro_fijar_objetivo's
output; that needs an n8n node change (reported to the coordinator, optional).
T3 evidence: assertion tool-quote-is-agreed-quote.sql (8 cases: single quote, re-quote, comparison, next execution, plan total, parsed replaced, no
via/no origin, closed send). RED on staging before the migration (column ejecucion missing / no quote stored), GREEN after
(aplicar: dry-run/apply/assertion/rollback OK, md5 equal).
