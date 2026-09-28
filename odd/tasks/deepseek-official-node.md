# Back to the official DeepSeek node

## Objective
Stop depending on the community node `n8n-nodes-deepseek-chat-model` if the official n8n DeepSeek node
no longer breaks tool turns.

## Problem / why
See `docs/negocio/12-el-modelo-no-debe-pensar.md`.
- **The official node failed.** With `deepseek-v4-flash` (adaptive thinking), when the model chained
  TWO tool calls in one turn, the API answered "The `reasoning_content` in the thinking mode must be
  passed back to the API" (n8n AI-2422). The customer got nothing.
- **The community node was the workaround.** It avoids this by switching thinking off, but it can
  leak the tool call as text (DSML).
- **The model barely calls tools.** Since 11-Aug the model has almost stopped calling them, which
  is why the automatic "twins" (`Registrar zelle auto`, `Registrar beneficiario auto`) exist.
- **Possible fix.** The user reports that n8n 2.39.8 fixes the reasoning_content problem.

## Plan (user, 2026-09-28)
1. Confirm the n8n version.
   - Not readable without a login: /rest/settings is minimal; Code nodes block `require` of the
     n8n packages; the n8n connector needs re-authentication.
   - The experiment answers the functional question anyway.
2. Temporary workflows with the official node instead of the community one, reusing `evaluar.py`
   pieces.
3. Conversations of 2–3 turns with memory that force tools, including the double question that
   always failed.
4. Measure per turn:
   - reasoning_content errors;
   - DSML leaks;
   - real tool calls (and turns with 2+ tools).
5. If clean: switch the staging Cerebro, test from the test chat, then production with a backup.

## Acceptance
- 0 reasoning_content errors and 0 DSML leaks in every tool turn.
- The model calls the tools.

## Tasks
- [x] E1 — Harness `~/cerebro-fase1/pruebas/evals/experimento-nodo-deepseek.py`.
  - Reads the CURRENT prod Cerebro (jEzlVLCLUaJhVwzs): prompt, agent, tools.
  - Mocked tools with fixed rates (2.8 CUP, 260 GYD/USD); RAM memory per conversation
    (memoryBufferWindow).
  - Nothing touches the DB or WhatsApp; every temporary workflow is deleted.
- [x] E2 — Full comparison: official vs community, 4 conversations x 3 repetitions (60 turns).
- [ ] E3 — If clean: staging Cerebro on the official node, live test from the test chat.
- [ ] E4 — Production with a backup, then watch.

## Progress
- 2026-09-28 first pass, official node (1 repetition, 10 turns):
  - 0 errors, 0 reasoning_content, 0 DSML;
  - 3 turns with 2–3 tools in the same turn (the case that ALWAYS failed before);
  - 11 real tool calls with correct figures.
- 2026-09-28 E2 — full comparison (`informes/experimento-deepseek-20260928-051811.json` +
  `-052001.json`).
  - Community: 30 turns, 0 errors, 0 reasoning_content, 0 DSML; 9 turns with 2+ tools; 33 calls.
  - Official: 30 turns, 2 "errors", both from the HARNESS: the no-argument mock of `consultar_tasas`
    read an undefined `query`. The official node calls a no-argument tool without `query`, and the
    agent still answered correctly.
    - Mock fixed; the double question was rerun 3x on the official node: 6/6 clean, all with 2–3
      tools.
  - Official total: 36 turns, 0 real errors, 0 reasoning_content, 0 DSML; 12 turns with 2+ tools;
    40 calls.
  - Both nodes chose the SAME tools in every comparable turn, with the same figures.
  - The first run was cut at turn 20 by an n8n network blip. The harness now retries and saves after
    every turn.
  - The acceptance criterion is met.
