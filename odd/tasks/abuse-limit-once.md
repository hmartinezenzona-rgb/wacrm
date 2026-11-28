# Feature: the message-rate limit locks once, alerts once, and never fires on a human-attended chat

## Objective
The Cerebro abuse limit must stop the bot for a flooding number with ONE admin alert and ONE waiting message to the
customer, must not lock a chat a team member is actively attending, and must use a threshold that real customers do
not reach. The decision lives in SQL, not in n8n branching that re-fires.

## Problem / why (root cause, 2026-11-10)
- conv c791477d (2026-11-09 UTC): a real customer burst (64 messages in 60 min, 75 texts + 9 media since 11-08, no
  duplicates); the owner was replying by hand from ~15:25. Node `Control de abuso` (prod workflow jEzlVLCLUaJhVwzs,
  version f696f951) counts `session_events` of the last hour, threshold > 30, then calls
  `cerebro_registrar_derivacion(conv, motivo, 'abuso', true)` and posts type LIMITE to the notifier.
- `cerebro_registrar_derivacion` returns a row (acaba_de_derivar) whenever the chat is unassigned OR assigned to the
  bot agent 377b0c8c, so every later execution "just handed off" again: 48 LIMITE alerts (exec 688462..688716,
  16:03-16:26) and 48 "Un momento por favor ..." messages to the customer.
- The limit ignores that a human was attending the chat; 30/hour is below a real fast customer.

## Owner decisions
- 2026-11-10: fix at root ("si, arréglalo de raíz").

## Claude defaults (stated to the owner)
- One lock = one alert + one waiting message; repeated passes while locked stay silent (throttle per conversation,
  6 h like cerebro_avisar_mlc).
- No abuse lock while a team member has written in the chat recently (window to be set from data, e.g. 30 min).
- Threshold set from production data (max messages/hour of legit conversations), stated with the numbers.

## Scope
In: SQL function(s) (migration 361+ with ROLLBACK + staging assertions); `Control de abuso` node query on staging,
then production with go-ahead. Out: notifier text, Decisor.

## Constraints
- Staging first; production only with explicit go-ahead (migration and n8n each). Read LIVE bodies first.
- Strict TDD (SQL assertions in rolled-back transactions, RED then GREEN). Never execute n8n workflows.
- Never touch the other session's files. No AI attribution in commits. RDD off.

## Tasks
- [x] T1 Data: per-conversation max inbound messages per rolling hour (60 days), and how often a human was writing
      during bursts; pick threshold and human window
- [x] T2 Migration 361: single SQL decision function (count, human-active check, lock-once, alert throttle), fix
      `cerebro_registrar_derivacion` re-firing; ROLLBACK; assertion (c791477d shape, first lock alerts once, later passes
      silent, human-active no lock, unlock then relock alerts again)
- [x] T3 Staging: apply migration; `Control de abuso` node on staging calls the function; backup first
- [x] T4 Production (owner go-ahead 2026-11-10): migration, node

## Acceptance criteria
- 64 messages/hour from a flooding number with nobody attending -> one lock, one alert, one waiting message.
- Same burst while a team member wrote recently -> no lock, no alert.
- After the team unassigns the chat, a new flood locks and alerts again.

## Progress / evidence
- 2026-11-10: root cause mapped (read-only; execs 688462..688716; conv c791477d).
- T1 (production, read-only, 60 days, 200 conversations with inbound customer messages; rolling 60 min per conversation):
  max inbound per hour p50 8, p90 18, p99 30, max 64. Conversations over 20: 13, over 30: 2, over 40: 1, over 60: 1, over 80: 0.
  Second-highest conversation: 33. The two conversations over 30 (64 and 33) both had a team member (non-bot agent message) writing in
  the 30 min before the peak; of the 37 conversations with a peak >= 15, 30 had one in the 30 min before, 24 in the 10 min before.
  session_events only covers ~30 days, so the 60-day figures use messages (customer), the node counts session_events (same shape: 64 for c791477d).
  Decision: limit = strictly more than 40 events in the last hour (above every legitimate conversation but the c791477d flood,
  margin 7 over the legitimate maximum 33), human-active window = 30 min (configurable: abuso_limite_mensajes, abuso_humano_activo_minutos).
