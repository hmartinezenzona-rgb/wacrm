# Cerebro measurement: a battery that can tell a real change from noise

## Objective
Give the owner a measurement of the Cerebro agent that can say whether a change helps, hurts or
does nothing: replicated per-case results with uncertainty, token cost per case, and run metadata,
on a versioned battery. Then refresh the battery's frozen layers (T9 of
`odd/tasks/cerebro-prompt-restructure.md`) and add cases for the bug classes found on 2026-10-19.

## Problem (verified 2026-10-19)
- The harness `~/cerebro-fase1/pruebas/evals/evaluar.py` is not under version control (only manual
  `.bak` copies).
- Totals are noise: 9 of 60 cases flip between identical runs; totals 42-45 (commit bf49ff4).
  `evaluar.py` has no per-case repetition for single-turn cases (`--reps` is multi-turn only) and
  `comparar_informes.py` compares exactly two reports.
- No tokens are recorded per case; no run metadata (prompt hash, workflow version).
- All 60 cases carry a `[CONTEXTO DEL SISTEMA]` block frozen inside `entrada.mensaje`; the real
  Decisor is not exercised. 12 of 60 are always SKIPPED (need history, none injected). Tool results
  are recorded mocks (38 of 60 non-empty).

## Ownership
Owner decision 2026-10-19: the CRM session owns this measurement work; the prompt session must not
touch `~/cerebro-fase1/pruebas/evals/` until this document says done (engram #494).

## Scope
- E0 Version the harness in place (`git init` in `~/cerebro-fase1/pruebas/evals`, reports ignored).
- E1 Replicated measurement: `--reps N` for single-turn cases, tokens per case (same extraction as
  the token collector), a metadata file per run, and `agregar_informes.py`: per-case pass rate with
  a Wilson 95% interval, stable / unstable classification, and an A-vs-B comparison per case
  (Fisher exact test) instead of totals.
- E2 Baseline of the current production prompt with N repetitions, after the memory fix.
- E3 T9: regenerate the frozen `[CONTEXTO]` and recorded tool results (its own analysis first; the
  `doble-pregunta` caveat applies).
- E4 New cases for the 2026-10-19 bug classes that the model layer can see.
- Not in scope: changing the prompt, the Decisor, or any production workflow.

## Constraints
- The harness runs the REAL model (DeepSeek, production credential) through temporary n8n
  workflows: it costs tokens. Forecast before long runs.
- Never print or store API keys. The harness reads `~/.n8n-api-key` (exists, 0600, valid).
- Reports keep their current list format so `comparar_informes.py` keeps working.

## TDD
- Mode: strict, source user global CLAUDE.md.
- Runner: `python3 -m unittest discover -s tests` in `~/cerebro-fase1/pruebas/evals` (stdlib; no
  pytest installed). Pure functions (aggregation, statistics, token extraction) are unit-tested;
  the n8n round trip is checked by one real single-case run.

## Tasks
- [x] E0 — Harness under git, current state as the first commit.
- [x] E1 — Replication, tokens, metadata, aggregator (unit tests RED -> GREEN, one real run).
- [x] E2 — Replicated baseline of the production prompt (informe-20261019-181016).
- [ ] E3 — Fresh cases from current traffic: generator + sheet DONE; owner arbitration PENDING.
- [x] E4 — 2026-10-19 bug classes: DB layer covered by staging assertions (247-250); the real model turn (reg-475460) is in the arbitration sheet.

## Acceptance criteria
- A run with `--reps N` produces one row per case and repetition, with tokens when measured.
- `agregar_informes.py` prints, per case, k/n, rate, Wilson interval and a stability class, and for
  two sets of runs, the cases whose difference is significant.
- The baseline names its prompt hash, workflow version, battery hash, N and cost in tokens.

## Progress
- 2026-10-19: harness mapped (read-only). Key file facts above.

- 2026-10-19 E0: `git init` in `~/cerebro-fase1/pruebas/evals` (branch main, local only), first commit
  4cbab5a = the harness exactly as found; `informes/` and later `corpus/` ignored.
- 2026-10-19 E1 (commit f944735): `medicion.py` (pure: tokens per execution with the collector's
  reading, Wilson 95%, stability class, Fisher two-sided, per-case aggregation and A/B comparison),
  `agregar_informes.py` (N reports, old or new format), `evaluar.py --reps` for single-turn cases,
  tokens per row, `.meta.json` per run (prompt md5, workflow version, battery md5, model, harness
  commit). `correr_caso` keeps its signature (cotizar_arm.py, evaluar_cambio_servicio*.py). Unit tests
  RED (module missing) -> GREEN 14/14; the Fisher constant checked by brute force (p=0.02564). Real run:
  reg-32373 x2 VERDE, 20,821 prompt tokens per call, meta written. On the 2026-10-18 reports: 3 vs 3
  runs, 0 significant changes, 8 cases moved without support — the noise finding, now quantified.
- 2026-10-19 E3 analysis: the battery's frozen contexts no longer look like production. Line kinds in
  the last 500 real blocks vs the 60 cases: TASAS DE HOY 100% vs 23%; EL NEGOCIO ESTA ABIERTO 78% vs
  0%; VIA ACTUAL DE LA OPERACION 39% vs 0%; EL CLIENTE ABRE CONVERSACION 32% vs 0%; ESTE LOTE TRAE
  DATOS NUEVOS 14% vs 0%. The August cases cannot be regenerated faithfully (their Decisor inputs were
  not kept), so T9 becomes: harvest current turns and have the owner arbitrate them, as in August.
- 2026-10-19 FOUND: the nightly `cerebro-cosecha.timer` harvested 0 executions since 2026-09-06
  (cosechar.py pointed at the retired T3v07IQqtMs6AKJ4) and its hardcoded tool list missed 5 of 16.
  Fixed with tests (commit 53a215b, 18/18): production workflow, tool names from the live workflow;
  corpus untracked. Manual harvest started to save the ~4 days n8n still retains.
- 2026-10-19 E2 started: `evaluar.py --reps 5` on the production prompt, log
  `informes/linea-base-20261019.log`.

- 2026-10-19 harvest: 187 executions saved (2026-10-19 12:28-22:55; 115 agent turns with input and
  output; 0 errors). n8n keeps only ~10 h of Cerebro executions, so the daily timer lost most traffic
  even before it broke: `cerebro-cosecha.timer` now runs every 2 h (OnCalendar=*-*-* 00/2:15:00;
  previous unit file kept in the session scratchpad). Local config, not versioned.
- 2026-10-19 E3: `generar_casos.py --desde` (commit c550fa5, tests 24/24) writes dated files and
  refuses to overwrite (PARA-ARBITRAR-evals.md is the 12-Aug record). First sheet:
  `PARA-ARBITRAR-2026-10-19.md`, 60 candidates in 11 families incl. the new `recarga`; cases in
  `casos/casos-regresion-2026-10-19.json`. They carry today's real [CONTEXTO]. Contains real customer
  messages: local only.
- 2026-10-19 E4: Yoandy's only agent turn in the harvest (475460, "dos transferencias") is candidate
  reg-475460-beneficiario-zelle: the model followed the tool's handoff result correctly; the defect was
  in the DB layer, already covered by the 247-250 staging assertions. No invented expectations.

- 2026-10-19 E2 DONE: `informe-20261019-181016` (+ .meta.json). 48 runnable cases x 5 reps = 240 runs,
  0 execution errors. Prompt md5 e58316d2 (56,126 chars), workflow jEzlVLCLUaJhVwzs version ec50cade,
  battery md5 6bab9431, model deepseek-flash, harness c550fa5. Duration 77 min.
  Result: 40 stable green, 4 unstable, 4 stable red.
  Stable red (0/5): reg-27065 and reg-28021 multi-herramienta (call the forbidden calcular_envio),
  reg-32454 calculo-desde-contexto (missing 30000), reg-32635 (never calls registrar_beneficiario_zelle).
  Unstable: reg-32598-otros 1/5; reg-24612, reg-25682 servicios and reg-27129 beneficiario-zelle 4/5.
  Tokens: 7,981,974 in / 107,664 out; mean 33,258 input tokens per run (range ~21k-66k per case).
  Caveat: these cases still carry August contexts (see E3 analysis); stable reds may be stale
  expectations rather than model faults, to be checked against the arbitrated battery.

## Next step
Owner arbitration of PARA-ARBITRAR-2026-10-19.md. Then the owner arbitrates PARA-ARBITRAR-2026-10-19.md; arbitrated cases join the gold
battery and the replicated baseline is rerun on the new battery.
