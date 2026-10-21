---
name: wacrm-migraciones
description: "Trigger: migración, migration, aplicar migración, staging, producción base de datos, supabase migration. Run the WaCRM migration cycle: staging first, then production through the Management API."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when creating, testing, applying or verifying a Supabase migration (`supabase/migrations/NNN_*.sql`) on staging or production.

## Hard Rules

- Staging first, always. Never run SQL on production before `staging-migracion.sh aplicar` ends all OK.
- Ask the owner for an explicit go-ahead before EVERY production `aplicar`. Earlier approvals do not carry over.
- Run `previa` first; apply only on `VEREDICTO: SEGURO`, or after explaining each difference to the owner.
- Never apply `ROLLBACK-*.sql` to production unless the owner asks.
- Apply migrations before the app that needs them.
- Never print the token or put it in a command line; the file `~/.config/wacrm/supabase-token.env` must be mode 600.
- Never paste migration SQL into the conversation; pass file paths.
- Every migration ships `ROLLBACK-NNN-*.sql` and a self-reverting assertion in `supabase/staging/assertions/` ending `ALL PASS (rolled back on purpose)`.
- Read live bodies with `pg_get_functiondef` before redefining a function.

## Decision Gates

| Situation | Action |
|---|---|
| Migration already applied on staging | `relacionadas ... --ya-aplicada <ROLLBACK>` |
| `previa` prints `RECORDED` | Stop; it is already in production |
| `previa` prints `DIFFERENT` / `MISSING-IN-PROD` / `EXTRA-IN-PROD` | Show the diff file to the owner; no apply without an answer |
| API error on `aplicar` | Stop at that file; report message; do not retry blindly |
| `verificar` mismatch | Report the objects; do not roll back on your own |

## Execution Steps

1. Pick the next free number (see reference); write migration, ROLLBACK, assertion.
2. `infra/db/staging-migracion.sh aplicar <mig> <assertion> <rollback> fn1,fn2`.
3. `infra/db/staging-migracion.sh relacionadas <mig> <pattern>` for assertions touching the same functions.
4. `infra/db/produccion-migracion.sh previa <mig...>` (all pending files, in order).
5. Report to the owner; wait for the go-ahead.
6. `infra/db/produccion-migracion.sh aplicar <mig...>`.
7. `infra/db/produccion-migracion.sh verificar <mig...>`.

## Output Contract

Return per step: OK/FAIL line, `VEREDICTO`, `OK <name> <version>` lines, `VERIFICADO: n/n`, and log or diff paths on failure. Never include secrets.

## References

- `references/workflow.md` — full workflow, numbering, assertion pattern, related-base trick, production checks, token rotation.
