# Cerebro: smaller context, reorganized prompt, one source for business data

## Objective
Make the Cerebro answer more precisely and more cheaply without breaking what works: measure
what each response sends to the model, reorganize the agent prompt, and keep business data
(accounts, holders) in one place. Measured against real production data before any change.

## Why (user, 2026-09-26)
Each response sends 17k–44k tokens to DeepSeek (38,581-char prompt, 30-message memory, context).
The user wants this done now, using existing production conversations, measuring carefully so
nothing breaks — not waiting for a week of collector data.

## Existing tools reused
- `~/cerebro-fase1/pruebas/evals/`: the agent exam (`evaluar.py`) runs gold cases against the
  REAL model through temporary n8n workflows with mocked tools (no DB, no WhatsApp); deterministic
  scoring (required/forbidden tools, exact figures, forbidden text); `comparar_informes.py`.
  Gold battery built from real turns and arbitrated by the user on 2026-08-12.
- n8n keeps ~1.5 days of production executions (173 on 2026-09-26); the model sub-node's
  `inputOverride` holds the exact messages sent and `tokenUsage` the real tokens.

## Tasks
- [x] T1 — Measure now: per production agent turn, tokens and how the input splits between
  system prompt, memory history, turn message and tool definitions. Report.
  - 2026-09-26, 175 retained production executions, 95 model calls (from the model sub-node's
    inputOverride + tokenUsage): input tokens median 36,224, p90 48,402, max 49,992; output
    median 35. Input characters: memory history 59.8% (median 68,342 chars, 46 messages),
    system prompt 36.0% (38,589), current turn 3.2% (3,194), tool results 0.9%.
  - ROOT CAUSE of the memory weight: every remembered Human message stores the customer text PLUS
    the Decisor's `[CONTEXTO DEL SISTEMA - el cliente NO ve esto]` block (rates "de hoy", horario,
    client history, instructions): stored Human median 3,094 chars vs AI 146. Each call re-sends
    ~23 stale context blocks — cost, and contradictory old context next to the fresh one (old
    rates, old "FUERA DE HORARIO"), a plausible cause of odd replies.
- [x] T3a (CLOSED, not applied — user decision) — Memory stores only what the customer said (strip the context block from stored Human
  messages; the current turn keeps its fresh context). Candidate mechanism: the existing
  BEFORE INSERT guard on `cerebro_memoria` (migration 105 `cerebro_memoria_sin_basura`). Measure
  with a replay of real calls (history stripped vs original) before any change.
  - Replay 2026-09-26 (`~/cerebro-fase1/pruebas/evals/replay-memoria.py`, report
    `informes/replay-memoria-20260926-150347.json`): 30 real production turns × {A current memory,
    B customer-text-only memory}, same agent/prompt/model node, mocked tools with recorded results,
    memory in staging table `eval_memoria_replay`. Input tokens 1,203,891 → 531,853 (−56%).
    Agreement B vs A: tools 29/30, figures 25/30, silence 28/30 (noise A vs production: tools
    29/30, figures 28/30).
  - Case review: B is WORSE in 5 — promised a handoff without calling derivar_humano (247714); named
    an OLD Zelle beneficiary on a receipt confirmation (246961); forgot the route was Zelle (246284);
    spoke where silence was right (247370 human attending; 247053 "Ook"). Same/better in 2.
  - VERDICT: variant B is NOT safe. The context blocks carry state of the operation in progress
    (beneficiary, route, human attention) that the fresh turn context does not repeat.
  - Next: variant C — strip only the repeated generic lines (today's rates, presentation note,
    horario, client history summary, generic instructions) and keep the state-bearing lines.
  - Variant C (2026-09-26): line types measured on 1,500 prod memory messages; GENERIC dropped =
    HISTORIAL de este cliente, EL NEGOCIO ESTA ABIERTO / FUERA DE HORARIO / PROXIMO A CERRAR,
    TASAS DE HOY, YA te presentaste / PRIMER CONTACTO DEL DIA / EL CLIENTE ABRE CONVERSACION,
    MINIMO PARA ZELLE, RECARGAS PRECIOS Y PROMO. Everything else (operation state, deposit,
    beneficiary/route, Zelle/card detected, receipt, human attention, idiom, alerts) is kept.
  - Run 1 (mocked tools): −23% tokens; the 5 B regressions: 3 fixed (handoff called, right
    beneficiary, silence on "Ook"); 247370 turned out to be a CURRENT-memory failure (the bot
    skipped "¿Tienen Zelle?" and an operator answered 3 min later; C answered correctly);
    246284 inconclusive — the test harness returned an error for calcular_usd (not recorded).
  - Harness fix: calcular_usd is NOT read-only (calls cerebro_fijar_objetivo, writes the send
    target) → computed simulator (rate 260) without the side effect; the 5 pure-SELECT tools
    (consultar_tasas, calcular_envio, calcular_inverso, calcular_usd_desde_gyd,
    consultar_servicio) run for real against PRODUCTION read-only. With it, 246284 behaves the
    same in A and C. Full 30-turn rerun started and then STOPPED.
  - DECISION (user, 2026-09-26): drop the memory/token-saving work. The user does not want to
    sacrifice context. T3a closed without changes; nothing was applied anywhere. Leftover temp
    workflow deleted; staging `eval_memoria_replay` emptied. The replay harness stays in
    `~/cerebro-fase1/pruebas/evals/replay-memoria.py` for future reuse.
- [ ] T2 — Baseline: run the gold battery against the current production prompt (score + cost).
- [ ] T3 — Reorganized prompt candidate(s): same or better exam score, fewer tokens; then staging;
  production only with the user's OK.
- [ ] T4 — One source for business data (accounts/holders in 9 nodes incl. deposit registration),
  with benches for every touched node.

## Constraints
- Production is not changed by this work without the user's explicit OK (cutover 2026-09-27).
- Exams call the real model (small cost); nothing writes or sends.
- Staging Cerebro shares production WhatsApp/AI credentials: live checks only with the test contact.

## Progress
- 2026-09-26: document created.
