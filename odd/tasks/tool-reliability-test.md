# Tool reliability test (gate 76)

Objective: measure whether the production Cerebro agent (deepseek-flash, official n8n DeepSeek node)
calls its write tools when a conversation requires them, and whether a corrected prompt with flexible
(partial-friendly) tools changes that. First step of `odd/design/beneficiary-draft.md` per the owner
(2026-10-01): "probar si el modelo puede usar herramientas de forma fiable".

Problem: in 14 days the model called any tool in 3.4% of its turns, `registrar_reparto_multiple` 3
times, and 28% of its "Anotado" replies had no write behind them (see the design doc, section 2).

Scope (authorized 2026-10-01, "si, móntala así y hazla"):
- Temporary, isolated n8n workflows in the production n8n (created and deleted by the script).
- Same system prompt, model node, memory type and tools as production `Agente Remesas`.
- Write tools neutralized (no real writes): they return a canned or argument-derived answer.
  Read-only tools (rates, calculators, services) stay live; `calcular_usd` runs without its
  `cerebro_fijar_objetivo` side effect.
- Ephemeral memory keys `gate76-<run>-...` in `cerebro_memoria`, deleted at the end.
- No WhatsApp, no production workflow changed (checked byte-identical before/after).

Arms:
- A: production prompt + production tool descriptions + production-like Decisor notes (baseline).
- B: same model; prompt says "a datum is saved only by calling the tool; never say Anotado without
  it"; reparto tool accepts partial data and answers what is missing; notes ask to register what
  is there and ask for the rest.

Acceptance: per scenario and arm, rate of (a) the expected tool called with the right key arguments
by the expected turn, (b) "promise without call" turns. Decision rule agreed with the owner: if B
uses the tools reliably, the fix is tools + prompt; otherwise another mechanism is needed.

TDD: not applicable (measurement harness, no product code). Checks: harness dry run (1 scenario,
1 repetition) before the full run; cleanup verified (0 memory rows, temp workflows absent,
production byte-identical).

Harness: `~/cerebro-fase1/pruebas/gate76-experimento.py` (outside this repo, next to gates 70-75).
Results: `~/cerebro-fase1/pruebas/gate76-resultados.jsonl`, summary copied below.

## Tasks
- [x] T1 Build harness + scenarios (arms A/B), dry run 1x1 (run 63483bdd; first dry run 6b779d9f failed
      on missing `Contexto conversacion` stand-in, fixed)
- [x] T2 Full run (8 scenarios x 3 repetitions x 2 arms), run of 2026-10-01 ~23:40 UTC
- [x] T3 Analyse and report
- [x] T4 Replay REAL production turns that said "Anotado" without a write, with their exact agent input
      and memory (authorized 2026-10-01). Harness `~/cerebro-fase1/pruebas/gate77-replay-real.py`.

## Progress / evidence
Cleanup verified on every run: memory rows of the run deleted (336 in the full run, 0 left), the 3
temporary workflows absent, production workflow fingerprint identical before/after.

Full run result (expected tool + right key arguments by the expected turn):

| Scenario | A (production) | B (corrected) |
|---|---|---|
| yeny_cada_una_si (2 cards, "cada una", phone for both) | 3/3 | 3/3 |
| reparto_explicito | 3/3 | 3/3 |
| zelle_en_partes | 3/3 (3 "Anotado" before the name) | 3/3 (2) |
| zelle_correccion_nombre | 3/3 | 3/3 |
| la_de_siempre | 3/3 | 3/3 |
| dictado_por_voz | 3/3 | 3/3 |
| clasica_usd | 3/3 | 3/3 |
| reparto_cambia | 3/3 | 3/3 |
| Total | 24/24 | 24/24 |

Findings:
- The model CAN call its write tools reliably, with the right arguments, even with the production
  prompt (A). The low production call rate is not a model capability problem.
- B behaves as designed: it registers partial repartos from the first turn and re-calls on every
  change (A waits until everything is complete, which is what lost Yeny when the bot was paused).
- The remaining "promise" in both arms is "Anotado" for a Zelle number before the holder's name:
  no tool can store it today (no partial Zelle tool).
- 11 of the 12 production tools have no manual description (only registrar_reparto_multiple does);
  A still worked, so this is not the cause by itself.
- What the test does NOT reproduce, and is therefore the prime suspect: the real production context
  (5-10k chars of notes per turn, many "NO hay tool que llamar / PROHIBIDO", 30 real memory messages
  including admin turns, ~53k input tokens) and the bot being paused at the moment the data
  arrives. Next step T4 measures exactly that.


## T4: replay of real production failures (gate 77)

