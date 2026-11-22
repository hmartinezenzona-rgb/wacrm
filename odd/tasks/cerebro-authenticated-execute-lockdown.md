# cerebro-authenticated-execute-lockdown

**Objective**: restrict the four mutating bot functions to `service_role` (plus the external `remesas_handoff` role where it already has a grant), removing `authenticated` EXECUTE.

**Problem**: after 387 removed `anon`, any signed-in user could still call `cerebro_registrar_derivacion`, `cerebro_liberar_derivacion_ambigua`, `cerebro_auditoria_semantica_registrar` and `cerebro_telemetria_registrar` directly through PostgREST `/rpc`, polluting bot state and telemetry.

**Evidence that revoking `authenticated` is safe**
- No `.rpc` callers in `src/`, `pruebas/`, `infra/`.
- All SQL callers are `SECURITY DEFINER` owned by `postgres`; those wrappers are already ACL-restricted to `postgres` + `service_role`.
- No views, RLS policies or triggers reference the four.
- n8n reaches the bot through those wrappers, so it runs as `service_role`.

**Exception**: `remesas_handoff` (login role, BYPASSRLS, no repo reference, no active sessions) holds an explicit EXECUTE grant on `cerebro_registrar_derivacion` only. 388 does not touch it.

**Scope**
- In: migration 388 (`REVOKE EXECUTE ... FROM PUBLIC, authenticated` on the four), ROLLBACK re-granting `authenticated`, staging assertion.
- Out: `remesas_handoff` credential audit (separate follow-up); `peek_invitation`.

**Constraints**: staging first; production only with explicit go-ahead; one file per invocation.

**Checks**: assertion proves authenticated=false, service_role=true, anon=false, and (when the role exists) remesas_handoff keeps EXECUTE on `cerebro_registrar_derivacion` only. RED expected on staging.

## Tasks

- [x] T1 Write 388 + ROLLBACK + assertion; confirm RED, apply on staging, confirm ALL PASS.
  - RED: 4 cases failed (`authenticated can EXECUTE ...`); cases 4-5 skipped (staging has no remesas_handoff).
  - Staging cycle: dry-run/apply/assertion/rollback OK.
  - Staging post-apply: all four ACLs are `{postgres, service_role}` only.
- [ ] T2 Production apply after go-ahead; verify ACLs read-only.
  - Production pre-388: authenticated on all four; remesas_handoff on `cerebro_registrar_derivacion`.
