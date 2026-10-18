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
- [x] T2 Baseline: the gold battery against the current production prompt (score + cost), plus a
      second run through `comparar_informes.py` to separate real reds from model variance. Advances
      T2 of `odd/tasks/cerebro-context-prompt.md`.
- [~] T3 (files written, locally syntax-checked; RED/GREEN on staging pending) Lead candidate:
      one `cotizar` replacing
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

Run B (2026-10-18 01:33Z, `informes/informe-20261017-193341.json`, on the hardened harness, zero
execution errors): **46 VERDE / 2 ROJO / 12 SALTADO of 60**.

`comparar_informes.py` over the two runs — **60 common cases, 58 stable, 2 unstable, stability
97%**. Both unstable cases went ROJO -> VERDE: `reg-27065-multi-herramienta` and
`reg-32598-otros`. Their red in run A is therefore model variance, not a defect.

### BASELINE OF RECORD (T2 done)
- Score: **44/60 and 46/60**, stability 97%.
- **Stable reds: exactly 2, and BOTH are calculator cases** —
  `reg-27486-calculo-con-herramienta` (run A: did not call `calcular_usd`, 13000 missing; run B:
  "no pregunta nada") and `reg-30178-calculo-con-herramienta` (figure 115 missing in both).
- 12 SALTADO are a known limitation (they need a `historial` reconstructed from `cerebro_memoria`),
  not a failure.
- T3 acceptance, now concrete: at least 46/60 with the same 97% stability, and those two stable
  reds must not get worse. Any single red must be re-run before it is read as a regression.

This is the measured case for the lead candidate: the ONLY two stable failures in the whole gold
battery are in the four calculators being merged. Logs: `scratchpad/baseline-t2.log`,
`scratchpad/baseline-t2-runB.log`.

### T3 design decided (not yet implemented)
One SQL function `cerebro_cotizar(p_conv, p_monto, p_direccion, p_moneda_destino, p_via,
p_execution_id)` holding the four existing branches VERBATIM — same rounding per branch (round /
ceil-to-20 / floor), same Zelle tier helpers, `cerebro_fijar_objetivo` still only on the USD-send
direction — behind ONE uniform output shape, with the n8n tool as a thin
`SELECT cerebro_cotizar(...)`. Migration 243 (production DB through 239, staging through 242).
- Output unified to stable generic names (`deposita_gyd`, `recibe_monto`, `recibe_moneda`, `tasa`,
  `aplica_a`) rather than today's six different column sets (`cup_a_entregar`,
  `monto_a_depositar`, `usd_a_enviar`, `gyd_a_depositar`, `usd_a_recibir`,
  `gyd_exactos_para_esos_usd`). Collapsing the prompt's routing is the whole point; leaving six
  shapes would keep it.
- The per-direction tool LABEL is preserved when calling `cerebro_registrar_cotizacion` and
  `cerebro_registrar_via_cotizada`, so those rows and
  `cerebro_verificar_coherencia_servicio` keep their current meaning.
- Efectivo is refused by the function itself instead of by three prompt lines.
- TDD: a parity assertion proving each branch returns, for the same inputs, exactly what the old
  tool returned today — the same shape of proof as the panel-vs-bot parity in
  `bot-change-service.md` case e.

### T3 — files written 2026-10-17, NOT yet proven
Three files, nothing applied anywhere:
- `supabase/migrations/243_cerebro_cotizar.sql` — `cerebro_cotizar(p_conv, p_monto, p_direccion,
  p_moneda_destino, p_via, p_execution_id) RETURNS jsonb`, service_role only. PURELY ADDITIVE: it
  creates one function and alters nothing, so the Cerebro behaves exactly as today until the n8n
  workflow is edited (a separate, PUT-reversible step).
- `supabase/migrations/ROLLBACK-243-cerebro-cotizar.sql` — one `DROP FUNCTION`, no data lost. Notes
  the ordering trap: if the workflow already points at the merged tool, PUT the workflow back FIRST.
