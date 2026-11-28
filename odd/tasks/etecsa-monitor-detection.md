# ETECSA promo monitor detection

## Objective
The monitor (`Vigilante - promociones de Etecsa`, n8n `vk6aEa4bOZtl5xSz`) must detect
ETECSA recharge promotions again, so the CRM asks for confirmation and the bot can
quote them; and promo validity must follow the Guyana day.

## Problem / why (investigated 2026-09-25)
- The 2026-09-21..26 promo (x5, 600–1250 CUP) was never detected. "Buscar candidatos"
  keeps hrefs matching /promo/ AND /internacional|recarga/; ETECSA moved it to
  `/es/promocion/septiembre/quintuplica`. The parser reads that page correctly.
- The bot answered inconsistently: it said "no promo" (DB), except in chats where an
  operator had quoted the price, which it repeated from memory.
- `cerebro_promo_vigente()` / `cerebro_promo_proxima()` use `current_date` in the UTC DB:
  promos start and end at 20:00 Guyana, 4 h early.

## Scope (accepted by the user 2026-09-25)
1. Widen the candidate filter so any ETECSA promo link is read (the parser already
   rejects pages that are not a dated recharge promo).
2. Promo functions use the Guyana date.
Out of scope: an alert when nothing is detected for N days (user declined); duplicate
detections of one promo under several URLs.

## Constraints
- The monitor exists only in production (no staging copy). Test offline against saved
  real HTML; the user applies the workflow change during the Sunday 2026-09-27 cutover.
- Migration 122 keeps `cerebro_servicio_get` working unchanged (it calls both functions
  with no arguments).

## Tasks
- [x] T1 — Bench for "Buscar candidatos" + "Parsear promocion" over saved HTML (current
  home, September quintuplica page, an August-style home link). RED on the current code,
  then fix the filter, GREEN.
  - `~/cerebro-fase1/pruebas/banco-vigilante-etecsa.js` runs the REAL node code from the
    workflow JSON over `pruebas/fixtures-etecsa/` (real home + quintuplica + oferta_internacional
    + ilimitados pages of 2026-09-25; August-style home/page are synthetic wrappers around the
    real text stored in promo_etecsa, etecsa.cu refused connections when re-fetching).
  - RED on production code: 2/4 (reproduces the miss: only oferta_internacional was a
    candidate). Candidate `~/cerebro-fase1/candidato-workflow-vigilante-etecsa.json`: filter =
    any href with "promo" except static assets → GREEN 4/4, incl. "other candidate pages
    down". Only "Buscar candidatos" changes ("Leer la promocion" already had
    onError=continueRegularOutput). Rollback snapshot
    `~/cerebro-fase1/ROLLBACK-vigilante-etecsa-antes-filtro.json` (versionId fa987509…).
- [x] T2 — Migration 122: both promo functions take `p_hoy date DEFAULT Guyana today`
  (drop the zero-arg versions to avoid overload ambiguity). Assertions in a rolled-back
  transaction on staging (RED first), then apply to staging.
  - Only caller: cerebro_servicio_get (checked prod pg_proc, views, 28 active n8n workflows,
    app code). Grants kept as 064 (service_role only).
  - RED: function(date) missing. GREEN: ALL PASSED (08-13/08-16 inclusive, 08-17 out, detected
    ignored in confirmar mode, proxima dias_para, Guyana default, exactly 2 functions,
    cerebro_servicio_get quotes a promo valid on the Guyana day). ROLLBACK restores the
    zero-arg versions and cerebro_servicio_get still works. BEGIN/COMMIT removed from the
    files (repo convention; they would have committed inside the rolled-back test).
  - Applied to staging + registered (20260926022536). Commit `4722a31`, pushed.
- [x] T3 — Production candidate workflow + runbook (apply, verify, rollback) and add 122
  to the cutover series.
  - Runbook `~/cerebro-fase1/PASOS-vigilante-etecsa-deteccion.md`; verify script
    `~/cerebro-fase1/verificar-vigilante-etecsa.py` (today: only "Buscar candidatos" DIFFERS).
  - 2026-09-26 ~02:30 UTC, at the user's explicit request, applied in PRODUCTION:
    B = migration 122 via Supabase apply_migration (registered 20260926022942; functions show
    the Guyana default; cerebro_servicio_get('recargas') still answers; grants postgres +
    service_role). A = workflow put after confirming live == rollback snapshot (fa987509…) and
    bench 4/4; new versionId ca7d5557-3b45-477a-9a25-4f0a34869828, verify script RESULT: OK.

## Acceptance criteria
- With the September home page, the monitor finds and parses 600–1250 CUP, x5, 21–26 Sep.
- An August-style link (`/es/promo/internacional/...`) is still a candidate.
- A promo whose last day is D is still valid at 21:00 Guyana on D and not valid on D+1.

## Checks
TDD strict. Node bench (`~/cerebro-fase1/pruebas/banco-vigilante-etecsa.js`), SQL assertions
via the staging rollback script, `n8n.py` + verify script for production.

## Progress
- 2026-09-25: document created after investigation.
- 2026-09-25: T1–T3 done. Waiting for the user to apply in production.
- 2026-09-26: applied in production (A + B). Feature complete.
