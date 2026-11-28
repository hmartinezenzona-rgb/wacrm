# WaCRM migration workflow

Staging = Supabase project `kolppplawzdsjfydwejr`, reached through `docker run ... postgres:17` with `.env.staging`
(`CRM_STAGING_DATABASE_URL`). Production = project `hqztotshnlzaiziwjyzh`, reached through the Management API with the
token in `~/.config/wacrm/supabase-token.env`. Scripts live in `infra/db/`; guard tests:
`bash infra/db/tests/probar_migraciones.sh` (fakes for docker and curl, no network).

## Files and numbering

- `supabase/migrations/NNN_short_name.sql` (no BEGIN/COMMIT; the header comment says what it does and how it is guarded).
- `supabase/migrations/ROLLBACK-NNN-short-name.sql` (restores the previous bodies, signatures and ACLs; no BEGIN/COMMIT).
- `supabase/staging/assertions/<name>.sql`, self-reverting.
- Next free number = highest of: this branch, every other branch/worktree, and production's `schema_migrations` names.
  Other sessions reserve numbers on their own branches, so check before writing:
  `git for-each-ref --format='%(refname)' refs/heads | while read r; do git ls-tree --name-only "$r" supabase/migrations/; done | grep -oE '[0-9]{3}_' | sort -u | tail -5`
- The production record name is the file name without `.sql` (`257_cup_source_card`); the version is a timestamp the API assigns.
- `previa` finds the rollback of `NNN_x.sql` as `ROLLBACK-NNN-*.sql` in the same folder (exactly one).

## Assertion pattern

Start with `\set ON_ERROR_STOP on`; build its own fixtures with `pg_temp` helpers; count failed expectations; finish with
`RAISE EXCEPTION 'ALL PASS (rolled back on purpose)'` (or fail with the number of failed expectations). Header comment
lists the cases and the order to load prerequisites. The staging script strips `\set`, `BEGIN;`, `ROLLBACK;`, `COMMIT;`
lines and wraps the file itself, so the same file also runs by hand.

## Staging cycle

`staging-migracion.sh aplicar <mig> <assertion> <rollback> [fn1,fn2]` prints one line per step:

1. `dry-run`: BEGIN; migration; assertion; ROLLBACK. Must end in `ALL PASS`. If it fails, nothing is applied.
2. `apply`: BEGIN; migration; COMMIT.
3. `assertion`: rerun on the applied state.
4. `rollback`: the ROLLBACK file in a rolled-back transaction; with function names, the md5 must equal the pre-migration md5.

Full output goes to a log (path printed on failure). `DRY_ONLY=1` stops after step 1. A migration that drops old overloads
is not re-runnable on staging once applied: the dry run fails ("function ... does not exist"); use the ROLLBACK first
or skip to `relacionadas`.

### The related-base trick

`staging-migracion.sh relacionadas <mig> <grep-pattern> [skip] [--ya-aplicada <ROLLBACK>]` runs every assertion matching
the pattern twice (base vs with the migration), sequentially (parallel runs deadlocked once), comparing the first ERROR
line with uuids normalized: `SAME|DIFF | name | base error | mig error` and totals. A DIFF is a regression only if the
base was clean; pre-existing errors are SAME. When the migration is already applied on staging, pass
`--ya-aplicada <ROLLBACK>`: both runs start with that rollback inside the transaction, so the base is the real
previous state. Without the flag on an applied migration, base and mig runs are identical and the result means nothing.

## Production

- `previa <mig...>`: read-only. Refuses (`RECORDED`, exit 2) if any name is in `supabase_migrations.schema_migrations`.
  Rebuilds staging's pre-bundle state (ROLLBACK files in reverse order, one rolled-back transaction) and compares
  functions (identity args), and for touched tables columns, constraints, triggers and indexes against production.
  Labels: `EQUAL`, `EQUAL-NORMALIZED` (whitespace only, accepted), `DIFFERENT` (bodies written to the diff file),
  `MISSING-IN-PROD`, `EXTRA-IN-PROD`, `NEW` (new function, informational). Verdict `SEGURO` or `REVISAR (n diferencias)`.
  Pass every pending file, in order; production must equal the staging state from before the whole bundle.
- `aplicar <mig...>`: `POST /v1/projects/<ref>/database/migrations` with `{"query": <file>, "name": <name>}` (the
  Management API's migration endpoint, which records the row in `schema_migrations`; its route was probed read-only on
  2026-10-21, the first real write is the first real apply). One file at a time, in order,
  stopping at the first non-2xx with the API message; afterwards the row is looked up and `OK <name> <version>` printed.
  If the row is missing it reports FAIL. Never retry blindly: a half-applied file is possible only if the API did not
  wrap it in a transaction, so inspect production first.
- `verificar <mig...>`: for every function the files create (owner = last file creating it; a final DROP excludes it)
  compares md5 of `pg_get_functiondef` production vs staging, per overload. `VERIFICADO: n/n iguales` or `NO VERIFICADO`
  with exit 1.

## Token

Management API token (not a DB password). Stored at `~/.config/wacrm/supabase-token.env`, mode 600, single line
`SUPABASE_ACCESS_TOKEN=...`; scripts refuse any other mode. curl reads the header from a generated config on a file
descriptor, so the token is never in argv, logs or output. To rotate: create a new token in the Supabase dashboard
(Account > Access Tokens), write it with `install -m 600 /dev/null <file>` then the line, check
`stat -c %a <file>` is 600, run `produccion-migracion.sh verificar` on any applied migration, then revoke the old one.
Never commit it or paste it in a conversation.
