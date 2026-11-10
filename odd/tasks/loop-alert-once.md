# Feature: the loop (bucle) handoff alerts once per lock

## Objective
When the Cerebro bot detects a loop (repeated questions) and hands the chat off, the admin gets ONE BUCLE alert and
the customer ONE waiting message, not one per incoming message while the chat stays held. The decision lives in SQL.

## Problem / why (2026-11-10)
- Same class as odd/tasks/abuse-limit-once.md: after 361 the node `Control de abuso` keeps a `derivar` CTE for the
  bucle derivation that calls `cerebro_registrar_derivacion(conv, motivo, 'bucle', true)` on every pass; that function
  returns a row whenever the chat is unassigned or held by the bot agent 377b0c8c, so `acaba_de_derivar` is true on
  every pass and the BUCLE alert (and the waiting message) repeat.

## Owner decisions
- 2026-11-10: fix it ("arregla también lo del bucle que repite la alerta").

## Claude defaults
- Same rule as abuse: already held for bucle (or abuso) by the bot -> silent; first derivation -> one alert and one
  waiting message; after the team unassigns, a new loop alerts again. Loop detection threshold unchanged.

## Scope
In: migration 363 + ROLLBACK + staging assertion; `Control de abuso` node on staging, then production with go-ahead.
Out: loop detection criteria, notifier text.

## Constraints
- Staging first; production only with explicit go-ahead (migration and n8n each). Read LIVE bodies first.
- Strict TDD (SQL assertions in rolled-back transactions, RED then GREEN). Never execute n8n workflows.
- Never touch the other session's files. No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Migration 363: bucle decision lock-once in SQL (extend cerebro_control_abuso or a sibling); ROLLBACK;
      assertion (repeated passes -> one alert; held for abuso then loop -> silent; unassign then loop -> alert again;
      other motivos unchanged)
- [x] T2 Staging: apply; node query on staging; backup first
- [ ] T3 Production (needs go-ahead): migration, node

## Acceptance criteria
- A loop detected on N consecutive passes -> exactly one BUCLE alert and one waiting message.
- After the team releases the chat, a new loop alerts again.

## Progress / evidence
- Live bodies read 2026-11-10: staging and production `Control de abuso` queries both md5 da863e74 (the 361 rewrite; staging 9ab5c1ff, prod 31a711a2);
  cerebro_registrar_derivacion md5 62fc4ddf and cerebro_control_abuso md5 b8ccdeb8 identical in staging and production.
- Design: SIBLING function cerebro_control_bucle(conv, en_bucle, preguntas, excede, eventos) returns boolean, not an extension of
  cerebro_control_abuso. Extending changes its RETURNS TABLE (DROP+CREATE, grants redone, and the production node that already calls
  the 3-column shape would break between migration and node change); the sibling is additive, ordered safely (migration then node),
  rollback is one DROP. Loop detection (4 repeated questions) stays in the node and arrives as en_bucle. Order: not loop or excede -> false;
  row lock; held by the bot for bucle or abuso -> false; cerebro_registrar_derivacion(..., 'bucle', true): row -> BUCLE alert
  (type, cliente_phone, eventos, preguntas_repetidas) and true; no row (person-held) -> false. Other bot-held reasons are re-labelled bucle once.
- T1 (commit ebc1a47). RED (staging, before 363): `NOTICE: FAIL [0 cerebro_control_bucle exists]` / `ERROR: 1 expectation(s) failed (function missing)`.
  GREEN (BEGIN; 363; assertion; ROLLBACK): 24 expectations ok, `ERROR: ALL PASS (rolled back on purpose)`; abuse-limit-once also stays
  `ALL PASS` with 363. `staging-migracion.sh aplicar`: dry-run OK, apply OK, assertion OK, rollback OK (md5 equal); cerebro_control_bucle md5 6e181ac07468,
  cerebro_control_abuso b8ccdeb8385c and cerebro_registrar_derivacion 62fc4ddf6fdd unchanged. `relacionadas --ya-aplicada` (mine skipped):
  derivacion TOTAL 3 SAME 3 DIFF 0; abuso TOTAL 1 SAME 1 DIFF 0; bucle TOTAL 1 SAME 1 DIFF 0. Pre-existing base errors (identical with and without 363):
  deal-free-beneficiary-writers, reparto-destino-node-adapters.
- T2 (staging only, nothing executed): backup /home/onlinefreedom/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-9ab5c1ff-3af0-4e8c-93ef-cc6dbcf0804d-20261110-013054.json.
  Node `Control de abuso` query old md5 da863e74 -> new dc5cd429: the `derivar` and `aviso` CTEs became one `derivar` CTE calling cerebro_control_bucle;
  acaba_de_derivar = abuso.bloquear_ahora OR derivar.derivar_ahora; LEFT JOIN aviso removed; output column names unchanged, no connection or other node changed.
  Before the PUT the new query ran three times on a rolled-back synthetic PRUEBA conversation (4 closed-question agent messages): pass1 acaba_de_derivar t,
  pass2 and pass3 f (ya_asignado t, en_bucle t), one alert row queued in total (rolled back, nothing sent).
  versionId 9ab5c1ff -> e400cbb0, activeVersionId e400cbb0 (equal), 132 nodes, only `Control de abuso` differs from the backup, connections equal, Decisor md5 243f6cfd.
  Script (not in the repo): /tmp/claude-1000/-home-onlinefreedom/650315b7-dab0-45e4-8750-257f1bb931ca/scratchpad/loop_alert_once_nodo.py (md5 0041fbf2),
  usage `loop_alert_once_nodo.py <staging|produccion> <versionId prefix> [--dry-run]`. Production --dry-run (read-only) against 31a711a2: builds the same new query, md5 dc5cd429. Not run on production.

## Next step
T3 needs the owner's go-ahead: production migration 363 (previa first), then the node with the script (respaldo produccion first).