- `supabase/staging/assertions/cerebro-cotizar.sql` — 13 expectations. Parity is measured by running
  each ORIGINAL expression inline against the SAME live `tasas` row and demanding the merged
  function return exactly that. No fixture rate is created: `tasas` is a VIEW and rejects INSERT
  (tasas-derives.sql case 5), and parity is relative anyway, so comparing both sides under the real
  rate is the stronger test.

Local verification done (throwaway `postgres:17` container, nothing remote): 243 reaches
`CREATE FUNCTION` + `COMMENT` cleanly — with `check_function_bodies` on, that is a real syntax check
of the plpgsql body — and the only error is `role "anon" does not exist`, expected without the
Supabase roles. The assertion's `DO` body was converted into a function so plpgsql would parse it
without executing: it parses clean. That check caught a genuine bug while writing (a duplicated
`INTO` in case h3), now fixed.

### T3 SQL proven on STAGING (owner go-ahead 2026-10-17 "si aplica y corre la assertion")
Runner: docker `postgres:17` psql against `CRM_STAGING_DATABASE_URL` (in `.env.staging`), every
assertion run wrapped in `BEGIN; ...; ROLLBACK;` — never plain `psql -1`, which can COMMIT a fixture.

- **RED** before the migration: `function cerebro_cotizar(uuid, integer, unknown, unknown, unknown,
  unknown) does not exist`, raised at case a. The fixture built fine up to that point.
- **Rehearsal**: 243 and the assertion applied in ONE transaction and rolled back ->
  `ALL PASS (13 expectations)`, nothing committed. Observed parity figures, against the live staging
  rates: 30,000 GYD -> 90,000 CUP at 3; 100,000 CUP <- 33,340 GYD (a multiple of 20); 115 USD <-
  29,900 GYD at 260; 30,000 GYD -> 115 USD. Those are the very figures the two stable baseline reds
  were missing (reg-27065 wanted 90000, reg-30178 wanted 90000 and 115) — the merged function
  computes them correctly.
- **Applied for real** (`BEGIN; <243>; COMMIT;`), then the assertion re-run on the committed state:
  13/13 PASS again.
- **Fingerprint**: `cerebro_cotizar` md5 `8262fc8f010694202f6e7b4cfce993ad`, ACL
  `{postgres=X/postgres,service_role=X/postgres}` — service_role only, no anon, no authenticated.
- **Rollback proof** in a reverted transaction: ROLLBACK-243 drops it (count 0); after that
  transaction rolled back staging still has it (count 1).
- **Leftovers: none.** 0 contacts `59900243001`, 0 accounts `cerebro cotizar test account`.

Staging is left WITH 243. Production untouched.

STILL NOT DONE, and it is the part that answers "does it actually improve anything": the n8n tool
has to be swapped on the STAGING Cerebro and the gold battery re-run against the bar (>= 46/60 at
97% stability). The SQL being green only proves the arithmetic is identical and the cash bug is
closed; it says nothing yet about whether the model picks the merged tool better than it picked one
of four. That needs the owner's go-ahead, and note the drift warning in `bot-change-service.md` B2:
10 staging nodes differ from production, `Agente Remesas` among them, so a staging battery run must
either use `--workflow` against production's prompt or the drift must be closed first.

Helper signatures the function calls (all declared with the `public.` prefix, which is why a first
grep without it found nothing): `cerebro_tasa_zelle(p_usd numeric) RETURNS numeric`;
`cerebro_zelle_cotizar_gyd(p_gyd numeric) RETURNS TABLE(usd numeric, tasa numeric)`;
`cerebro_fijar_objetivo(p_conv uuid, p_monto numeric, p_moneda text DEFAULT 'GYD') RETURNS TABLE(...)`;
`cerebro_registrar_cotizacion(uuid, numeric, numeric, text, text) RETURNS void`;
`cerebro_registrar_via_cotizada(uuid, text, text, text, numeric DEFAULT NULL) RETURNS void`.