Source: the 32 bot replies of the last 14 days that said "Anotado/queda..." with no write. Excluded:
no tool exists for them (Mexico, recargas, a lone phone, a Zelle number without a name) or no memory
row to rebuild. Kept: 11 turns; each replayed with the exact human input stored in `cerebro_memoria`
(customer text + the full Decisor context) and the 30 memory rows loaded before it, 3 repetitions.

| Arm | What changes | Result |
|---|---|---|
| A | nothing (production prompt, real input) | 0/33 — reproduces production exactly |
| A2 | real input, the false sentence "YA ESTA REGISTRADO EN EL TABLERO: NO hay ninguna tool que llamar" replaced by production's own truthful sentence | 25/33 |
| B2 | A2 + gate 76's corrected prompt and tool descriptions | 30/33 |

The 3 misses of every arm are one case (`oberto_correccion`): a Mexico remittance handled by an admin,
for which no tool exists, so it is not a valid case. On the 10 valid Zelle cases: A 0/30, A2 25/30,
B2 30/30.

Root cause found: in 10 of the 11 real turns the Decisor told the model the Zelle was ALREADY
registered and that there was no tool to call, and it was not. `Contexto conversacion` computes
`tiene_beneficiario` as "any open operation of this conversation has any complete vigente
beneficiary"; it never checks that the Zelle detected in this turn is the registered one. Katalella
2026-10-01 14:33: her stuck open operation f9289dc7 had "RF Consulting Business", so the new Zelle
"Rodolfo valiente / rvalienter@outlook.com" was announced as registered. The model obeyed the context.

Fix order this points to (not implemented, needs the owner's go):
1. Make "already registered" true only for the datum detected in this turn and the operation in
   progress (alone: 0 -> 83%).
2. Prompt "regla de oro" + real tool descriptions (with 1: 100% on these cases).
3. Partial-friendly tools (Zelle number before the name, reparto in steps), per the owner's request.


## T5-T6: fixes 1 + 2 implemented, tested on the real cases, deployed (gate 78, owner's go 2026-10-01)

Harness: `~/cerebro-fase1/pruebas/gate78-candidato.py` (construir / probar / desplegar) and
`gate78-banco-decisor.js`. Rollback: `~/cerebro-fase1/pruebas/ROLLBACK-78-cerebro-20261001-180009.json`
(full workflow before the change, base version 0d7de989).

- [x] T5 Fix 1: `Contexto conversacion` returns `beneficiarios_registrados` (vigente beneficiaries of the
      open operations); the Decisor says "YA ESTA REGISTRADO" only when the detected Zelle (account +
      name) or card + phone is in that list, otherwise "NO ESTA REGISTRADO TODAVIA ... llama ... EN ESTE
      MISMO TURNO" (Zelle) / "TARJETA Y CELULAR DETECTADOS PERO NO REGISTRADOS ... llama
      gestionar_beneficiario" (Cuban). Without the list the old flag is used.
- [x] T6 Fix 2: prompt "REGLA DE ORO DEL REGISTRO" (only a tool call saves a datum; no "anotado" without
      it), the "UNA sola vez" rules allow re-calling on a correction, manual descriptions for
      gestionar_beneficiario, registrar_beneficiario_zelle, marcar_destino_usd,
      registrar_datos_entrega_efectivo, derivar_humano. Partial tools (fix 3) not included.

Checks before deploy:
- Decisor bank (193 existing cases, base vs candidate, local): 0 broken; 186 identical; 7 differ only in
  the new wording of the not-registered Zelle sentence. 5 new gate-78 cases OK (Katalella shape, same
  Zelle registered, corrected name, Cuban pair registered / not registered).
- New SQL column run read-only on production data (returns the expected lists; conversation 8d6d9758 still
  has a stuck open operation with another Zelle, the shape that produced the false sentence).
- Real replay, 10 Zelle turns x 3: candidate 28/30 (production 0/30). The 2 misses: yoel_primo, the bot
  asks for the holder's name (the name came from an earlier turn) instead of registering, once with an
  "Anotado".
- Clean scenarios x 3: candidate 23/24 (production 24/24). The miss: reparto_explicito rep 3, the bot asked
  which phone goes with which card and said "Anotado el reparto" without calling.
- No miss wrote wrong data; all are "asked instead of registering", one wording violation each.

Deploy: REST PUT with drift check (Contexto, Decisor, prompt, descriptions equal to the tested base),
exactly 8 nodes changed (the 3 + 5 tools), connections identical, workflow active, active version
a2b2851d-1eff-4761-b368-4fd2370a1a7a. The full Contexto query validated live with EXPLAIN.

Pending: watch the first real turns with a Zelle/card in production; residual "Anotado" while asking a
question (a deterministic guard on the reply, or fix 3) is the next lever.
