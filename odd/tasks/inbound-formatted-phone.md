# Inbound messages lost when a hand-made contact has a formatted phone

## Objective

No inbound WhatsApp message may be lost because a contact was saved by hand with a formatted phone, and any message the
webhook does not save must leave a reason in `whatsapp_webhook_log`.

## Problem (production, 2026-10-29)

- Webhook log rows f5401b04 (15:48 UTC, text) and 628b4a9e (15:55 UTC, image) stayed `procesado = false`, `error = null`.
- Their contacts 0f7ff89d and 3f2c9f90 were created by hand in the panel (`name_source = manual`) with phone
  `+N (NNN) NNN-NNNN`; Meta sends digits only.
- `src/lib/contacts/dedupe.ts` `findExistingContact` prefilters candidates with `.like('phone', '%<last 8 digits>')` on
  the raw column, so a formatted phone is never a candidate. The webhook then inserts a new contact, the unique index
  rejects it, the "raced" lookup fails the same way, `findOrCreateContact` returns null and `processMessage` returns
  false. `src/app/api/whatsapp/webhook/route.ts` only writes `error` when processMessage throws, so nothing alerted.
- Data fix applied 2026-10-29 16:47 UTC (owner go-ahead): both phones normalized to digits, audit rows 797d737d and
  b44735cf. Only these 2 of 258 contacts had formatting.

## Owner decision

2026-10-29: "si, corrige los dos numeros y luego arregla el codigo".

## Scope

- T1 Lookup: `findExistingContact` finds a contact whose stored phone has separators (spaces, brackets, dashes, dots,
  leading +). Keep `phonesMatch` as the final strict check.
- T2 Save: the manual contact form (create and edit), the CSV import and any other panel path that writes
  `contacts.phone` store digits only (the shape 255 of 258 rows already have). Check the API routes, not only the UI.
- T3 Trace: when `processMessage` returns false (contact, conversation or message step), the webhook writes a short
  reason in `whatsapp_webhook_log.error` (for example "no guardado: contacto"), so the existing watcher on that table
  alerts. Behaviour for saved messages unchanged.

## Out of scope

- Re-processing the two lost messages; messaging those customers (owner decides).
- Schema changes or migrations.

## Constraints

- Do not touch the other session's uncommitted files: `pruebas/decisor/decisor.jscode`, `pruebas/decisor/correr.ts`,
  `pruebas/decisor/decisor-notas.test.ts`, `odd/tasks/bot-brevedad.md`.
- Next.js has breaking changes: read `node_modules/next/dist/docs/` before touching route code.
- Panel deploy only with the owner's go-ahead (skill wacrm-publicar-panel).

## TDD

Strict, on (global CLAUDE.md). Runner vitest: `npx vitest run <paths>`; `npx tsc --noEmit`; `npx eslint <files>`.

## Tasks

- [ ] T1 Lookup matches formatted stored phones.
- [ ] T2 Every panel write path stores digits only.
- [ ] T3 Webhook writes a reason when a message is not saved.
- [ ] T4 Full suite, tsc, eslint; production panel deploy after the owner's go-ahead.

## Progress

- 2026-10-29 created after the data fix. RDD off.

## Next step

T1.
