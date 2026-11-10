# Feature: the bot never asks again for cash-delivery data already saved

## Objective
On a cash (efectivo_usd) send, the bot asks only for the delivery data that is really missing (name, phone,
address, carnet photo) according to what is saved, and asks nothing when all of it is saved.

## Problem / why (2026-11-10)
- conv ce686768, op 715b44dd: the carnet photo was saved at 17:44 UTC (exec 699432, beneficiary 8a618468
  id_photo_wamid). At 19:13 (exec 700098) an audio with no data got "Cuando llegue, me envía la foto del carnet".
- Contexto conversacion returned `entrega_efectivo_falta: []` and `entrega_efectivo_en_curso: true`, but the
  production Decisor (pruebas/decisor/produccion/decisor.jscode, live fe8fb5ae) never reads
  `entrega_efectivo_falta`; `sabeDestino` ignores cash beneficiaries (`tiene_beneficiario` false); the fixed cash
  note (~line 974) lists "nombre completo, direccion exacta o foto del carnet"; `hayOperacionNueva` counts the stored
  phone (`celularCtx`) as new data, which forced a reply ("PROHIBIDO RESPONDER SKIP") to an audio with no data.

## Owner decisions
- 2026-11-10: fix at root ("si").

## Scope
In: production-lineage Decisor (pruebas/decisor/produccion/decisor.jscode, correr.ts pin, decisor-produccion.test.ts);
production deploy with go-ahead. Out: Contexto SQL (the field already exists), the other session's Decisor.

## Constraints
- Strict TDD with vitest (`npx vitest run pruebas/decisor/produccion`), RED then GREEN, real case as fixture.
- The staging Cerebro runs the other session's Decisor: production-lineage changes ship to production after their
  tests, with the owner's go-ahead (backup first, `publicar-decisor produccion --esperado <live md5>`).
- Never touch pruebas/decisor/decisor.jscode, pruebas/decisor/correr.ts, pruebas/decisor/decisor-notas.test.ts,
  odd/tasks/bot-brevedad.md. No AI attribution in commits.

## Tasks
- [x] T1 Decisor: cash rail reads ctx.entrega_efectivo_falta (empty + en curso -> destination known, note forbidding
      any data request; non-empty -> ask only the listed items); stored data (celularCtx/tarjetaCtx) no longer counts
      as new data in hayOperacionNueva; tests (ce686768 shape, partial missing list, card rail unchanged)
- [ ] T2 Production (needs go-ahead): backup, publish, first executions check

## Acceptance criteria
- Cash send with everything saved + audio without data -> no request for carnet or any delivery data.
- Missing only the carnet -> asks only for the carnet photo.
- Card sends behave as before (existing tests green).

## Progress / evidence
- 2026-11-10: root cause (read-only; execs 699432, 700098).
- 2026-11-10 T1 done (commit fc19ca5): sabeDestino true for cash rail when en curso and falta [] (new note: all delivery data
  saved, PROHIBIDO ask again); non-empty falta -> note asks only listed items (telefono/direccion/carnet); absent field
  -> old note. hayOperacionNueva counts only this batch (s.comprobante/tarjeta/celular); it had a single use (the
  "DATOS NUEVOS / PROHIBIDO RESPONDER SKIP" note), so no split needed.
  RED: 5 of 7 new tests failed (2 guards passed). GREEN: `npx vitest run pruebas/decisor/produccion` 112/112.
  New md5 97469eb2a5da7a61f68d2528d50a9a0b (was fe8fb5ae...), pin updated in produccion/correr.ts.

## Next step
T2 (needs owner go-ahead).
