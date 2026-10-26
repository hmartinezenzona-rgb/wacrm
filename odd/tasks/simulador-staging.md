# Phase 4c: staging simulator

Status: DONE (2026-10-26). Objective: exercise the Cerebro end to end in staging without sending
WhatsApp, because the staging Cerebro shares the production token and must never be executed.

## What

- `infra/n8n/crear_simulador.py` clones the latest staging Cerebro into a **separate** workflow,
  replaces every outbound path (outbox, direct send, wait notice, admin confirmation, result) with a
  no-op or a `messages` insert, and writes the webhook URL/token to
  `~/.config/wacrm/simulador.env` (0600).
- `infra/n8n/simular_cerebro.py` creates a PRUEBA conversation and customer message in staging,
  posts a signed `message.received` payload to the simulator, waits for the bot reply in `messages`,
  prints it and cleans the PRUEBA rows.
- `infra/n8n/README-simulador.md` documents the safety boundary and the commands.

## Incident and fix

The first clone replaced `Responder por WaCRM` but missed the newer outbox path
(`Encolar en outbox` → `Enviar directo?` → `Despertar al enviador`). The first test queued the reply
to the fake PRUEBA number `59902539999`; the outbox sender attempted Meta and got
`#133010 Account not registered`. **No real customer was involved** (the number is fake and Meta
rejected it). The outbox row was deleted, the bad clone deactivated and deleted, and the corrected
clone removes `Encolar en outbox`, `Resultado del envio`, `Despertar al enviador`, `Avisar espera` and
`Confirmar al admin`; `Enviar directo?` is forced true and `Responder por WaCRM` inserts into
`messages`. The second and third runs produced the bot reply and cleaned to zero.

## Evidence

- Simulator workflow: `hQHnga5PmaDHsCFO` (staging, active), webhook path `simulador-cerebro-75d2d59a2134`.
- First successful turn: "Hola, cuánto llegan por 13,000 GYD a Zelle?" → reply with 50 USD by Zelle,
  the after-hours notice and a request for the recipient; no WhatsApp.
- Second successful turn (repo tool): "Hola, cuánto llegan por 26,000 GYD a Zelle?" → reply with 100
  USD; `cleaned yes`.
- Cleanup checks: contacts/conversations/messages/outbox/cases/ejecuciones/tool logs/memoria/nonces
  for the test rows = 0.

## Tasks

- [x] T1. Create the separate simulator workflow and the env file.
- [x] T2. Run a synthetic turn and inspect the bot reply.
- [x] T3. Fix the missed outbox path; delete the outbox row and the bad clone.
- [x] T4. Move the tools to `infra/n8n/`, document them and test the repo tool.
- [x] T5. Verify the PRUEBA rows are zero.

## Decisions

- The simulator is a separate workflow; the staging Cerebro is never executed.
- All outbound nodes are no-ops except the `messages` insert; the bot reply is visible in the panel.
- The webhook has a random path and a header token stored only in the local 0600 env file.
- If the Cerebro gains a new outbound node, `crear_simulador.py` must be updated; the README says so.
