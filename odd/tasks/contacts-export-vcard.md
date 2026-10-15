# Feature: export contacts (by tag) as a phone-importable vCard

## Objective
From Contacts, an admin exports the currently filtered contacts (e.g. tag "Nuevos") as a .vcf the phone imports, so
they appear in WhatsApp. Every exported name carries a prefix (default: the tag name) so the owner can find them all
in WhatsApp when adding them to a group (search "Nuevos").

## Owner request (2026-10-14)
"Exportar contactos para importarlos al celular y que salgan en WhatsApp; si selecciono la etiqueta Nuevos, exportar
solo esos. Solo para administradores. Que al exportar tengan una etiqueta que permita reconocerlos para añadirlos a
un grupo."

## Current state (mapped 2026-10-14)
- src/app/(dashboard)/contacts/page.tsx: client page, tag multi-select filter (selectedTagIds, OR) via RPC
  filter_contacts_by_tags (025, SECURITY INVOKER), else direct contacts query with ilike search; paginated 25.
- contacts.phone stored as digits (phone_normalized 022); no export exists; import in src/components/contacts/.
- i18n Contacts.page in messages/es.json + en.json. Roles: src/hooks/use-can.ts, src/lib/auth/roles.ts.

## Design (stated to the owner)
- "Exportar" button next to "Importar", visible only to owner/admin.
- Dialog: "Marca para el nombre" text field, prefilled with the selected tag name(s) (none selected: empty or
  "CRM"), editable; shows how many contacts will be exported.
- Exports ALL contacts matching the current filter (tags + search), fetched in batches (PostgREST ~1000 cap).
- vCard 3.0, CRLF, escaped; FN/N = "<marca> - <nombre>" (no name -> number); TEL;TYPE=CELL:+<digits>.
- File name contactos-<marca>.vcf. No migration.
- Note: RLS already lets any member read contacts; the admin limit is a UI gate.

## Constraints
- TDD strict (RED -> GREEN -> REFACTOR); runner `npm test` (vitest). Pure logic in src/lib/contacts/ with tests.
- Conventional Commits, no AI trailer. Staging first; production only with explicit go-ahead. Do not restyle.

## Tasks
- [x] T1 src/lib/contacts/export-contacts.ts (vCard builder, prefix, phone format, file name) + tests (a07c725)
- [x] T2 Contacts page: admin-only Exportar button + dialog + batched fetch of the filtered set + i18n es/en (94207d4)
- [x] T3 Staging deploy + owner check (deployed to staging 2026-10-14; owner tested on staging 2026-10-14)
- [x] T4 Production (owner go-ahead 2026-10-14 "probado en staging, pasalo a produccion"; done 2026-10-14, evidence below)

## Acceptance criteria
- Tag "Nuevos" selected -> only those contacts exported, all of them (not just the visible page).
- Imported on a phone, names read "Nuevos - <name>" and WhatsApp finds them by "Nuevos".
- Agents/viewers do not see the button.

## Progress / evidence
- 2026-10-14: document created, exploration done.

- 2026-10-14: T1 RED (module missing) -> GREEN 11 tests. T2 RED (canExportContacts, fetchAllInBatches missing) -> GREEN.
  Gate: new capability 'export-contacts' (canExportContacts = admin+) in roles.ts/use-can.ts. buildVCard returns
  {vcf, exported, skipped}. TDD runner: vitest. npm test 191 files/2596 tests pass; tsc clean; eslint 0 errors.

- 2026-10-14 T3 staging deploy (owner-authorized, staging only, no migration):
  - Release 7e62096f35818f7a50ab9ae25765230efeafdc15, BUILD_ID J7IHWXegbL9PwnZa35pWB (server, pm2 cwd and crm.onlinefreedom.site match, /login 200). anterior -> 037c366a8e72040453ad0b3a6b1e8fc80749f5d4.
    Manifest staging, kolppplawzdsjfydwejr, 0 production refs, sha256 ok. Built WITH the tests step (114 pipeline tests passed in node:20). pm2 wacrm-staging online. prod-build restored to 16b6436, env copy deleted.
    Rollback: current -> 037c366a8e72040453ad0b3a6b1e8fc80749f5d4 and pm2 restart wacrm-staging --update-env.
  - Staging tags of the owner account (read-only): Nuevo 2, Recurrentes 1, Admin 0, Cliente 0 (3 contacts in total). Try "Nuevo".

- 2026-10-14 T4 production (app only, no migration):
  - Release 97ae254ab8a8bd7bd53e06e668b834a22b382469 (code identical to staging 7e62096 plus docs), BUILD_ID xVXl-gGpioH2EPSND4Mz1. Built in docker node:20 uid 1000 from prod-build (production build env read from mejora-legacy, no env copy created; .git of the main checkout mounted read-only; NEXT_PRIVATE_OUTPUT_TRACE_ROOT=$PWD), with tests (114 passed). Manifest production, ref hqztotshnlzaiziwjyzh, 0 staging refs (kolppplawzdsjfydwejr), sha256 ok.
  - Deployed with desplegar-wacrm-produccion.sh: pm2 wacrm online (restarts 40, unstable 0, same pid after 20 s), /proc cwd = the release, domain serves the BUILD_ID, /login 200.
    Rollback: anterior -> 16b64366e61919d90ea271c32a355a2254af81cf (rollback-wacrm-produccion.sh). prod-build left at 97ae254.

## Next step
Owner checks the Exportar button in production (admin only).