- Live bodies read 2026-11-10: cerebro_registrar_derivacion identical in production and staging (only caller with motivo/razon
  abuso and bucle is the node `Control de abuso`; node queries identical in both workflows, md5 09784da8...; prod f696f951, staging b5ff9a88).
- T2: migration 361 + ROLLBACK-361 + assertion abuse-limit-once. Design: one function cerebro_control_abuso(conv, repeated_questions)
  returns (eventos, excede, bloquear_ahora): <= limit -> continue; row lock; already locked for abuse (disabled + reason abuso + bot) ->
  silent; person wrote within window -> continue; else cerebro_registrar_derivacion(..., 'abuso', true): row back -> LIMITE net.http_post
  (same payload as the node) and bloquear_ahora; no row (person-held) -> silent. cerebro_registrar_derivacion unchanged.
  The 6 h alert throttle was NOT added on purpose: lock-once is the chat state, a timer would swallow the wanted second alert after the
  team unlocks (owner may overrule).
  RED (staging, before 361): `NOTICE: FAIL [0 cerebro_control_abuso exists]` / `ERROR: 1 expectation(s) failed (function missing)`.
  GREEN (BEGIN; 361; assertion; ROLLBACK): 33 expectations ok, `ERROR: ALL PASS (rolled back on purpose)`.
  `staging-migracion.sh aplicar`: dry-run OK, apply OK, assertion OK, rollback OK (md5 equal); cerebro_control_abuso md5 b8ccdeb8385c,
  cerebro_registrar_derivacion md5 62fc4ddf6fdd (unchanged by 361). `relacionadas` (9 matching assertions, mine skipped; touching ai_handoff, registrar_derivacion,
  session_events, avisar_mlc, with --ya-aplicada): TOTAL 8, SAME 8, DIFF 0 (pre-existing base errors: deal-free-beneficiary-writers,
  grants-mirror-production, reparto-destino-node-adapters, identical with and without 361).
  Note: the `bucle` alert in the node still re-fires every pass (cerebro_registrar_derivacion returns a row each time); out of scope here.

- 2026-11-10 T4 production (owner "si, pásalo a producción"): previa SEGURO; `OK 361_abuse_limit_once 20261110070308`;
  verificar 1/1 equal (cerebro_control_abuso b8ccdeb8). n8n backup
  /home/onlinefreedom/cerebro-fase1/respaldos-n8n/produccion-jEzlVLCLUaJhVwzs-f696f951-4070-4b3d-8951-82dd6ffa1b44-20261110-010318.json;
  node query md5 da863e74, other nodes and connections untouched, versionId f696f951 -> 31a711a2 = activeVersionId, 128 nodes.

## Next step
Done. Watch the next real flood (one LIMITE alert). Follow-up candidate: the bucle alert re-fires every pass (same class).
- T3 (staging only, nothing executed): backup /home/onlinefreedom/cerebro-fase1/respaldos-n8n/staging-U52y1kSNvhgxvWeb-b5ff9a88-ecee-4dda-9c91-e5758af143cd-20261110-005846.json.
  Node `Control de abuso` query rewritten (old md5 09784da8, new da863e74): removed the `cnt` CTE, new `abuso` CTE = cerebro_control_abuso($1, repeated
  questions), `derivar` now only the bucle derivation (skipped when abuso already excedes), BUCLE alert unchanged, output columns keep their names
  (excede from the function, acaba_de_derivar = first lock or bucle derivation). No connection or other node changed (If nodes read the same fields).
  versionId b5ff9a88 -> 9ab5c1ff, activeVersionId 9ab5c1ff (equal), 132 nodes, Decisor md5 243f6cfd unchanged, other nodes and connections identical.
  The new query was also run three times on a rolled-back synthetic PRUEBA conversation (64 events): pass1 excede t / acaba_de_derivar t, pass2 and pass3
  excede t / acaba_de_derivar f, one alert row queued in total (rolled back, nothing sent).
  Script (not in the repo, reusable for production with its own md5/anchor table): /tmp/claude-1000/-home-onlinefreedom/650315b7-dab0-45e4-8750-257f1bb931ca/scratchpad/abuse_limit_once_nodo.py
  (md5 1dc18a97), usage `abuse_limit_once_nodo.py <staging|produccion> <versionId prefix> [--dry-run]`. Production dry run is read-only: against f696f951 it builds the same new query (md5 da863e74).
