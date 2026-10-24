# Promotion guard: every DB dependency of the workflow exists in the target database

## Objective

Stop `infra/n8n/promover_cerebro.py` from promoting a Cerebro workflow that references a database function or table
missing in production. `--ensayo` and `--aplicar` check every DB identifier used by the workflow's Postgres node
queries against the target catalog and refuse with the missing list.

## Problem and why

2026-10-24 outage: the new production Cerebro (`01c7622d`) failed at "Contexto conversacion" because
`cerebro_catalogo_servicios()` (legacy migration 138) existed in staging but never in production. Ten of fourteen
executions failed and three conversations got no reply (Engram `bug/prod-outage-2026-10-24-catalogo-servicios`).
The owner asked for a guard in Engram as pending (`pending/promover-cerebro-dependency-guard`, #612).

## Scope

- Extract function and table references from the queries of `n8n-nodes-base.postgres*` nodes of the workflow being
  promoted (the built body, production values included).
- Check both against the target database (production by default) via the Supabase Management API, read-only.
- Offline catalog (`--catalogo` / `CEREBRO_CATALOGO`) for tests and dry runs without API access.
- Fail closed: if the catalog cannot be read, the promotion is refused.

Out of scope: executing workflows, validating SQL semantics, reading staging's catalog.

## Constraints

- Never execute the staging or production workflow.
- Never print the token, the workflow JSON or customer data.
- Read-only on the target DB. No migration is run by the guard.
- Extraction must not flag SQL keywords, CTE names, column aliases or n8n `{{ }}` expressions.

## Tasks

- [x] G1 `dependencias_bd(workflow)` — pure extraction (functions, tables) with tests for queries, CTEs, INSERT
  column lists, `EXTRACT(... FROM ...)`, aliases and `{{ }}` expressions (`DependenciasTest`).
- [x] G2 `catalogo_destino()` — Management API read (functions and relations), offline JSON file, fail closed;
  never prints the token (`CatalogoTest`).
- [x] G3 Wire the check into `--ensayo` and `--aplicar` before any write; refuse with the missing list
  (`CliTest`: PASS line, missing function, apply refused with no PUT, unreadable catalog).
- [x] G4 Run `--ensayo` against the live workflows: no dependency missing; suite green.

## Acceptance criteria

- A workflow referencing a function absent from the target catalog makes `--ensayo` return 1 and prints the missing
  function; `--aplicar` refuses before the backup and the PUT.
- The current production/staging Cerebro report zero missing dependencies.
- `python3 -m unittest discover -s infra/n8n/tests` is green.

## Checks

- TDD: enabled (user global CLAUDE.md). Runner: `python3 -m unittest discover -s infra/n8n/tests`.
- RED before implementation for G1-G3; GREEN after.
- G4: `python3 infra/n8n/promover_cerebro.py --ensayo` (read-only) and the full suite.

## Progress

- Task file created 2026-10-24. Extraction spike against the production backup: 84 functions, 20 tables, zero false
  positives and zero missing after masking literals, comments, `{{ }}` expressions, CTEs, aliases and
  `EXTRACT(... FROM ...)`.
- 2026-10-24 implemented with TDD: RED first (10 errors + 4 failures for the missing functions and CLI behaviour),
  GREEN with `Ran 58 tests ... OK`.
- Live `--ensayo` (read-only): `PASS: every DB dependency exists in the target DB (86 functions, 20 tables)`.
- Outage reproduction: `--ensayo --catalogo <production catalog without cerebro_catalogo_servicios>` exits 1 and
  prints `missing in the target DB: funcion cerebro_catalogo_servicios`.
- Fail closed: an unreadable catalog (missing file/token) is a FAIL, so `--aplicar` refuses before the backup and
  the PUT.
