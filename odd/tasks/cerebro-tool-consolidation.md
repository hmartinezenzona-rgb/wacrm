# Cerebro: consolidate agent tools without losing functionality

## Objective
Reduce the Cerebro agent's tool surface by merging tools that are the same operation split by a
name, and move the routing they need out of the system prompt into the tool schema and SQL, where
the model reads it at the call site. Measured against the existing gold battery before and after
every step. No functionality is dropped.

## Why (owner, 2026-10-17)
The owner asked to look for tools that can be merged "que no pierda funcionalidad y que mejore",
to research the best way to do whatever is done, and to improve the current prompt as long as it
works better and nothing that already works is lost. Same approach as the vision change of
2026-10-17.

## Problem (measured 2026-10-17, read-only, production `jEzlVLCLUaJhVwzs`)
- Agent `Agente Remesas` (langchain agent v3.1), `maxIterations` 6, 126 nodes.
- 16 `n8n-nodes-base.postgresTool` tools (12 at the gate-76 test on 2026-10-01).
- System prompt 51,550 chars / 373 lines. It was 38,581 chars when T1 of
  `odd/tasks/cerebro-context-prompt.md` measured it on 2026-09-26 (+34%). That T1 measured input
  tokens median 36,224, p90 48,402, max 49,992, system prompt at 36% of input chars.
- 6 of the 16 tools have NO manual `toolDescription` (`consultar_tasas`, `calcular_envio`,
  `calcular_inverso`, `calcular_usd`, `calcular_usd_desde_gyd`, `consultar_servicio`): their whole
  semantics live in prompt lines 101-117. NOT a reliability bug — gate 76 measured arm A at 24/24
  with the descriptions absent. It is cost and maintainability.
- Prompt defects: lines 210 and 211 are the same ORTOGRAFIA rule near-verbatim; the efectivo
  routing to `consultar_servicio('efectivo_usd')` is stated three times (106, 163, 179); the SQL
  comment in `calcular_envio` references a tool `calcular_zelle` that does not exist.

## Candidate ranking (corrected 2026-10-17 after reading `odd/tasks/bot-change-service.md`)

### LEAD CANDIDATE — the four calculators -> one `cotizar`
`calcular_envio` / `calcular_inverso` / `calcular_usd` / `calcular_usd_desde_gyd` are one
operation: a conversion between the GYD the customer deposits and what the beneficiary receives,
in one of two directions. All four already read `tasas`, compute, and register the quote through
`cerebro_registrar_cotizacion` + `cerebro_registrar_via_cotizada`. The only differences are
rounding (round / ceil-to-20 / floor) and the Zelle tiers, all functions of (direction,
destination currency, via) — parameters, not separate tools. `calcular_usd` additionally calls
`cerebro_fijar_objetivo`.

Evidence FOR, from the system's own direction of travel: migration 231(d) added
`cerebro_registrar_via_cotizada`, which all four call uniformly, and
`cerebro_verificar_coherencia_servicio` reads "the LAST quote of the execution" regardless of
which calculator produced it. The contract already converged.

Also folds into SQL what the prompt now repeats: a merged tool can REFUSE efectivo itself instead
of the prompt forbidding it in three places. That is the project's own written principle — the
comment inside `calcular_usd` says "una instruccion en el prompt no es un control", recorded after
`fijar_objetivo` was measured 0 of 2 as a prompt instruction.

Dependency to handle, NOT a blocker: `cerebro_registrar_cotizacion` and
`cerebro_registrar_via_cotizada` both take the tool name as an argument, and the coherence net logs
`tool_name` = the quote tool. The merged tool must keep passing a distinct label per direction so
those rows and that net keep their current meaning.

### REJECTED — `marcar_destino_usd` + `cambiar_servicio`
Proposed first, then withdrawn on evidence. The split is deliberate and was hardened nine days ago:
- Migration 231(c) added a stale-write guard to `cerebro_marcar_destino_usd` that refuses with
  "ya elegiste X" / "la via vigente de la operacion es X (la cambiaste con cambiar_servicio)". The
  ERROR first cited as an argument FOR merging is that guard. Before it, the 096 lock suppressed
  the write while the tool still answered "destino marcado": the agent was told the opposite of the
  truth. The honest refusal is the fix, not a wart.
