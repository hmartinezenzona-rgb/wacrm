# cerebro-anon-execute-lockdown

**Objective**: remove `anon`'s EXECUTE on seven internal `SECURITY DEFINER` functions in `public` while preserving `authenticated` and `service_role`.

**Problem**: the functions kept PostgreSQL's default `EXECUTE` grant to `PUBLIC`, so anyone with the public anon key could call bot internals: `cerebro_registrar_derivacion`, `cerebro_liberar_derivacion_ambigua`, `cerebro_auditoria_semantica_registrar`, `cerebro_telemetria_registrar`, `cerebro_combo_en_curso`, `cerebro_tasa_usd_mxn`, `cerebro_tasa_usd_mxn_info`.

**Why now**: finding from the 2026-11-22 audit (High). `peek_invitation` is intentionally anonymous (migration 019, `/join/<token>` before sign-in) and stays untouched.

**Scope**
- In: migration 387 with `REVOKE ALL ... FROM PUBLIC, anon` plus explicit `GRANT EXECUTE ... TO authenticated, service_role` for the seven signatures; ROLLBACK; staging assertion.
- Out: restricting `authenticated` on the four mutating bot functions (follow-up after caller audit); `peek_invitation`.

**Constraints**: staging first; production only with explicit go-ahead; one file per production invocation; do not touch other-session files.

**Checks**: assertion proves anon=false, authenticated=true, service_role=true for the seven, and `peek_invitation` still anon-executable. RED before the migration on staging.

## Tasks

- [x] T1 Write 387 + ROLLBACK + assertion; confirm RED on staging, apply on staging, confirm ALL PASS.
  - RED: 7 cases failed (`anon can EXECUTE ...`).
  - Staging cycle: dry-run/apply/assertion/rollback OK.
  - Staging post-apply: `anon_can_execute=[]`, `peek_anon=true`; assertion cases 2-3 confirm authenticated and service_role keep EXECUTE.
- [x] T2 Production apply after go-ahead; verify with read-only SQL.
  - Production pre-387: anon can execute all 7; `peek_anon=true`.
  - Applied 2026-11-22 19:23Z: `OK 387_cerebro_anon_execute_lockdown 20261122192327`.
  - Production post-387: `anon_can_execute=[]`, `auth_missing=[]`, `svc_missing=[]`, `peek_anon=true`, ledger row present.
