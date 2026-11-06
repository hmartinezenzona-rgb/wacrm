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

- [ ] T1 Team-given data is never registered.
- [ ] T2 No open operation and no new request: ask before registering.
- [ ] T3 Production deploy after go-ahead.
