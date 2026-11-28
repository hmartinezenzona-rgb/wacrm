# mejora-nocturna-cerebro

**Objective**: run a nightly, local review of the Cerebro bot, diagnose bad answers, propose a prompt change, validate it on staging with the eval battery, and auto-apply only low-risk changes to production. Everything else is reported for the owner.

**Why**: the owner wants continuous improvement without waiting for a manual session, but the bot handles money. Autonomy must be bounded by a deterministic risk classifier and an evaluation gate.

**Constraints**
- Customer data stays local (wacrm-medir-bot rule). The reviewer runs on this machine, not on the Hermes VPS, unless the owner explicitly relaxes the rule.
- Measurement rules keep their force: per-case comparison, replication (`--reps 5` for the gate), never judge by totals, never deploy from the harness.
- High-risk changes always need the owner's explicit go-ahead. Production write path stays `cerebro_n8n.py` / `desplegar_prompt.py` with backup and `--esperado`.
- Every applied change is reversible: backup before apply, auto-rollback if the next review shows a regression.

**Low-risk definition (auto-appliable)**
- Only the prompt text changes (not the Decisor, not code, not tool schemas).
- The changed lines touch none of: prices/rates/amounts/payment/deposit/saldo/recarga, handoff/human/assign/close/cancel/complete/verify/confirm, tool names or functions, security/identity/admin/permissions, arithmetic/formulas.
- The eval gate on the affected cases shows no regression and no unexplained movement.
- Anything else is reported, never auto-applied.

**Nightly flow**
```
00:15 local timer
  collect the last 24 h (local, read-only)
  review with revisar-agente-whatsapp + prompt-crafter-pro
  classify the proposed diff (infra/ia/clasificar_riesgo.py)
  write odd/reports/mejora-nocturna-YYYY-MM-DD.md + patch
  if low risk:
    apply to staging (backup), run eval subset x5, compare per case
    if green: apply to production (backup), notify the owner
    else: report only
  else: report only
```

**TDD**: enabled. Runner: `python3 -m unittest` for infra scripts; staging assertion for DB changes.

## Tasks

- [x] T1 Risk classifier: deterministic rules over a prompt diff, with tests.
  - `infra/ia/clasificar_riesgo.py` + `infra/ia/tests/test_clasificar_riesgo.py`, 7/7 green.
  - Low only when the changed prompt lines touch no protected group; decisor/code always high.
  - Note: over-blocking is intentional (falls back to the owner); tune after real reports.
- [x] T2 Day collector: read-only turns of the last 24 h (local query or Hermes read tools).
  - `infra/ia/colectar_dia.py` + `infra/ia/tests/test_colectar_dia.py`, 3/3 green.
  - SQL runs inside `BEGIN READ ONLY ... ROLLBACK`; output is a 0600 JSON under `~/cerebro-fase1/mejora-nocturna/dias/`; never prints customer text.
  - Real run 2026-11-23: 28 conversations, 24 operations, 8 tools, 5 without reply, 3 paused, 0 assigned.
- [x] T3 Reviewer prompt/orchestrator: run the two skills, produce the report and the proposed diff.
  - `infra/ia/mejora_nocturna.py` + `infra/ia/tests/test_mejora_nocturna.py`, 3/3 green.
  - Sends the two skills, the current prompt and a compacted day digest to `hermes -z`; requires one JSON block; runs `clasificar_riesgo.py` on V1/V2; writes a 0600 report and, only when low-risk, a candidate file. Nothing is applied here.
  - Dry build with the real day (28 conversations) and the refreshed production prompt (27,574 chars): 86,853 chars, under the 120k budget.
  - The wrapper must refresh the contract first: `cd ~/cerebro-fase1/pruebas/evals && python3 evaluar.py --exportar-contrato` (read-only).
  - **V1 is now a list of exact patches** (`{buscar, reemplazar}`), applied locally with a one-occurrence check and a length guard (max(200 chars, 10%)). V2 is a full rewrite for human review and is never auto-chosen. Full rewrites and invalid patches are high-risk.
  - Real run 2026-11-23: 20 conversations reviewed; one finding (duplicate consecutive messages after a receipt verification); V1 empty, V2 high-risk; no candidate, nothing applied. The raw Hermes answer is saved as `respuesta-*.txt` (0600) for audit.
  - **Corrección 2026-11-23**: el backend por defecto es `crm`, no el CLI local. El revisor hace POST a `/api/internal/hermes/review` (ruta interna del CRM) con `x-cerebro-secret`; la ruta añade `HERMES_API_KEY` del servidor y llama al Hermes del CRM. `--backend cli` queda solo para pruebas locales. La ruta está implementada (`src/app/api/internal/hermes/review/route.ts`) con 6 tests; **falta publicar el panel** para que exista en producción.
- [x] T4 Staging eval gate: apply candidate to staging, run the affected subset x5, compare per case.
  - `infra/ia/aplicar_candidato.py` + tests.
  - Refuses any risk other than `bajo`; runs only the **affected-family subset** with `evaluar.py --reps 5 --casos <subconjunto>`; requires exit 0 (all green) before anything else.
  - The reviewer asks Hermes for `familias_afectadas`, validates the names against `casos/casos-conversaciones.json`, and writes `subconjunto-*.json` (0600). If no valid family is named, no candidate is produced (report-only).
  - Time: full battery 117 cases x5 = 585 runs ~2h55m; a 3-family subset (24 cases) = 120 runs ~36m (−79%); one family (11 cases) = 55 runs ~16m (−90%). Tokens drop proportionally.
- [x] T5 Production apply + rollback record.
  - With `--aplicar`, after a green battery it runs `desplegar_prompt.py --candidato <file> --etiqueta nocturna-YYYYMMDD`, requires `COINCIDE`, and records the rollback path (`~/cerebro-fase1/ROLLBACK-v2-antes-<tag>.json`) in `~/cerebro-fase1/mejora-nocturna/estado.json`.
  - Manual rollback (auto watcher pending): `python3 infra/n8n/cerebro_n8n.py estado produccion`, then `python3 infra/n8n/cerebro_n8n.py restaurar produccion <rollback> --esperado <versionId prefix>`.
- [x] T6 systemd timer and notification.
  - `infra/ia/mejora_nocturna.sh` runs router check/start, collect, contract refresh, review, and apply-if-low.
  - `wacrm-mejora-nocturna.{service,timer}` installed; the timer is **disabled** until the panel with `/api/internal/hermes/review` is published. Re-enable with `systemctl --user enable --now wacrm-mejora-nocturna.timer`.
