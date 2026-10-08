# Choose the cash recipient's ID photo from the chat

## Objective
The team can attach the recipient's ID-card photo to a cash-USD recipient from the panel, by choosing an image the customer already sent in the same chat.

## Problem / why (production, 2026-10-08, "Edel")
The n8n node "Registrar carnet efectivo" writes `remittance_beneficiaries.id_photo_wamid` through `crm_registrar_datos_entrega_efectivo` only when an open cash
operation exists at that instant. The customer sent the carnet before any cash operation existed, so nothing was stored and nothing retries. The panel has no
manual path: `crm_corregir_beneficiario` takes no photo key, yet `crm_beneficiarios_completos` (188) and `crm_entregar_operacion` require the photo.
Owner: "seria buena idea poder tambien poner manualmente la foto para casos como este".

## Design (decided)
No new column, no upload. The photo is a reference to an image message of the SAME conversation: `id_photo_wamid = messages.message_id`. "Ver ID" already
resolves it through `crm_operaciones_de_conversacion` (189: `messages.message_id = id_photo_wamid AND messages.conversation_id = operation.conversation_id`).
- DB 233: `crm_corregir_beneficiario` accepts `id_photo_wamid` for an `efectivo_usd` recipient only; the value must be the `message_id` of an image message
  (`content_type = 'image'`) of the operation's conversation, else 22023. NULL clears it (the RPC already lets card_number / phone / amount / currency be cleared
  with null; an empty string is rejected). Same permission (`agent`), locks (beneficiaries lock) and audit (`human_correction`, before/after carry the reference).
  `crm_agregar_beneficiario` accepts the same optional key for a cash recipient, same validation. New read RPC `crm_imagenes_de_conversacion(conversation, limit)`
  (viewer membership like `crm_operaciones_de_conversacion`) returns the image messages (id, message_id, created_at, sender_type, media_url), newest first.
- App: route `GET /api/remittance-operations/chat-images?conversationId=`, `fetchChatImages` command, `id_photo_wamid` allowed in the PATCH route. UI: an "Elegir del chat"
  control (compact picker in a Dialog, lazy thumbnails, newest first, time and sender, customer images first-class) where the card shows "Falta la foto del ID",
  in the cash recipient's edit and add forms; with a photo set: "Ver ID" plus a way to change it. The note "La foto del carnet llega por el chat" is replaced by the control.

## TDD
Mode strict, source user global CLAUDE.md. Runners: DB = staging SQL assertion (docker postgres:17 psql, `BEGIN; <assertion minus BEGIN/ROLLBACK>; ROLLBACK;`);
app = `npx vitest run <files>` (RED then GREEN), `npx tsc --noEmit`, `npx eslint <changed>`.

## Tasks
- [ ] P1 - Migration 233 (+ ROLLBACK) and staging assertion `id-photo-from-chat.sql`, RED then GREEN, rollback proof, related assertions.
- [ ] P2 - API/command layer: PATCH key, chat-images route, command, tests.
- [ ] P3 - Picker component and card / edit / add integration, strings es+en, tests.
- [ ] P4 - Full suite, tsc, eslint, evidence.

## Follow-up (privacy, NOT fixed here)
`chat-media` is a PUBLIC bucket: ID-card photos are reachable by URL to anyone who has it (the URL carries a timestamp and a WhatsApp id, hard to guess but not secret).
Options: (a) private bucket + signed URLs resolved by an authenticated route (the "Ver ID" link and the thumbnails would go through it); (b) move only identity
documents to a private bucket at ingestion; (c) keep public and shorten exposure with unguessable object names. (a) is the cleanest; it touches ingestion and every media viewer.
