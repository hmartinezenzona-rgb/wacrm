# Cerebro measurement: workflow reference

H = `/home/onlinefreedom/cerebro-fase1/pruebas/evals` (its own local git repo, branch main, no remote, commit
history from 4cbab5a). Tests: `python3 -m unittest discover -s tests` (38 passing on 2026-10-21).
Design record: `odd/tasks/cerebro-measurement.md` in the WaCRM repo.

## File roles

| File | Role |
|---|---|
| `cosechar.py [--desde ID]` | Read-only harvest of production Cerebro executions into `corpus/ejecuciones.jsonl` (ignored). Timer `cerebro-cosecha.timer` (every 2 h) runs `cerebro-cosecha.service`, log in `corpus/cosecha.log`. |
| `generar_casos.py --desde AAAA-MM-DD [--hoy]` | Pre-annotated candidates from the corpus: `casos/casos-regresion-DATE.json` + `PARA-ARBITRAR-DATE.md`. Refuses to overwrite. |
| `ascender_arbitraje.py candidatos veredictos --quien X [--solo-nuevos F]` | Joins verdicts (`oro`, `corregido`, `pendiente`) into `casos/casos-conversaciones.json` (gold). Refuses a candidate without verdict or already in gold. `--solo-nuevos` writes only the promoted cases, exclusive create. |
| `evaluar.py` | Runs cases against the real model: downloads the production workflow, builds a temporary n8n workflow per case with mocked tools, scores deterministically, deletes the temporary workflow. Flags: `--casos`, `--solo ID`, `--reps N`, `--prompt FILE` (candidate prompt, production untouched), `--workflow ID`, `--exportar-contrato`. |
| `medicion.py` | Pure functions: token reading, Wilson 95%, class, Fisher two-sided, aggregation, A/B comparison. |
| `agregar_informes.py` | Joins N reports, or `--a`/`--b` sets. `--json F` writes the aggregate. |
| `comparar_informes.py A B` | Legacy two-report flip list. Takes exactly two positional paths; use `agregar_informes.py` instead. |
| `desplegar_prompt.py` | Writes a prompt to production (backup first). Out of scope for this skill. |

## Battery sizes (2026-10-21)

- Gold `casos/casos-conversaciones.json`: 117 cases. 15 carry `historial_requerido` without history, so they
  SKIP. Runnable: 102.
- Regression sheet 2026-10-19 `casos/casos-regresion-2026-10-19.json`: 60 candidates, all arbitrated and promoted.
- To run a subset, write a JSON `{"casos": [...]}` with the selected gold cases into `corpus/` (ignored) and pass it
  with `--casos`. `ascender_arbitraje.py --solo-nuevos` already produces such a file for the promoted cases.

## Cost forecast

Measured: about 30-33k input tokens per run (range 21k-66k per case), about 18-19 s per run.

- Runs = runnable cases x reps. Input tokens ~ runs x 31k. Minutes ~ runs x 0.3.
- Baseline E2: 48 x 5 = 240 runs, 7,981,974 in, 107,664 out, 77 min.
- Baseline E5: 57 x 5 = 285 runs, 8,807,438 in, 176,654 out, 86 min.
- Full gold today: 102 x 5 = 510 runs, about 16M in, about 2.6 h.
- Single case x5: about 0.15M in, 2 min.

## Reports and meta

- `informes/informe-AAAAMMDD-HHMMSS.json`: list of rows `{id, familia, rep, resultado, fallos, avisos, herramientas,
  respuesta, tokens}`. `resultado` is `VERDE`, `ROJO`, `SALTADO`, or `ERROR`.
- `informes/informe-AAAAMMDD-HHMMSS.meta.json` (beside it, not inside): `inicio`, `fin`, `reps`, `solo`, `casos` and
  `casos_md5`, `prompt` (`produccion` or the file path), `prompt_md5`, `prompt_chars`, `modelo`, `contrato`
  (workflow id, version id), `harness_commit` (`+cambios` when dirty).
