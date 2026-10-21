# Skill: publish the WaCRM panel

## Objective
Turn the production panel release procedure (done 4 times on 2026-10-20/21) into a project skill plus versioned
scripts, so a session publishes by running two commands and reading a short result instead of re-deriving the steps.

## Problem
- The procedure lives only in engram notes and in the session: release branch from the served commit + cherry-picks,
  vitest + tsc, stale `.next/types` breaking tsc, host node 26 vs required node 20 (docker), the worktree `.git` file
  needing the common git dir mounted, the gitignored production build env, manifest check, deploy script, rollback.
- Helper scripts (local panel against staging) lived in a per-session scratchpad and were lost between sessions.

## Scope
- `infra/deployment/publicar-panel.sh` with subcommands `compilar` (checks + docker node:20 build + manifest check;
  prints sha and BUILD_ID) and `publicar <sha>` (runs `desplegar-wacrm-produccion.sh`). Guard tests in
  `infra/deployment/tests/` with fakes (no docker, no network).
- `infra/deployment/panel-local-staging.sh`: runs this checkout's panel on localhost:3100 against staging Supabase using
  `~/.config/wacrm/staging-build.env` (public values only).
- Project skill `.claude/skills/wacrm-publicar-panel/SKILL.md` (+ `references/procedure.md` with the release-branch
  decision and gotchas); registered in AGENTS.md.
- Out of scope: staging remote deploy script (not repeated recently), DB migrations (separate skill later).

## Constraints
- Scripts never print secrets; production publish still needs the owner's explicit go-ahead each time (the skill says so).
- Existing deploy scripts unchanged except where a test proves a need.

## TDD
Strict. Runner: `bash infra/deployment/tests/<test>.sh` (existing fake-based harness pattern).

## Tasks
- [x] P1 — `publicar-panel.sh` + guard tests (RED -> GREEN).
- [x] P2 — `panel-local-staging.sh`.
- [x] P3 — Skill + reference + AGENTS.md registration; dry run of `compilar` on the current release branch.

## Acceptance criteria
- `publicar-panel.sh compilar` refuses a dirty tree, a non-production manifest, or a missing build env, and on success
  prints the sha and BUILD_ID; `publicar` refuses an unknown artifact.
- The skill body is within the style guide budget and tells the model when to ask the owner.

## Progress
- 2026-10-21: owner chose this skill first among the repetitive-workflow skills.

- 2026-10-21 P1-P3 DONE: 2cd59e6 (publicar-panel.sh compilar/publicar/servido + tests), 713dc8b (panel-local-staging.sh),
  938cbeb (skill .claude/skills/wacrm-publicar-panel + references/procedure.md; AGENTS.md "## Skills"). RED 20 failures
  -> GREEN "todo en pie"; existing probar_despliegue_de_produccion.sh still "todo en pie" (parent re-ran both).
  `servido` read-only dry run printed 9367f0f (what production serves). compilar/publicar only covered by fake tests.
  Note: the scripts locate the repo from their own path, so a release branch must contain them (any branch cut from
  the feature branch from now on does).

## Next step
Use the skill on the next panel release; then the next skill (production migrations, needs a write credential decision).