### A latent bug found while writing it
Today `via='efectivo'` does NOT match the single-rate regex `^(cl[aá]sica|tropical|m[eé]xico|usdt)`
in `calcular_usd` / `calcular_usd_desde_gyd`, so cash falls into the Zelle branch and is quoted BY
TIERS — the wrong rate, with nothing to show anything went wrong. That is exactly what the prompt
tries to prevent in three separate places (lines 106, 163, 179). The merged function refuses it in
SQL instead, and case h of the assertion proves both the refusal and the old premise.

### T3 experiment result — THE HYPOTHESIS DID NOT HOLD (2026-10-18)
Option 2 chosen by the owner: a bounded arm instead of rewriting 55 gold cases. Harness
`~/cerebro-fase1/pruebas/evals/cotizar_arm.py`. Design: ONE variable changes — the four calculators
become `cotizar(monto, direccion, moneda_destino, via)` — and the prompt PROSE is left identical,
only the call forms mechanically rewritten, so a change in outcome cannot be blamed on a new prompt.
The mock invents no rates: it dispatches on ARGUMENTS and returns the case's own arbitrated numbers
translated to the new shape (the recorded mocks use inconsistent rates — 3 for envio, 2.8 for
inverso, 260 flat for USD — so one global simulator could not reproduce the expected figures).
`cifras_exactas` untouched.

Result over the calculation families, 17 cases x 2 reps: **29/34 green**.

Case-by-case against the two baseline runs:
| case | base A | base B | candidate |
|---|---|---|---|
| 12 stable cases | VERDE | VERDE | VERDE (no regression) |
| `reg-27065-multi-herramienta` | ROJO | VERDE | VERDE (was already unstable, no credit claimed) |
| `reg-27486-calculo-con-herramienta` | ROJO | ROJO | **ROJO** |
| `reg-30178-calculo-con-herramienta` | ROJO | ROJO | **ROJO** |
| `reg-28021-multi-herramienta` | VERDE | VERDE | ROJO/VERDE (new instability) |

**The merge did NOT fix either stable red.** And the evidence says why: in both, the candidate called
no quote tool AT ALL (`pidio=[]`), exactly as the baseline called no calculator. The failure was
never "picked the wrong tool out of four" — it is "did not realise it had to quote". Merging cannot
fix a choice the model never reaches. The inference that led here — the only stable reds are
calculator cases, therefore the four-way split causes them — was wrong: it confused the AREA of the
failure with its CAUSE.

What the merge did deliver, and still stands:
- No regression on the 12 stable green cases: one parameterised tool handles them as well as four.
- The cash bug is closed in SQL (proven by the staging assertion), independently of ergonomics.
- 16 -> 13 tools. The prompt prose was deliberately NOT shrunk in this experiment, so that saving
  is still only potential.

Honest caveat on the measuring stick: this arm scores directions + `cifras_exactas` only, while the
full battery also checks forbidden text, `debe_preguntar_algo` and forbidden tools. It is a WEAKER
scorer, so its green count is not comparable to 46/60 and no improvement should be read from it.

`reg-28021` going from stable green to unstable is one data point over two reps, inside the
baseline's own ~3% flip rate. Not callable as a regression, not dismissable either.

Two of my own harness bugs were found and fixed while running this, both of which would have
produced false conclusions:
1. `cotizar` calls were INVISIBLE to the scorer (the same class as T1: the arm adds the tool after
   `contrato_vivo()` syncs `HERRAMIENTAS`). Uncaught, this arm would have reported 0/34 and I would
   have told the owner the merge breaks everything.
2. A home-made `cifras_exactas` matcher split card numbers, which the prompt requires written in
   groups of four, giving `reg-32899` a false ROJO on both reps. Replaced by the project's own
   `E.cifra_presente`, which allows a separator between every digit. Re-scored from the saved report
   with no extra model calls: 27/34 -> 29/34.

### Why the model does not call the tools — root cause of the two stable reds (2026-10-18)
Owner asked for the causes. Neither red is a tool problem, and one is not a bot problem at all.