- Name the baseline by the run stamp and record it in the measurement doc with: prompt md5, workflow version, battery
  md5, N and tokens.
- Redirect the console log to `informes/*.log` (ignored).

## Reading agregar_informes output

- Per case: `k/n [low-high] class id ~tokens`, then `fallo mas comun (Nx): ...` for non-stable cases.
- Summary: `clases: {estable_verde, estable_rojo, inestable}`, `saltados`, `errores de ejecucion`, token totals and mean.
- A/B: `== A vs B: N cambios significativos (Fisher dos colas, alfa 0.05)`, then the significant changes, then the count
  of moves the data does not support. Only cases present in both sets are compared. Disjoint sets (E2 vs E5) compare
  nothing.
- Interval with 5 runs: 5/5 gives [0.57, 1.00]; 0/5 gives [0.00, 0.43]. A change of 1-2 out of 5 is not evidence.

## Lessons (verified)

1. Totals are noise: identical prompts gave totals 42-45 on 2026-10-18.
2. Frozen `[CONTEXTO]` blocks drift. On 2026-10-19 the August battery no longer resembled production (TASAS DE HOY
   100% vs 23%, EL NEGOCIO ESTA ABIERTO 78% vs 0%). August Decisor inputs were not kept, so cases are regenerated from
   current traffic and arbitrated by the owner, not rebuilt.
3. The harvest broke silently: `cosechar.py` pointed at a retired workflow from 6 Sep to 19 Oct, and its tool list
   missed 5 of 16 tools. Check that `WORKFLOW` and `HERRAMIENTAS` in `cosechar.py` match production when the corpus
   looks stale (`corpus/cosecha.log`).
4. n8n keeps about 10 h of Cerebro executions. The harvest must run every 2 h or the traffic is lost.
5. Pre-annotation copies production behaviour. The 2026-10-19 reds about "did not call the registration tool" were
   redundant: the system had already saved the data (`remittance_beneficiaries` source `notes_parse` / `reparto_auto`).
   E6 changed the expectations: registration tools became permitted, and the saved datum must appear in the answer.
   Check the production answer before calling a red a fault.
6. Tool-less turns were mislabelled as `calculo-desde-contexto`. Families now follow what happened:
   `datos-ya-guardados`, `calculo-desde-contexto`, `numeros-sin-herramienta`.
7. History-dependent cases (477891, 474015, 474079 and 12 others in gold) must be marked and skipped until history is
   rebuilt from `cerebro_memoria`; running them produces reds that do not measure the model.
8. Staging is not production: the staging Cerebro prompt (22df00c2, 51,622 chars) differs from production
   (c509c572, 56,545 chars). Owner replays on staging do not measure production until the prompts match.
9. Remaining real faults at E6: 478178 answers a pure "Ok" despite a Decisor SKIP note (1/5, reproducible); 474455
   does not take "Luis Proenza" as the Zelle holder (2/5); 475982 asks CUP or GYD for "cinco mil pesos" (1/5, possibly the
   prompt's ambiguity rule, owner to decide).

## Rescoring without tokens

`evaluar.py` exposes `puntuar(caso, salida, llamadas)` as a pure function. Stored `respuesta` and `herramientas` can be
rescored against edited expectations at no model cost. There is no committed script for this; write one under `corpus/`.

## Customer-data caution (open)

The local repo tracks files with real customer messages: `PARA-ARBITRAR-2026-10-19.md`, `PARA-ARBITRAR-evals.md`,
`casos/casos-regresion-2026-10-19.json`, `casos/casos-conversaciones.json`, `casos/casos-regresion.json`,
`casos/veredictos-2026-10-19.json`. `.gitignore` covers only `informes/`, `corpus/`, `__pycache__/` and `*.pyc`. No
remote is configured. Do not add a remote or push until the owner decides whether to untrack these files.
