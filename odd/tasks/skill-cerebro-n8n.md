# Skill: change the Cerebro in n8n safely

## Objective
A versioned tool + project skill to back up, inspect, compare, publish the Decisor to, and restore the Cerebro n8n
workflows (staging `U52y1kSNvhgxvWeb`, production `jEzlVLCLUaJhVwzs`), so a change never depends on scripts rewritten in
a per-session scratchpad. First feature where code is delegated to Hermes (owner decision 2026-10-21).

## Problem
- 2026-10-19/20: three Cerebro changes (S4b, S6, production S4b+S6) each needed a fresh script (deploy_s4b.py,
  deploy_s6.py, deploy_prod_s4b_s6.py) in the scratchpad: GET + backup, clone a tool node with the right credential,
  replace the Decisor, PUT, verify versionId == activeVersionId, node diff, Decisor md5 == repo file.
- Staging and production "Contexto conversacion" queries differ (staging has extra fields): a change made on staging
  cannot be copied blindly; the guard must be "expected current md5", not "equal to staging".
- Staging shares production's WhatsApp token: executing the staging workflow can message real customers.

## Scope
- `infra/n8n/cerebro_n8n.py` (stdlib only): `respaldo <staging|produccion>`, `estado <env>`, `comparar`,
  `publicar-decisor <env> --esperado <md5-prefix>`, `restaurar <env> <backup.json> --esperado <versionId-prefix>`.
  API key from `~/.n8n-api-key` (never printed); base URL https://automatizaciones-n8n.ttjgax.easypanel.host; backups
  in `~/cerebro-fase1/respaldos-n8n/` (outside the repo). PUT sends only name, nodes, connections, settings. Every write
  verifies after: versionId == activeVersionId, node set, Decisor md5 == repo file (`pruebas/decisor/decisor.jscode`).
- Tests `infra/n8n/tests/test_cerebro_n8n.py` (unittest) against a local stub HTTP server: refuses a wrong
  `--esperado`, never prints the key, backup written before any PUT, PUT payload limited to the allowed keys, verify
  fails when activeVersionId != versionId, restaurar refuses a backup of another workflow id.
- `infra/ia/delegar_hermes.py`: generic text-only delegation to Hermes (`hermes -z ... -t todo --in /tmp`): task file +
  context files -> answer with `FILE: <path>` + fenced blocks -> optional apply into a worktree. Refuses context files
  matching secret patterns (.env, *token*, *key*).
- Project skill `.claude/skills/wacrm-cerebro-n8n/` (+ references: ids, node names, tool-clone pattern, Decisor test
  harness + md5 pin, prompt deploy script location, gotchas); AGENTS.md line; global symlink.

## Constraints
- Never execute (run) the staging or production workflow. Production writes only with the owner's go-ahead.
- Hermes receives only code/specs; never the n8n key, workflow JSON with prompts, or customer data.

## TDD
Strict. Runner: `python3 -m unittest discover -s infra/n8n/tests` (+ a small test for delegar_hermes guards).

## Tasks
- [ ] N1 — `delegar_hermes.py` + guard test.
- [ ] N2 — tests for `cerebro_n8n.py` (RED), implementation by Hermes via delegar_hermes, GREEN (Claude finishes if
  Hermes fails twice).
- [ ] N3 — Skill + references + AGENTS.md + global symlink; read-only real runs: `estado staging`, `estado produccion`,
  `comparar`.

## Acceptance criteria
- `estado produccion` reports versionId == activeVersionId and the Decisor md5 vs the repo file; `comparar` lists the
  known Contexto conversacion difference; all guard tests pass.

## Progress
- 2026-10-21: owner chose this skill; Hermes to write code.
- 2026-10-21: N1 (35f8b69, 02cc7af), N2 (74c62f7) and N3 implemented; Hermes round 1: 200 s, 15/15 tests, then hardened by hand (21 tests). Real read-only runs done (estado x2, comparar, respaldo produccion).

## Next step
N1.