- `cambiar_servicio` carries its own no-operation-yet machinery: a `cerebro_destino_pendiente` row
  (`origen='agente'`, 24 h), the AFTER INSERT trigger `trg_zz_destino_agente_al_crear`, and a
  per-conversation advisory lock closing the "pending written while the operation is being created"
  race. `marcar_destino_usd` has its own operation-CREATING branch instead.
- The enums differ on purpose (`cerebro_cambiar_servicio` also accepts recarga / combo / visa /
  saldo), and open decision gap #5 of `bot-change-service.md` asks the owner whether the bot should
  reach those at all. Merging would silently answer a question the owner has not answered.
- Different audit and log contracts: `cambiar_servicio` writes `automation_service_change`, retires
  and retypes recipients, re-quotes and stamps an `automation:` rail lock;
  `marcar_destino_usd` logs marcado | sin_cambios | rechazado | tipo_invalido | operacion_ambigua.
Merging them would collapse two migrations of race, lock and audit semantics for one fewer tool.

### DEFERRED — `gestionar_beneficiario` + `registrar_reparto_multiple`
Same operation at N=1 vs N=2..3, but backed by different SQL merge functions
(`cerebro_guardar_beneficiario` vs `cerebro_guardar_reparto`) whose D1 semantics are hardened by
migration 179 assertions. Saves one tool and touches the most safety-critical recently-stabilized
path.

### RECOMMENDED AGAINST — the recarga / combo / visa openers
Genuinely different data shapes. A generic `registrar_servicio(servicio, json)` is harder for the
model to fill correctly than named parameters, and named parameters are the thing that works here.

### SEPARATE QUESTION — `consultar_tasas`
Drop-not-merge: 0 params, pure SELECT, and the rates are already injected into the `[CONTEXTO]`
every turn by the `Decisor` ("TASAS DE HOY, leidas de la base en este mismo momento", conditional
on `partes.length` from `Ultima cotizacion`). Small and measurable on its own; not bundled here.

## Scope
Authorized 2026-10-17 ("dale empieza") for: fix the harness defect, run the baseline, then the
lead candidate. The ranking changed after the authorization, so the lead candidate itself is
re-confirmed with the owner before any SQL or n8n work.

