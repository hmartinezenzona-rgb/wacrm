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
- [ ] T2 Day collector: read-only turns of the last 24 h (local query or Hermes read tools).
- [ ] T3 Reviewer prompt/orchestrator: run the two skills, produce the report and the proposed diff.
- [ ] T4 Staging eval gate: apply candidate to staging, run the affected subset x5, compare per case.
- [ ] T5 Production apply + rollback watcher: backup, apply, verify, auto-revert on regression.
- [ ] T6 systemd timer and notification.
