# Port the other session's Zelle and deposit protections to the production Decisor

## Problem

Another session left uncommitted changes in the development copy of the Decisor (`pruebas/decisor/decisor.jscode`,
tests in `pruebas/decisor/decisor-notas.test.ts`, notes in `odd/tasks/bot-brevedad.md`). They add protections that are
not in production:
- several Zelle accounts: do not register a name-account pair blindly; confirm each pair (the 26-oct case 7c0920e3);
- a Zelle + CUP send: do not tell the customer there is no CUP;
- a deposit that equals the planned split is not an over-deposit or an incident; a partly assigned Zelle says how much
  is still unassigned;
- a customer who only acknowledges ("ok", "gracias") after the beneficiary was registered gets no repeated summary.
The live Decisor is the PRODUCTION copy `pruebas/decisor/produccion/decisor.jscode` (md5 9150c4d8, versionId 158fdc43,
which already has the 2026-11-05 cash-rail fix f3d0ebd, brevity and away mode).

## Owner decision

2026-11-05: "con respecto a los cambios que anaden la proteccion, ponlos tambien" (after the check that the 4 recent
multi-Zelle operations were registered correctly).

## Scope

- T1 Port to the production copy ONLY the behaviours above that the production copy does not already have (some items of
  that diff, e.g. "5 mil pesos" as GYD or the follow-up brevity rule, may already be live: check each one and skip what
  exists). Keep the cash-rail fix and everything else. Port the matching tests into
  `pruebas/decisor/produccion/decisor-produccion.test.ts`; update the md5 pin in `pruebas/decisor/produccion/correr.ts`.
  Do not edit the other session's files.
- T2 Production deploy (owner go-ahead given above): backup, publish from the production copy, verify active version.

## Constraints

- Never edit `pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`, `pruebas/decisor/decisor-notas.test.ts`,
  `odd/tasks/bot-brevedad.md`. No real customer data in tests or commits.

## TDD

Strict, on. vitest (`npx vitest run pruebas/decisor/produccion`).

## Tasks

- [x] T1 Port the missing protections with tests. Evidence: 6 new tests RED (6 failed / 81), then GREEN (81/81); full suite 273 files, 3806 passed; new production md5 f8de0539 (full f8de0539dcb3460b87886582a555ad13). Commit: see Progress.
- [ ] T2 Deploy to production.

## Progress

- 2026-11-05 created. RDD off.
- 2026-11-05 T1 done. Ported: several Zelle accounts (no forced pair, zelle_nombre_cuenta wins), Zelle+CUP note,
  deposit equal to planned split (reads optional ctx.servicio_resuelto.reparto_pendiente; dormant until the context node
  supplies it, production had no resolver state), partly assigned Zelle (FALTAN x USD). Already present in production:
  acknowledgement-only summary (soloAcuse), "5 mil pesos" as GYD, follow-up brevity (own cotizacionPrevia design),
  "Lista para transferir" without "enseguida". Not ported: rp325 / resolver-based etapa logic (different lineage).
