---
name: wacrm-medir-bot
description: "Trigger: medir el bot, evals, batería, línea base, comparar prompt, arbitrar casos, cosecha. Replicated per-case measurement of the Cerebro bot."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when measuring the Cerebro agent with the eval battery at `/home/onlinefreedom/cerebro-fase1/pruebas/evals` (H): baselines, prompt or Decisor comparisons, harvesting, arbitration.

## Hard Rules

- Never judge a change by totals. Compare per case: `agregar_informes.py --a ... --b ...` (Fisher).
- Replicate: `python3 -u evaluar.py --reps 5`. A single run is noise (9 of 60 cases flipped between identical runs).
- State the forecast first (~31k input tokens, ~18 s per run); get the owner's go-ahead before launching.
- Customer data stays local: sheets, `casos/*.json`, `informes/`, `corpus/`. Never send them to another model, never push H.
- Never overwrite an arbitrated sheet (`generar_casos.py` writes dated files only).
- A stable red is not a model fault until the production answer is checked (stale expectation or missing history).
- `ascender_arbitraje.py` writes the gold file in place: one verdict per candidate first.
- Do not deploy prompts from here (`desplegar_prompt.py` touches production): use `wacrm-cerebro-n8n`.

## Decision Gates

| Situation | Action |
|---|---|
| New prompt or Decisor change | Subset of affected cases x5 with `--prompt`, then compare with the baseline |
| Case needs earlier history | Set `entrada.historial_requerido: true`; the runner skips it |
| Fresh production traffic | Harvest, `generar_casos.py --desde`, give the owner the dated sheet |
| Owner answered a sheet | Write the veredictos file, then `ascender_arbitraje.py` |
| Stable red | Check the production answer first (reference, lessons) |

## Execution Steps

Run from H with `python3 -u`.

1. Harvest: `python3 cosechar.py` (the timer runs it every 2 h).
2. Candidates: `python3 generar_casos.py --desde AAAA-MM-DD`.
3. Owner arbitrates `PARA-ARBITRAR-AAAA-MM-DD.md`; save `casos/veredictos-AAAA-MM-DD.json`.
4. Promote: `python3 ascender_arbitraje.py casos/casos-regresion-DATE.json casos/veredictos-DATE.json --quien "NAME DATE"`.
5. Run: `python3 -u evaluar.py --casos SUBSET.json --reps 5 [--prompt FILE] > informes/NAME.log 2>&1`.
6. Compare: `python3 agregar_informes.py --a informes/A*.json --b informes/B*.json`.
7. Harness tests: `python3 -m unittest discover -s tests`.

## Output Contract

Per case: `k/n`, Wilson 95%, class. Then: significant A/B changes, unexplained moves, tokens (total and mean per run), skipped cases, errors, report and meta paths. Never quote customer text.

## References

- `references/medicion.md`: file roles, report naming, reading the aggregate output, baselines, lessons.
