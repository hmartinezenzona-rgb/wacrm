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
- [x] P1 - Migration 233 (+ ROLLBACK) and staging assertion `id-photo-from-chat.sql`, RED then GREEN, rollback proof, related assertions.
- [x] P2 - API/command layer: PATCH key, chat-images route, command, tests.
- [x] P3 - Picker component and card / edit / add integration, strings es+en, tests.
- [x] P4 - Full suite, tsc, eslint, evidence.

## Follow-up (privacy, NOT fixed here)
`chat-media` is a PUBLIC bucket: ID-card photos are reachable by URL to anyone who has it (the URL carries a timestamp and a WhatsApp id, hard to guess but not secret).
Options: (a) private bucket + signed URLs resolved by an authenticated route (the "Ver ID" link and the thumbnails would go through it); (b) move only identity
documents to a private bucket at ingestion; (c) keep public and shorten exposure with unguessable object names. (a) is the cleanest; it touches ingestion and every media viewer.

## Evidence - P1 database (staging, 2026-10-08)
- RED: `id-photo-from-chat.sql` failed at case a (`22023 unknown field`) before 233. 233 applied (`BEGIN; 233; COMMIT;`), assertion GREEN (a-h).
- Fingerprints on staging after 233: crm_corregir_beneficiario 8200d08f647f817eb5fa8a5fa6b44065, crm_agregar_beneficiario 167b6bc5971c44f80fdd59ee5ee769cb,
  crm_imagenes_de_conversacion 67ceb0d384c9af6ff455ce1e4afbb5d2. Pre-233 (staging = production, no drift): 43e52676..., ee9da2d6.... Rollback proof: ROLLBACK-233
  inside a rolled-back transaction restored both md5s and dropped the new function. Staging left WITH 233; no fixture rows.
- Related assertions with 233: cash-recipient-add, add-beneficiary, corrections, cash-delivery-data, cash-delivery-activation, change-operation-service, saldo-model,
  reparto-auto, panel-cash-recipient, panel-notify-and-cash-name, cash-delivery-rate, combo-edit, combo-model, panel-closing-actions, panel-recarga, recarga-model, visa-model: PASS.
  Failing identically WITHOUT 233 (deal-era fixtures): deals-free-views-and-inert-edits, history-readiness, delivery-feed-evidence.
- Choice: null clears the photo on a correction (the RPC already clears card_number/phone/amount/currency with null); on add, null = none.

## Evidence - P2-P4 app
- API: PATCH beneficiary accepts `id_photo_wamid` (string or null, 400 otherwise); `GET /api/remittance-operations/chat-images?conversationId=` (viewer, beta flag,
  42501 -> 403) over `crm_imagenes_de_conversacion`; `fetchChatImages` command. RED seen first (10 failing tests), then GREEN.
- UI: `id-photo-picker.tsx` (trigger + Base UI Dialog, 3-column lazy thumbnails, time + sender, aria-pressed on the current one, keys stay inside the dialog),
  `beneficiary-id-photo.tsx` (card row: Ver ID / missing note + picker that saves at once; `IdPhotoFormRow` for the edit and add forms, whose check sends the
  choice). The note "La foto del carnet llega por el chat" (`cashIdPhotoHint`) was removed from both catalogs. Strings in es and en; parity test green.
- Checks: `npx vitest run` full suite 186 files / 2497 tests passed; `npx tsc --noEmit` clean; `npx eslint` on the changed files clean.
- Not done here: the production application of 232/233 and the app deploy (not authorised); the visual check in a real browser.
- Staging deploy (2026-10-08; release 7ed8f14a9786d3fea9b92794b758952758f98af8, BUILD_ID TA9KQYcBbpGSr3rPTw4o4, app commit 7ed8f14; migrations 232 and 233 already applied on staging): manifest environment=staging, project kolppplawzdsjfydwejr, 0 production refs, 32 files with staging refs, 114 build tests passed, sha256 OK on oracle2 and the unpacked release byte-identical to a fresh extraction of the built tarball (2477 files), pm2 wacrm-staging process cwd resolves to the new release, restarts 90 -> 91 and stable (unstable 0, still 91 after 30 s), /login 200 with the new BUILD_ID and "Bienvenido de nuevo", all 17 JS chunks listed by the inbox client-reference manifest served by crm.onlinefreedom.site byte-identical to the build, the deployed bundle contains "Elegir del chat" (78 files) and no longer "La foto del carnet llega por el chat", and `/api/remittance-operations/chat-images` is in the route manifest and answers 401 unauthenticated on the live site. Rollback: anterior -> d5dd1b2 (`ssh oracle2 'ln -sfn /home/ubuntu/wacrm-releases/d5dd1b2c5ae22a7007c882a0fcc5c19649cb038c ~/wacrm-releases/current && pm2 restart wacrm-staging --update-env'`).

- Production database (2026-10-08, owner "si pasalo a produccion"): backup
  `~/wacrm-respaldos/produccion-20261008T230834Z.dump`. Pre-check: production had the pre-232/233 definitions
  (`cerebro_registrar_deposito` e14bc02d…, `crm_corregir_beneficiario` 43e52676…, `crm_agregar_beneficiario` ee9da2d6…),
  last migration 231. `~/cerebro-fase1/pruebas/gate135-aplicar-db.py` (bundle 232 + 233; helper `zz_wu5b_exec` created
  before, dropped after, count 0): `ensayo` -> function md5s equal to staging (70f46bff…, 8200d08f…, 167b6bc5…,
  67ceb0d3…); `GATE_BUNDLE=ida-y-vuelta ensayo` -> the three pre-existing functions back to their old md5s and the
  picker read gone; `aplicar` -> `{"r":"OK"}`, recorded as `232_deposit_reuses_recipient_first_operation` and
  `233_id_photo_from_chat`. Assertions on production (rolled back): `deposit-reuses-recipient-first-operation`,
  `id-photo-from-chat`, `cash-recipient-add` pass. Pre-existing difference kept: production does not grant the two
  panel RPCs to service_role (staging does).
- Production app deploy (2026-10-08, owner "si pasalo a produccion"; release 940a58c254fea4a0f259f98ffb18012b3c0ce5b8, BUILD_ID IDLrCbIIlagVS7CsrAu3A, app commit 940a58c; migrations 232 and 233 were already applied on production): built in docker node:20 as uid 1000 from the clean prod-build worktree with the production build env, manifest environment=production, project hqztotshnlzaiziwjyzh, 0 staging refs (kolppplawzdsjfydwejr), 32 production refs, 114 build tests passed, pm2 `wacrm` cwd = new release, restarts 34 -> 35 and stable (unstable 0, still 35 after 20 s), /login 200 with valid TLS, "Bienvenido de nuevo" and the new BUILD_ID, all 19 JS chunks listed by the inbox client-reference manifest served by wacrm.onlinefreedom.site byte-identical (sha256) to the build, deployed es messages carry "Elegir del chat" and not "La foto del carnet llega por el chat", `/api/remittance-operations/chat-images` in the route manifest and 401 unauthenticated on the live site, prod-build clean. Rollback: anterior -> 04c7a7637cdc5a373ffaa90c2fbe9e7bdf8218dc (`infra/deployment/rollback-wacrm-produccion.sh`).
