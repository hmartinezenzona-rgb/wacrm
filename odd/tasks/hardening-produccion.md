# hardening-produccion

**Objective**: close the `public.messages` anonymous-insert hole and make production database backups automatic and verified.

**Problem**: production and staging still carry the permissive policy `Service role can insert messages` (INSERT, roles=PUBLIC, `WITH CHECK true`), and `anon` holds INSERT on `public.messages`. Anyone with the public anon key can inject rows into any known conversation. Separately, the newest production dump is from 2026-10-15 because `respaldar-base.sh` is manual.

**Why now**: these are the two audit findings with direct data-integrity impact (2026-11-22 five-front audit).

**Scope**
- In: migration 386 (policy + anon grants), staging assertion, rollback; daily backup wrapper with retention and verification; systemd user timer.
- Out: offsite copy (needs an explicit decision and remote authorization); revoking anon SELECT (RLS already scopes it).

**Constraints**
- Migrations: staging first, production only after the owner's explicit go-ahead, one file per invocation.
- Never edit an applied migration; 017 keeps its history.
- Do not touch the four uncommitted files left by another session.

**Checks**
- SQL: assertion `messages-insert-lockdown.sql` ends `ALL PASS (rolled back on purpose)`.
- Shell: `bash infra/db/tests/probar_respaldo.sh` green (retention + sibling deletion).
- Manual: one real production dump produced, sha256 verified, timer listed.

**TDD**: enabled (global). Runner: SQL assertion via `staging-migracion.sh`; shell guard test via `bash`.

## Tasks

- [x] T1 Migration 386 written (migration + ROLLBACK + assertion). Staging: RED confirmed before the migration (cases 1-3 failed), then `aplicar` ended dry-run/apply/assertion/rollback OK. Post-apply staging: `policy=0`, `anon_insert=false`, `anon_update=false`, `auth_insert=true`. Production pending the owner's go-ahead.
- [x] T2 Daily backup: `infra/db/respaldo-diario.sh` (dump + sha256 verify + retention), systemd service/timer in `infra/deployment/systemd/`, installed and enabled for user `onlinefreedom` (`Linger=yes`). Guard test `infra/db/tests/probar_respaldo.sh` ALL PASS.
- [ ] T3 Evidence: production backup verified 2026-11-22T19:07Z (134 data tables, 548 functions, sha256 `e7899d7f…`, 44 s); retention pruned 24 dumps older than 30 days. Timer next run 2026-11-23 03:17 CST. Pending: production apply of 386 and its evidence.

**Production precheck**: `produccion-migracion.sh previa` refuses policy/ACL-only migrations ("no encontre ninguna funcion, tabla ni vista"). Equivalent read-only check on production: `policy=1`, `anon_insert=true`, `anon_update=true`, `auth_insert=true` — exactly the staging pre-state. Staging post-apply is the target state.

**Delivery**: small change (<400 authored lines), single work-unit commit on `feat/port-chat-operations-calculator`; no push, no merge.