**`reg-30178` is a STALE TEST. The bot is right and the case is wrong.**
Message: `Voy a tranferir 30mil gy a las 5 pm`. The case expects the figures 90000 and 115, recorded
from production in 2026-08. The CURRENT prompt forbids producing them:
- line 113 `COTIZACION SIN MONEDA DE DESTINO`: a GYD amount with nobody having said the destination
  currency -> "TODAVIA NO calcules ni des cifras", ask the currency first, "PROHIBIDO asumir CUP".
- line 355 carries THIS EXACT MESSAGE as a worked example, and the prescribed answer is the one the
  model gave: ask which currency and where they will deposit.
So the model obeyed a rule the owner added after the case was frozen. The expectation is outdated,
exactly the hazard `cerebro-context-prompt.md` warned about ("stale expectations in those files").

**The prompt CONTRADICTS ITSELF on that same scenario — and this one is a real defect.**
- line 108: "Misma frase, moneda de destino NO dicha -> calcular_envio(monto, gyd) Y
  calcular_usd_desde_gyd(monto), respondes con las DOS (ver COTIZACION SIN MONEDA DE DESTINO)"
- line 113: same situation -> "TODAVIA NO calcules ni des cifras", ask instead.
Line 108 says quote BOTH and cites line 113 as its reference; line 113 says quote NEITHER. Line 108
is the pre-change behaviour that was never removed. A contradictory instruction makes invocation
depend on which rule wins on a given run, which is a plausible mechanism for exactly the kind of
flip seen in `reg-28021` (stable green in both baseline runs, green/red in the candidate).

**`reg-27486` is an ambiguous customer message, not a missed tool.**
Message: `Amigo deposite en su cuenta para 50 zelle`. Without the accent, "deposite" reads either as
the imperative or as "deposité" (already deposited). The arbitration of 2026-08-12 chose "deposits
GYD for 50 USD" -> quote 13,000. The candidate read it as a deposit ALREADY MADE and moved the
conversation on: "¿A nombre de quién está la cuenta Zelle...? Y envíenos la captura de su depósito".
Under that reading, not quoting is correct. Production in 2026-08 did call a calculator but replied
"no le entendí bien"; the current reply is arguably more useful. One defensible reading scored
against another, not a capability failure.

**Already-settled evidence that this is not a capability problem.** Gate 76 measured the model
calling its write tools 24/24 with the production prompt. Gate 77 found the real historical cause of
non-invocation was a FALSE CONTEXT SENTENCE telling the model the datum was already registered and
there was no tool to call (fixed in T5/T6, 0 -> 83% alone, 100% with the prompt rule).

**A measurement blocker to fix before chasing this in production.**
`partial-beneficiary-tools.md` T5 records `cerebro_telemetria_turno.model_calls` as NULL on every
turn since 2026-09-29 23:44 (and on 699 of 905 baseline turns), so the original "3.4% of turns
called a tool" metric is NO LONGER MEASURABLE; that window had to use a proxy. Any real
investigation of invocation rate in production needs that telemetry fixed first. Listed there as a
pending follow-up.

### Where this leaves the feature
The SQL (243) is worth keeping on its own merits: it closes the cash-quoted-as-Zelle bug and is
additive and reversible. The TOOL SWAP in n8n is not justified by this evidence — it buys
simplification, not reliability. The two stable failures need a different lever: both are
non-invocation, which points at the prompt and the context, not at the tool surface. That is what
T2/T3 of `odd/tasks/cerebro-context-prompt.md` were always about.

### Analysis
- 2026-10-17: read-only analysis of the production Cerebro (126 nodes, 16 tools, 373-line prompt)
  and of 5 Cerebro ODD docs. Candidate ranking CORRECTED: the `marcar_destino_usd` +
  `cambiar_servicio` merge was proposed first and is now rejected on the evidence in
  `bot-change-service.md` (migration 231 guards, pending-row trigger, advisory lock, divergent
  enums with an open owner decision). The four-calculator merge becomes the lead candidate.
  Engram: `cerebro/tools/consolidation-analysis`.
