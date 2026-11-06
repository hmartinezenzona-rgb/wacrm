# Data the team gave is never registered as the customer's beneficiary

## Problem (production, 2026-11-05)

A customer had been overpaid. At 20:27 UTC a team member wrote in the chat the Zelle account (US phone + name) where the
money had to be returned. At 20:33 the customer sent an image; vision read it as `cuenta_zelle` with that same name and
account (execution 650307). With no open operation (the last one completed at 19:23) the Decisor still emitted "DATOS DE
ZELLE DETECTADOS ... Llama registrar_beneficiario_zelle EN ESTE MISMO TURNO", so the bot registered it and opened Zelle
operation 5a20c482 (later deleted by an admin).

## Owner decision

2026-11-06: "si el admin es quien da la cuenta no deberia crear una operacion con esa cuenta" (no question to anyone).

## Scope (production Decisor `pruebas/decisor/produccion/decisor.jscode` only)

- T1 If a detected Zelle account (US phone or e-mail) or Cuban card/phone also appears in a TEAM member's message of this
  conversation (the "Companero del equipo" lines the Decisor already receives, or whatever ctx field carries team
  messages), do not emit any note that orders a registration tool for it, and add one note: that data was given by the
  team, it is not the customer's recipient: do NOT register it, do NOT open a send, do NOT ask about it; answer only what
  the customer says.
- T2 With no open operation and no new send request from the customer in this turn, detected recipient data does not
  order a registration tool; a note tells the model to ask first whether it is for a new send.
- Tests in `pruebas/decisor/produccion/decisor-produccion.test.ts`; md5 pin in `pruebas/decisor/produccion/correr.ts`.
  Deploy to production after the owner's go-ahead.

## Constraints

Do not touch `pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`, `pruebas/decisor/decisor-notas.test.ts`,
`odd/tasks/bot-brevedad.md`. No real customer data in tests or commits. Strict TDD, vitest.

## Tasks

- [x] T1 Team-given data is never registered.
- [x] T2 No open operation and no new request: ask before registering.
- [ ] T3 Production deploy after go-ahead.

## Implementation notes (T1, T2)

- Mode: strict TDD, vitest (`npx vitest run pruebas/decisor/produccion`). RED observed first (4 new tests failed), then GREEN.
- Team messages come from `ctx.conversacion_no_vista` ("Companero del equipo: ..." / "Cliente: ..."); only team-labelled lines
  (and unlabelled continuations) count. Normalization: e-mail lowercase, digits only, US phone 10 digits after +1, Cuban phone 8
  digits after 53, card 16 digits. A matched datum is blanked before any note is built; one team-data note follows the team note.
- T2 rule: "open operation" = `Historial.envios_abiertos > 0`, `etapa_envio_abierto`, `ctx.riel_operacion`, registered
  beneficiaries of open operations, `ctx.tiene_beneficiario`, or a recarga/combo/visa in progress. "New request" = receipt in the
  turn, `ctx.servicio_pendiente`, or a send verb (quiero/necesito/enviar/mandar/envio/remesa/transferir/depositar/recarga). With
  neither, the registration-ordering notes are removed and the ask-first note is added.
- 12 existing tests modelled a Zelle/card datum with no open operation; they now declare `historial: { envios_abiertos: 1 }`.
- New md5 of the live Decisor: d63c936eada22ac2962fc43f569160f7.
