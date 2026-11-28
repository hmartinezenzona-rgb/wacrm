---
name: wacrm-publicar-panel
description: "Trigger: publicar panel, desplegar panel, deploy panel, release WaCRM app, pasar a producción el panel. Build and publish the WaCRM production panel with publicar-panel.sh."
license: Apache-2.0
metadata:
  author: "hmartinezenzona-rgb"
  version: "1.0"
---

## Activation Contract

Load when the owner asks to publish, deploy or release the WaCRM panel (Next.js, pm2 `wacrm` on host `oracle`), or to roll it back.

## Hard Rules

- Ask the owner for an explicit go-ahead before EVERY `publicar`. Earlier approvals do not carry over.
- Apply DB migrations before the app. Never ship app code that needs a migration missing in production.
- Push release branches (`release/prod-<topic>`) to remote `privado` only, never `origin`.
- Never print, type or ask for secrets or passwords. The owner logs in himself.
- Build only in the `~/wacrm-worktrees/prod-build` worktree; never build or deploy on the VPS.

## Decision Gates

| Situation | Action |
|---|---|
| Branch head fully shippable (all its migrations in production) | Branch `release/prod-<topic>` from it |
| Head not shippable | Branch from the served sha (`servido`), cherry-pick only shippable commits |
| `package-lock.json` changed vs served | Run `npm ci` inside `node:20` before `compilar` |
| Post-deploy problem | `rollback-wacrm-produccion.sh` (restores `anterior`); never rebuild |
| Owner wants to see it first | `panel-local-staging.sh` (port 3100); the owner logs in |

## Execution Steps

1. `infra/deployment/publicar-panel.sh servido` returns the served sha.
2. `git diff --stat <served> HEAD -- src messages public package.json package-lock.json`; compare migration numbers with production.
3. In prod-build: `infra/deployment/publicar-panel.sh compilar` prints `sha` and `build_id`.
4. Report to the owner and wait for the go-ahead.
5. `infra/deployment/publicar-panel.sh publicar <sha>` prints the served BUILD_ID.

## Output Contract

Return: served BUILD_ID, new sha, rollback sha (previous `servido`), checks run (vitest, tsc, manifest) and any skipped. On failure return the script's log path and last lines.

## References

- `references/procedure.md` — full procedure, gotchas, rollback command.
