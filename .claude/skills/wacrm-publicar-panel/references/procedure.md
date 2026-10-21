# Publishing the WaCRM production panel

Production = Next.js app served by pm2 `wacrm` on ssh alias `oracle`, domain wacrm.onlinefreedom.site.
Releases live in `/home/ubuntu/wacrm-releases` (`current` and `anterior` symlinks).
Verified four times on 2026-10-20/21.

## Commands

All in `infra/deployment/`: `publicar-panel.sh compilar [--sin-pruebas] | publicar <sha> | servido`,
`panel-local-staging.sh [port]`, `rollback-wacrm-produccion.sh [sha]`.
Guard tests: `bash infra/deployment/tests/probar_publicar_panel.sh` and `probar_despliegue_de_produccion.sh`.

## 1. Release branch

- If the branch head is fully shippable (its DB migrations are all in production), branch from it.
- Otherwise branch from the served commit (`publicar-panel.sh servido`) and cherry-pick only the commits to ship.
- Check what would ship: `git diff --stat <served> <candidate> -- src messages public package.json package-lock.json`.
  Any app change needing a migration absent from production must NOT ship. Compare migration numbers with
  production's `supabase_migrations.schema_migrations`.
- Name it `release/prod-<topic>`; push to remote `privado` (never `origin`).

## 2. Checks (inside `~/wacrm-worktrees/prod-build`)

`compilar` runs them: remove `.next/types` (stale generated types from another branch break tsc),
`npx vitest run`, `npx tsc --noEmit`. node_modules is reused; if `package-lock.json` changed, run `npm ci`
inside the `node:20` container first.

## 3. Build

Host node is 26 but `build-wacrm.sh` needs node 20, so `compilar` runs it in `docker run node:20` and
mounts the common git dir (`git rev-parse --git-common-dir`) because a worktree's `.git` is a file.
The production build env `infra/deployment/wacrm.produccion.build.env` is gitignored: copy it (0600) from the
mejora-legacy worktree if missing. Output: `dist/wacrm-<sha>.{tar.gz,sha256,manifest.json,buildid}`; log in
`dist/build-<sha>.log`.

## 4. Manifest check

`environment == production` and `supabase_project_ref == hqztotshnlzaiziwjyzh`. `compilar`, `publicar` and
`desplegar` all refuse otherwise.

## 5. Publish (owner go-ahead required)

`publicar-panel.sh publicar <sha>` runs `desplegar-wacrm-produccion.sh <sha>` and prints the served BUILD_ID.
It keeps `anterior` for rollback.

## 6. Order with the database

Migrations first, then the app (new routes may need them). The old app keeps working after additive migrations.

## Rollback

`./infra/deployment/rollback-wacrm-produccion.sh` (to `anterior`) or `... <sha>` (to a specific release).
It only moves the symlink and restarts pm2; it never rebuilds and never deletes the bad release.

## Local check against staging

`panel-local-staging.sh 3100` (needs `~/.config/wacrm/staging-build.env`). The owner logs in himself; never
type or ask for passwords. `/api/promotions/etecsa` returns 500 locally (no service key): expected.

## Gotchas

- ssh prints post-quantum warnings starting with `**` on stderr; the scripts filter them.
- `$?` after a pipe is the last command's status; use `PIPESTATUS`.
- Deploy refuses an existing release dir (`ya existe`): use a new sha or remove the stale dir deliberately.
- A stale browser tab shows raw i18n keys after a deploy: hard-reload (Ctrl+Shift+R).
