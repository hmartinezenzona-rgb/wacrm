# Skill: database migrations (staging cycle and production apply)

## Objective
Make the migration workflow repeatable and cheap: versioned scripts for the staging cycle (dry run, apply, assertion,
rollback proof, related assertions) and for production (pre-flight comparison, apply from the file, post-check against
staging), wrapped in a project skill. The SQL never has to be pasted into the conversation.

## Problem (2026-10-20/21)
- Staging helpers `apply.sh` / `related.sh` lived in a per-session scratchpad; every new agent re-read or patched them
  (related.sh needed a rollback-first base once the migration was applied).
- Production had no write credential: migrations were applied through the Supabase MCP by pasting the full SQL into
  the conversation (58 KB once, 175 KB through an agent), and the pre-flight comparison was re-derived by hand each time.
- Owner stored a Supabase Management API token at `~/.config/wacrm/supabase-token.env` (0600,
  `SUPABASE_ACCESS_TOKEN=`), verified 2026-10-21: it reaches project hqztotshnlzaiziwjyzh and runs SQL as `postgres`
  (`POST https://api.supabase.com/v1/projects/<ref>/database/query`, body `{"query": ...}`).

## Scope
- `infra/db/staging-migracion.sh` — `aplicar <mig> <assertion> <rollback> [funcs]` (the apply.sh flow) and
  `relacionadas <mig> <pattern> [skip]` (related.sh with the rollback-first base when already applied); staging via
  `docker run ... postgres:17` and `.env.staging`.
- `infra/db/produccion-migracion.sh` — `previa <mig...>`: objects each file creates/replaces/drops; staging pre-bundle
  state (rollback files in reverse inside a rolled-back transaction) vs production now (exact and whitespace-normalized
  md5 of functions, constraints, columns); production schema_migrations must not contain them; prints EQUAL /
  EQUAL-NORMALIZED / DIFFERENT / MISSING per object and a verdict. `aplicar <mig...>`: one file at a time through the
  Management API (the migration-recording endpoint if available, else /database/query + an explicit
  schema_migrations row), stopping at the first error. `verificar <mig...>`: final md5 of every function the files own
  vs staging. Never prints the token.
- Tests with fakes (no network, no docker) for the guards: missing token file, wrong file permissions, refusing an
  already-recorded migration, stopping at the first API error, a md5 mismatch reported as failure.
- Project skill `.claude/skills/wacrm-migraciones/SKILL.md` (+ references); register in AGENTS.md.

## Constraints
- Production apply only after the owner's explicit go-ahead and a `previa` verdict of safe; never apply ROLLBACK files
  to production unless the owner asks; staging first always.
- The token is a secret: read from the file, never echoed, never in commits or logs.

## TDD
Strict. Runner: `bash infra/db/tests/<test>.sh` (fake-based, like infra/deployment/tests).

## Tasks
- [x] M1 — staging-migracion.sh + tests.
- [x] M2 — produccion-migracion.sh (previa / aplicar / verificar) + tests.
- [x] M3 — Skill + references + AGENTS.md; read-only dry run of `previa` and `verificar` on 257 against production.

## Acceptance criteria
- `previa` on already-applied 253-257 reports them as recorded and refuses; `verificar` on them reports all md5 equal.
- The guards are proven by the fake tests; the skill fits the style-guide budget.

## Progress
- 2026-10-21: token stored and verified (runs as postgres).

- 2026-10-21 M1-M3 DONE: df36720 (staging-migracion.sh aplicar/relacionadas; no apply when the dry run fails; md5 before
  vs after the rollback proof), a4ae623 (produccion-migracion.sh previa/aplicar/verificar + lib-migracion.sh +
  migracion_sql.py + fake tests), 65bfd0e (skill .claude/skills/wacrm-migraciones + references/workflow.md; AGENTS.md).
  Tests RED -> GREEN "todo en pie" (parent re-ran); no token in the repo history. Read-only dry runs on production:
  `previa 257` -> RECORDED, refuses (exit 2); `verificar 253 255 257` -> VERIFICADO 16/16 iguales; previa on a renamed
  probe copy of 257 -> VEREDICTO REVISAR (15 diferencias) + diff file (comparison works). `aplicar` uses
  POST /v1/projects/{ref}/database/migrations {query,name} (route probed read-only: GET 200, POST {} -> 400); it checks
  the schema_migrations row after each file. NOT yet exercised for real: the first real production apply is its test —
  run `verificar` right after. `relacionadas` needs `--ya-aplicada <ROLLBACK>` once the migration is on staging.
  Skill linked globally: ~/.claude/skills/wacrm-migraciones -> the repo copy.

## Next step
Use it on the next migration (first real `aplicar` + `verificar`). Owner to rotate the Supabase token (it was pasted
in chat) and save the new one himself in ~/.config/wacrm/supabase-token.env (0600).