Out of scope: the memory/context token work. The owner closed it on 2026-09-26 ("does not want to
sacrifice context", T3a closed with nothing applied). Any token saving here targets the SYSTEM
PROMPT only.

## Method (reuses what already exists — not reinvented)
- Gold battery `~/cerebro-fase1/pruebas/evals/evaluar.py`: runs gold cases against the REAL model
  through temporary n8n workflows with mocked tools (no DB, no WhatsApp), scoring deterministically
  on required/forbidden tools, exact figures and forbidden text. Battery arbitrated by the owner on
  2026-08-12. `comparar_informes.py` measures model variance between two runs of the same prompt,
  so a single green or red is never read alone.
- Case counts: `casos-conversaciones.json` 75, `casos-cambio-servicio.json` 21,
  `casos-orden-beneficiario.json` 12, `casos-regresion.json` 12, `casos-catalogo-servicios.json` 8,
  `casos-efectivo-usd.json` 4.
- `--prompt <file>` examines a candidate prompt without touching production.
  `candidato_produccion.py` reads a dry candidate workflow and aborts any non-GET mentioning the
  production id.
- Gate pattern for any n8n edit (from `bot-change-service.md` B1): `python3 gateNNN.py
  staging|produccion [--seco]`, GET the workflow, save the full pre-change JSON as the rollback,
  `rep(text, old, new)` asserting each marker occurs exactly once, edit only the named nodes, PUT
  with only `name, nodes, connections, settings`, then read back `active` and
  `versionId == activeVersionId`.
- SQL: self-reverting assertions wrapped in `BEGIN; <assertion>; ROLLBACK;` with the docker
  `postgres:17` psql — never plain `psql -1`, which can COMMIT a fixture.

## Corrections to stale notes found while planning
- `cerebro-context-prompt.md` says `evaluar.py` still reads the old workflow `T3v07IQqtMs6AKJ4`.
  Stale: `evaluar.py:43` already points at production `jEzlVLCLUaJhVwzs` (fixed 2026-09-28). The
  old id only remains in `cosechar.py` (the harvester).
- `bot-change-service.md` leaves C2 (migrations 230 + the new 231 to production) unchecked, but the
  handoff of 2026-10-17 records production DB through migration 239, and the production workflow
  does carry the guarded `cambiar_servicio` tool. The checkbox is stale, not the deployment.
- `~/cerebro-fase1` is NOT a git repo: harness edits are backed up to `*.bak-<date>` beside the
  file. `pruebas/evals/contrato/` is the arbitrated reference of 2026-08-12 and is NOT regenerated.

## TDD
Strict TDD is on globally. Applied per layer, following `tool-reliability-test.md` and
`partial-beneficiary-tools.md`:
- Measurement harness code: TDD not applicable (no product code), but every fix is proven RED then
  GREEN with an observable run.
- SQL: self-reverting assertions, RED before the migration, GREEN after, plus a rollback proof.
- Bot behaviour: the gold battery plus a variance run, never a single pass.

## Tasks
- [x] T1 Harness defect: the scorer records tool calls only for a hardcoded 11-tool set
      (`HERRAMIENTAS`, `evaluar.py:48`) while production has 16. `HERRAMIENTAS & set(run)` makes
      `cambiar_servicio`, `registrar_datos_entrega_efectivo`, `registrar_numeros_recarga`,
      `registrar_destinatario_combo` and `abrir_extension_visa` INVISIBLE in the report, so any
      baseline involving them is wrong. Derive the set from the live contract.
- [ ] T2 Baseline: the gold battery against the current production prompt (score + cost), plus a
      second run through `comparar_informes.py` to separate real reds from model variance. Advances
      T2 of `odd/tasks/cerebro-context-prompt.md`.
- [ ] T3 (owner re-confirmation after the ranking change) Lead candidate: one `cotizar` replacing
      the four calculators, preserving the per-direction tool label for
      `cerebro_registrar_cotizacion` / `cerebro_registrar_via_cotizada` and the coherence net; SQL
      assertions RED then GREEN; prompt lines 101-117 rewritten; battery equal or better than T2.
- [ ] T4 Staging deploy with a rollback copy, then the battery and a live smoke on staging.
- [ ] T5 Production, only with the owner's explicit go-ahead, with a rollback copy and a drift
      check; then watch the first real cases.

## Acceptance criteria
- No functionality lost: every quote reachable today is still reachable, and the gold battery
  scores the same or better than the T2 baseline, with variance measured rather than assumed.
- `cerebro_registrar_cotizacion`, `cerebro_registrar_via_cotizada` and
  `cerebro_verificar_coherencia_servicio` keep their current meaning.
- Prompt lines that only existed to route between the four calculators are gone.
- Production is not touched without the owner's explicit go-ahead.

## Progress / evidence

### T1 — scorer blind to 5 of the 16 production tools (done 2026-10-17)
`~/cerebro-fase1` is not a git repo; backup `evaluar.py.bak-20261017` (md5 of the original
8eda8400a348d74f255782b010370f98). Fix lives inside `contrato_vivo()`, not `main()`, because 7
scripts call it: `candidato_produccion.py`, `carlos_multiturno.py`, `carlos_multiturno_prod.py`,
`evaluar_cambio_servicio.py`, `evaluar_cambio_servicio_prod.py`, `experimento-nodo-deepseek.py`
and `evaluar.py` itself. Union, not replacement, so the manual
`E.HERRAMIENTAS = set(E.HERRAMIENTAS) | {"cambiar_servicio"}` that four of them do at import time
survives (and becomes redundant). `cosechar.py` keeps its OWN separate set at line 29 and is
untouched — it is the production harvester and still carries the stale workflow id
`T3v07IQqtMs6AKJ4`; noted, not chased here.

Proof (probe against the LIVE production contract, GET only):
| | live tools | scorer set | invisible |
|---|---|---|---|
| RED (before) | 16 | 11 | `abrir_extension_visa`, `cambiar_servicio`, `registrar_datos_entrega_efectivo`, `registrar_destinatario_combo`, `registrar_numeros_recarga` |
| GREEN (after) | 16 | 16 | none |

All 8 scripts compile (`py_compile`). The diff is exactly the 9 added lines, nothing else. Harness
smoke after the fix: `evaluar.py --solo doble-pregunta-tasa-y-calculo-inverso` -> VERDE, tools
recorded `['calcular_inverso', 'consultar_tasas']`, temp workflow cleaned up, report
`informes/informe-20261017-171218.json`.

### T1b — the harness crashed on a transient timeout and leaked a workflow (fixed 2026-10-17)
Found by running T2, not by inspection. In `correr_caso` and `correr_caso_multiturno` the
`POST /api/v1/workflows` that creates the temp workflow sat OUTSIDE the `try`, and the `finally`
could only clean up by `wf['id']`. Consequences, both observed: a `TimeoutError` on that POST
killed run B at case 51 of 60 (losing the run) and left the orphan workflow `p9D31AoI05c9KSzK`
"ZZ EVAL temporal (se borra solo) reg-32742-otros" in the PRODUCTION n8n (inactive, 0 triggers,
22 nodes). Deleted through the harness's own `api()` after asserting the name prefix and that it
was inactive; `search_workflows "ZZ EVAL"` then returned 0.

Fix: the POST moved inside the `try` with `wf = None` first, plus a new `_borrar_temporal(wf,
nombre)` that cleans by id when there is one and otherwise SWEEPS BY EXACT NAME (the name carries
the case id), never propagating. A failed create is now a recorded case error instead of a dead
run. Public signatures of both functions unchanged, so the four external callers
(`evaluar_cambio_servicio{,_prod}.py:21`, `carlos_multiturno.py:22`,
`carlos_multiturno_prod.py:19`) are unaffected.

Proof with a stubbed `api` (no n8n touched): with an id -> deactivate + delete by id and NO sweep;
without an id -> sweeps, deletes only the orphan and does NOT touch
`Cerebro v2 — LEGACY OPTIMIZED V1` sitting in the same listing; the sweep itself failing -> warns
and does not propagate. All 8 scripts compile.

Caveat recorded in the docstring: the multi-turn temp name is NOT unique per case, so its
name-sweep is only safe while two runs are not in flight at once.

### T2 — baseline, run A done, run B relaunched
Run A (2026-10-17 17:26Z, `informes/informe-20261017-172650.json`): **44 VERDE / 4 ROJO /
12 SALTADO of 60 countable** (the 12 skipped need a reconstructed `historial`; the remaining 15 of
the 75 ids are multi-turn cases, which carry no verdict by design).

The 4 reds — 3 of 4 sit in the area the lead candidate touches:
| case | failure |
|---|---|
| `reg-27065-multi-herramienta` | did not call `calcular_envio`; figure 90000 missing |
| `reg-27486-calculo-con-herramienta` | did not call `calcular_usd`; figure 13000 missing |
| `reg-30178-calculo-con-herramienta` | figures 90000 and 115 missing |
| `reg-32598-otros` | wording only, unrelated |

NOT yet a conclusion: with one run these cannot be told apart from model variance, which is
exactly what `comparar_informes.py` exists for. Run B relaunched 2026-10-17 ~23:50Z on the
hardened harness; the baseline number and the red list stay provisional until it lands. Consumes
DeepSeek credit (relevant to the parked balance-alert item in the handoff). Logs:
`scratchpad/baseline-t2.log`, `scratchpad/baseline-t2-runB.log`.

### Analysis
- 2026-10-17: read-only analysis of the production Cerebro (126 nodes, 16 tools, 373-line prompt)
  and of 5 Cerebro ODD docs. Candidate ranking CORRECTED: the `marcar_destino_usd` +
  `cambiar_servicio` merge was proposed first and is now rejected on the evidence in
  `bot-change-service.md` (migration 231 guards, pending-row trigger, advisory lock, divergent
  enums with an open owner decision). The four-calculator merge becomes the lead candidate.
  Engram: `cerebro/tools/consolidation-analysis`.
