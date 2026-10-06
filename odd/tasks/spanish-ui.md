# Feature: panel in Spanish, "Resumen" renamed "Finanzas"

## Objective
The CRM panel shows its interface in Spanish, and the section "Resumen" is called "Finanzas".

## Problem
The panel copy lives in messages/en.json (about 1,800 strings, next-intl). src/i18n/request.ts reads the locale from
NEXT_PUBLIC_APP_LOCALE (default 'en') and falls back to en.json when messages/<locale>.json is missing. There is no
es.json, so the panel is in English except a few hard-coded Spanish screens.

## Why (owner, 2026-10-06)
"quiero poner el crm en español y renombrar algunas cosas" — for now only "que resumen sea finanzas".

## Scope
- messages/es.json: full translation of en.json, same keys and structure, ICU placeholders/plurals/rich-text tags kept
  byte-identical in their syntax ({count}, {count, plural, ...}, <b>...</b>), neutral professional Spanish, the
  business's own vocabulary where it already exists in the app (remesa, recarga, combo, visa, Zelle, Clasica, Tropical,
  tarjeta, beneficiario, deposito, operacion, Calculadora, Tablero...). Brand "Remesas YA" unchanged.
- Rename: the section's visible name becomes "Finanzas" in Spanish ("Finances" in English): Sidebar.resumen, the
  matching Header key, and Resumen.page.title ("Finanzas e historial" / "Finances and history"). The in-page block
  "Resumen por periodo" keeps its name. Route /resumen, the "Resumen" namespace and code identifiers stay unchanged.
- Locale switch: NEXT_PUBLIC_APP_LOCALE=es where builds read it (build env examples/docs in infra/deployment); the real
  staging/production build env files are changed only at deploy time with the owner's go-ahead.
- A test that es.json has exactly en.json's keys and the same ICU arguments per string.
- Out of scope for now: hard-coded English strings outside the catalog (listed in the doc as a follow-up), date and
  number formats, renaming routes or namespaces.

## Constraints
- No behaviour change besides copy. Existing tests that read en.json keep passing.
- Deploy: staging first for the owner's look, then production with the owner's go-ahead.

## TDD
Strict TDD on (user config). Runner: vitest (npm test). RED: the parity test fails before es.json exists.

## Tasks
- [x] T1 Parity test (RED) + es.json for the sections in daily use: LoginPage, Sidebar, Header, ModeToggle, Dashboard,
  Inbox, Contacts, Settings, Resumen, Tablero; rename Resumen -> Finanzas (es and en).
- [x] T2 es.json for the remaining sections (Pipelines, Broadcasts, Automations, Flows); parity test GREEN; list the
  hard-coded English strings outside the catalog.
- [ ] T3 Staging build with NEXT_PUBLIC_APP_LOCALE=es; owner's look.
- [ ] T4 Production with the owner's go-ahead.

## Acceptance criteria
- With NEXT_PUBLIC_APP_LOCALE=es the panel menus, headers, buttons and messages are in Spanish; the menu shows
  "Finanzas".
- es.json and en.json have identical key sets and ICU arguments; typecheck, lint and the full test suite pass.

## Progress
- 2026-10-06 document created. Delivery strategy: ask-on-risk (the translation is data, not authored logic).

- T1 done: RED observed (parity test failed: es.json missing, 1,799 keys missing; 3 of 4 tests failed). es.json holds LoginPage, Sidebar,
  Header, ModeToggle, Dashboard, Inbox, Contacts, Settings, Resumen, Tablero; the key and ICU tests pass for those
  sections (only Pipelines, Broadcasts, Automations, Flows keys are still missing). Rename applied in both catalogs
  (Sidebar.resumen, Header.resumen, Resumen.page.title). src/i18n/request.test.ts proves NEXT_PUBLIC_APP_LOCALE=es loads es.json.

- T2 done: es.json now covers all 14 sections (1,799 strings; 1,617 differ from en, the other 182 are already-Spanish
  values, cognates, brand names or placeholders). Parity test GREEN (4/4), request config test 2/2.
  NEXT_PUBLIC_APP_LOCALE=es added to infra/deployment/wacrm.produccion.build.env.example (before the two manifest-checked
  last lines) and the .env.local.example comment; the real build env files were not touched.

## Terminology (owner review)
Dashboard = Panel; Inbox = Bandeja de entrada; Contacts = Contactos; Pipelines = Embudos (stages = Etapas); Deals =
Negocios (the already-Spanish delivery-proof strings keep "deal"); Broadcasts = Difusiones; Automations =
Automatizaciones; Flows = Flujos; AI Agents = Agentes de IA; Settings = Configuracion; Tablero = "Tablero de
operaciones"; Viewer = Observador; Owner = Propietario; Templates = Plantillas; Quick replies = Respuestas rapidas;
tags = Etiquetas; Incident = Incidencia.

## Follow-up: hard-coded English
Visible strings outside messages/*.json (list only, not fixed). calculadora/page.tsx and the *.ts API errors are
already Spanish or out of scope.
- src/app/join/[token]/page.tsx:76,80,84,88 (invite error titles), :189,194,200,215 (toasts), :226,260,267,275,283,340,387 (labels/buttons)
- src/app/(auth)/signup/page.tsx:102,122,164,169,184,199,209,214,241 (title, labels, placeholders, links)
- src/app/(auth)/forgot-password/page.tsx:54,68,82,102,124
- src/app/(dashboard)/notifications/page.tsx:128,161 (toasts), :188-189,202,210-211,264
- src/app/(dashboard)/agents/page.tsx:43-44
- src/components/agents/ai-usage.tsx:73,79,111,140,146-154,162,179,205
- src/components/agents/ai-playground.tsx:46,48,67,88,109-111,155,179
- src/components/flows/header.tsx:67-68,79,81,88,169-170
- src/components/flows/flow-editor-shell.tsx:109; src/components/flows/forms/node-config-form.tsx:459,501,660,808,931
- src/components/interactive/interactive-builder.tsx:97,102,107,112,230,323,374
- src/components/settings/quick-replies-manager.tsx:80,107,118,129-130,193,204,209,217
- src/components/settings/whatsapp-config.tsx:162,187,191,219,274,304,320,330,351,363,371 (toasts)
- src/components/settings/members-tab.tsx:173,225,251,271; invite-member-dialog.tsx:143 (toasts)
- src/components/settings/template-manager.tsx:550,778,848; ai-knowledge.tsx:202,211; appearance-panel.tsx:42; profile-form.tsx:273; settings-rail.tsx:51
- src/components/inbox/message-thread.tsx:501,514,567,579,624,633,713,722,783,829,848 (toasts)
- src/components/inbox/message-composer.tsx:272,280,295,453,473,500 (toasts); message-bubble.tsx:178
- src/components/contacts/contact-detail-view.tsx:351 (toast); src/app/(dashboard)/contacts/page.tsx:542
- src/components/broadcasts/step2-select-audience.tsx:432; step3-personalize.tsx:273,347; step4-schedule-send.tsx:128,141,204
- src/app/(dashboard)/broadcasts/page.tsx:162; broadcasts/[id]/page.tsx:82; automations/page.tsx:337
- src/components/automations/automation-builder.tsx:1013,1022,1311
- src/components/layout/sidebar.tsx:190; src/components/ui/dialog.tsx:75 and sheet.tsx:75 (sr-only "Close")
Count: roughly 150 occurrences in about 35 files (regex scan; not exhaustive: server-returned error strings and
multi-line JSX text can be missed).

## Next step
T3: staging build with NEXT_PUBLIC_APP_LOCALE=es and the owner's look (needs the owner's go-ahead for any deploy).
